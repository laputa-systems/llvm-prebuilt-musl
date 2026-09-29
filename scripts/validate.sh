#!/usr/bin/env bash
# Validate a built package the way a downstream user meets it.
#
#   usage: validate.sh <clang+llvm-...-linux-musl.tar.xz>
#   environment: LLVM_VERSION, LLVM_ARCH; TESTS_DIR (default /tests)
#
# Runs in the validation container (docker/validate.Dockerfile): musl's headers,
# startup objects, and libc.a as the sysroot, and no compiler, linker, libstdc++
# or libgcc. The package is extracted to a different absolute prefix than it was
# installed at, and every tool is invoked by its package path. Failures print the
# captured output of the failing command; the script exits nonzero if any check
# fails. Test programs really run: a failing executable is a failure.
set -uo pipefail

TARBALL="${1:?usage: validate.sh <package.tar.xz>}"
: "${LLVM_VERSION:?}" "${LLVM_ARCH:?}"
TESTS="${TESTS_DIR:-/tests}"
MAJOR="${LLVM_VERSION%%.*}"
TRIPLE="${LLVM_ARCH}-linux-musl"

case "$LLVM_ARCH" in
    x86_64)  MACHINE="X86-64";   OTHER_TRIPLE="aarch64-linux-musl"; OTHER_MACHINE="AArch64" ;;
    aarch64) MACHINE="AArch64";  OTHER_TRIPLE="x86_64-linux-musl";  OTHER_MACHINE="X86-64" ;;
    *) echo "unsupported LLVM_ARCH ${LLVM_ARCH}" >&2; exit 2 ;;
esac
# The complete set of external dependencies a shipped ELF may have: musl's libc.
MUSL_SONAME="libc.musl-${LLVM_ARCH}.so.1"
MUSL_INTERP="/lib/ld-musl-${LLVM_ARCH}.so.1"

passed=0 failed=0
pass() { printf '  PASS: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; failed=$((failed + 1)); }
indent() { sed 's/^/      | /' | head -60; }
section() { printf '\n--- %s ---\n' "$1"; }

# verdict <description> <command...>: pass if the quiet test command succeeds.
verdict() {
    local desc="$1"
    shift
    if "$@"; then pass "$desc"; else fail "$desc"; fi
}

# check <description> <command...>: passes if the command succeeds; otherwise the
# captured output is shown.
check() {
    local desc="$1" out
    shift
    if out=$("$@" 2>&1); then pass "$desc"; else fail "$desc"; printf '%s\n' "$out" | indent; fi
}

# contains <description> <haystack> <fixed-string>
contains() {
    if grep -qF -- "$3" <<<"$2"; then pass "$1"; else fail "$1 (missing: $3)"; printf '%s\n' "$2" | indent; fi
}
lacks() {
    if grep -qF -- "$3" <<<"$2"; then fail "$1 (found: $3)"; printf '%s\n' "$2" | indent; else pass "$1"; fi
}

WORK=$(mktemp -d /tmp/validate.XXXXXX)
PREFIX_PARENT=$(mktemp -d /opt/relocated.XXXXXX)
trap 'rm -rf "$WORK" "$PREFIX_PARENT"' EXIT

# -- the environment really is clean --------------------------------------------
section "Clean environment"
verdict "container architecture is ${LLVM_ARCH}" test "$(uname -m)" = "$LLVM_ARCH"
stray=$(for tool in clang clang++ gcc g++ cc c++ ld ld.lld ld.bfd lld as cpp ar ranlib; do command -v "$tool"; done)
if [ -z "$stray" ]; then pass "no host compiler, linker, or binutils on PATH"; else fail "host toolchain present"; echo "$stray" | indent; fi
verdict "no GCC runtime or libstdc++ headers" test ! -e /usr/lib/gcc -a ! -e /usr/include/c++
verdict "musl sysroot present at /" test -f /usr/include/stdio.h -a -f /usr/lib/libc.a -a -f /usr/lib/Scrt1.o

# -- extract at a different prefix ----------------------------------------------
section "Package"
TC="${PREFIX_PARENT}/toolchain"
mkdir -p "$TC"
if out=$(tar -xf "$TARBALL" -C "$TC" --strip-components=1 2>&1); then pass "extracted to ${TC}"; else
    fail "extract package"; printf '%s\n' "$out" | indent; echo "Validation FAILED" >&2; exit 1; fi

CLANG="${TC}/bin/clang"
CLANGXX="${TC}/bin/clang++"
READELF="${TC}/bin/llvm-readelf"
RES="${TC}/lib/clang/${MAJOR}"
BUILTINS="${RES}/lib/linux/libclang_rt.builtins-${LLVM_ARCH}.a"
COMMON=(--target="$TRIPLE" --sysroot=/)
CXXFLAGS=(-std=c++20 -O2 -Wall -Wextra -Werror)

# Exact expected contents of the top-level directories. Anything missing or
# extra is a deliberate-change signal, not something to wave through.
declare -A expected_entries=(
    [bin]="clang clang++ clang++.cfg clang-${MAJOR} clang-cl clang-cpp clang.cfg ld.lld ld64.lld lld lld-link
           llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-ranlib llvm-readelf llvm-readobj llvm-size llvm-strings
           llvm-strip llvm-symbolizer wasm-ld"
    [lib]="clang libLTO.so libLTO.so.${MAJOR}.1 libc++.a libc++abi.a libc++experimental.a libclang.so
           libclang.so.${MAJOR}.1 libclang.so.${LLVM_VERSION} libunwind.a"
    [include]="c++ clang-c llvm-c"
)

listing() { (cd "$1" && ls -A) | sort | tr '\n' ' '; }
sorted() { xargs -n1 <<<"$1" | sort | tr '\n' ' '; }  # split on whitespace, sort, one line

section "Package layout"
if [ "$(listing "$TC")" = "bin include lib " ]; then pass "top-level: bin include lib only"; else
    fail "unexpected top-level entries"; listing "$TC" | indent; fi
for dir in bin lib include; do
    if [ "$(listing "${TC}/${dir}")" = "$(sorted "${expected_entries[$dir]}")" ]; then pass "${dir}/ has exactly the expected entries"; else
        fail "${dir}/ entries differ from the expected set"
        diff <(sorted "${expected_entries[$dir]}" | xargs -n1) <(listing "${TC}/${dir}" | xargs -n1) | indent
    fi
done
for required in include/c++/v1/__config_site include/c++/v1/iostream include/c++/v1/cxxabi.h include/clang-c/Index.h \
                include/llvm-c/lto.h "lib/clang/${MAJOR}/include/stddef.h" \
                "lib/clang/${MAJOR}/lib/linux/libclang_rt.builtins-${LLVM_ARCH}.a" \
                "lib/clang/${MAJOR}/lib/linux/clang_rt.crtbegin-${LLVM_ARCH}.o" \
                "lib/clang/${MAJOR}/lib/linux/clang_rt.crtend-${LLVM_ARCH}.o"; do
    verdict "present: ${required}" test -e "${TC}/${required}"
done
unwanted=$(find "${TC}/lib" \( -name 'libclang_rt.*' ! -name 'libclang_rt.builtins-*' \) -o -name '*san*' -o -name '*i386*' \
    -o -name '*i686*' -o -name 'libc++.so*' -o -name 'libc++abi.so*' -o -name 'libunwind.so*' -o -name 'libLLVM*' \
    -o -name cmake
    find "$TC" \( -path '*/include/llvm' -o -path '*/include/clang' -o -path '*/share' \))
if [ -z "$unwanted" ]; then pass "no sanitizers, i386 runtimes, shared C++ runtimes, LLVM libraries, or dev exports"; else
    fail "unwanted files in package"; echo "$unwanted" | indent; fi
verdict "__config_site selects musl" grep -Eq '^#define _LIBCPP_HAS_MUSL_LIBC 1' "${TC}/include/c++/v1/__config_site"

# Symlinks must resolve inside the package (no dangling or escaping aliases).
bad_links=$(find "$TC" -type l | while read -r link; do
    target=$(readlink -f "$link") || target=""
    case "$target" in "$TC"/*) [ -e "$target" ] || echo "dangling: $link" ;; *) echo "escapes package: $link -> $target" ;; esac
done)
if [ -z "$bad_links" ]; then pass "all symlinks resolve inside the package"; else fail "bad symlinks"; echo "$bad_links" | indent; fi

# -- ELF contract -----------------------------------------------------------------
section "ELF files (architecture, interpreter, dependencies)"
elf_field() { sed -n "$2" <<<"$1" | head -1; }
elf_count=0 inspected=""
while IFS= read -r file; do
    [ "$(od -An -tx1 -N4 "$file" | tr -d ' \n')" = "7f454c46" ] || continue
    rel="${file#"${TC}"/}"
    elf_count=$((elf_count + 1))
    if ! info=$("$READELF" -h -l -d "$file" 2>&1); then fail "${rel}: cannot inspect"; printf '%s\n' "$info" | indent; continue; fi
    type=$(elf_field "$info" 's/^ *Type: *\([A-Z]*\).*/\1/p')
    machine=$(elf_field "$info" 's/^ *Machine: *//p')
    interp=$(elf_field "$info" 's/.*Requesting program interpreter: \(.*\)\]/\1/p')
    needed=$(sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' <<<"$info" | sort | tr '\n' ' ')
    soname=$(elf_field "$info" 's/.*Library soname: \[\(.*\)\]/\1/p')
    rpath=$(sed -n 's/.*(RPATH).*\[\(.*\)\]/\1/p' <<<"$info")
    runpath=$(sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p' <<<"$info")
    problems=""
    case "$machine" in *"$MACHINE"*) ;; *) problems+=" machine='${machine}'" ;; esac
    if [ "$type" = REL ]; then
        [ -z "$interp$needed$rpath$runpath" ] || problems+=" relocatable file with dynamic info"
    else
        [ "$needed" = "${MUSL_SONAME} " ] || problems+=" NEEDED='${needed}' (expected only ${MUSL_SONAME})"
        # LLVM's install rules add the origin-relative $ORIGIN/../lib; anything else
        # (absolute paths, DT_RPATH) would leak build-machine locations.
        [ -z "$rpath" ] || problems+=" DT_RPATH='${rpath}'"
        # shellcheck disable=SC2016  # a literal $ORIGIN, not a variable
        [ -z "$runpath" ] || [ "$runpath" = '$ORIGIN/../lib' ] || problems+=" RUNPATH='${runpath}'"
        case "$rel" in
            bin/*) [ "$interp" = "$MUSL_INTERP" ] || problems+=" interpreter='${interp}'" ;;
            lib/*.so*)
                [ "$type" = DYN ] || problems+=" type=${type}, not a shared object"
                [ -z "$interp" ] || problems+=" shared library has an interpreter"
                [ -n "$soname" ] || problems+=" no SONAME" ;;
            *) problems+=" unexpected ELF executable/library location" ;;
        esac
    fi
    inspected+=" ${rel} "
    if [ -z "$problems" ]; then pass "${rel}: ${type} ${MACHINE} ${interp:+interp=$interp }${needed:+needs ${needed}}"; else fail "${rel}:${problems}"; fi
done < <(find "$TC" -type f | LC_ALL=C sort)
# Aliases are symlinks, so these are the real files behind every shipped tool.
for required in bin/clang-${MAJOR} bin/lld bin/llvm-ar bin/llvm-nm bin/llvm-objcopy bin/llvm-objdump bin/llvm-readobj \
                bin/llvm-size bin/llvm-strings bin/llvm-symbolizer lib/libclang.so.${LLVM_VERSION} lib/libLTO.so.${MAJOR}.1; do
    case "$inspected" in *" ${required} "*) ;; *) fail "ELF audit did not cover ${required}" ;; esac
done
pass "ELF audit covered ${elf_count} files"

# Runtime archives hold ELF objects too: every member must be for this architecture
# (an x86-64 package must not carry i386 builtins, for example).
section "Runtime archives"
for archive in "lib/clang/${MAJOR}/lib/linux/libclang_rt.builtins-${LLVM_ARCH}.a" lib/libc++.a lib/libc++abi.a \
               lib/libunwind.a lib/libc++experimental.a; do
    machines=$("$READELF" -h "${TC}/${archive}" 2>&1 | sed -n 's/^ *Machine: *//p' | sort -u)
    if [ -n "$machines" ] && [ "$(wc -l <<<"$machines")" -eq 1 ] && [[ "$machines" == *"$MACHINE"* ]]; then
        pass "${archive}: only ${MACHINE} objects"
    else
        fail "${archive}: machines found: ${machines:-none}"
    fi
done
# libc++.a carries the libc++abi objects so that the driver's default -lc++ links.
verdict "libc++.a contains the libc++abi objects" grep -q '__cxa_throw' <("${TC}/bin/llvm-nm" --defined-only "${TC}/lib/libc++.a" 2>&1)

# -- tools start and identify themselves -------------------------------------------
section "Tools"
out=$("$CLANG" --version 2>&1)
contains "clang reports version ${LLVM_VERSION}" "$out" "clang version ${LLVM_VERSION}"
contains "clang defaults to a musl target" "$out" "Target: ${LLVM_ARCH}-unknown-linux-musl"
contains "clang runs from the relocated prefix" "$out" "InstalledDir: ${TC}/bin"
contains "clang picks up its config file" "$out" "Configuration file: ${TC}/bin/clang.cfg"
out=$("${TC}/bin/ld.lld" --version 2>&1)
contains "ld.lld reports version ${LLVM_VERSION}" "$out" "LLD ${LLVM_VERSION}"
for tool in llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-ranlib llvm-readelf llvm-readobj llvm-size llvm-strings \
            llvm-strip llvm-symbolizer; do
    if out=$("${TC}/bin/${tool}" --version 2>&1); then contains "${tool} reports LLVM ${LLVM_VERSION}" "$out" "${LLVM_VERSION}"
    else fail "${tool} --version"; printf '%s\n' "$out" | indent; fi
done
# Both compiled-in backends, without a non-native sysroot.
for pair in "${TRIPLE}:${MACHINE}" "${OTHER_TRIPLE}:${OTHER_MACHINE}"; do
    triple="${pair%%:*}" machine="${pair##*:}"
    obj="${WORK}/backend-${triple}.o"
    if out=$("$CLANG" --target="$triple" -ffreestanding -nostdinc -O2 -c "${TESTS}/probe/backend.c" -o "$obj" 2>&1); then
        contains "compile for ${triple}" "$("$READELF" -h "$obj" 2>&1)" "$machine"
    else fail "compile for ${triple}"; printf '%s\n' "$out" | indent; fi
done

# -- driver defaults --------------------------------------------------------------
section "Driver defaults (no options besides the target)"
cat > "${WORK}/probe.cpp" <<'EOF'
int main() {}
EOF
plan=$("$CLANGXX" "${COMMON[@]}" -### "${WORK}/probe.cpp" -o "${WORK}/probe" 2>&1)
contains "resource directory is inside the package" "$("$CLANG" -print-resource-dir)" "$RES"
contains "libc++ headers come from the package" "$plan" "\"${TC}/bin/../include/c++/v1\""
contains "linker is the package's ld.lld" "$plan" "\"${TC}/bin/ld.lld\""
contains "libc++ is the default C++ library" "$plan" '"-lc++"'
contains "libunwind is the default unwinder" "$plan" '"-lunwind"'
contains "compiler-rt builtins are the default runtime" "$plan" "\"${BUILTINS}\""
contains "compiler-rt startup files are used" "$plan" "\"${RES}/lib/linux/clang_rt.crtbegin-${LLVM_ARCH}.o\""
contains "startup files end with compiler-rt's" "$plan" "\"${RES}/lib/linux/clang_rt.crtend-${LLVM_ARCH}.o\""
contains "package lib/ is on the library path" "$plan" "\"-L${TC}/bin/../lib\""
lacks "no libstdc++" "$plan" "stdc++"
lacks "no libgcc" "$plan" "-lgcc"
lacks "no GCC installation" "$plan" "/usr/lib/gcc"

# -- programs that compile, link, and run ------------------------------------------
# build_run <name> <expected-file> <compiler> <args...>: build, run natively, and
# compare stdout. Output of failing steps is shown; nothing is discarded.
build_run() {
    local name="$1" expected="$2" driver="$3" out actual rc
    shift 3
    local exe="${WORK}/${name}"
    if ! out=$("$driver" "$@" -o "$exe" 2>&1); then fail "${name}: build"; printf '%s\n' "$out" | indent; return 1; fi
    [ -z "$out" ] || printf '  note: %s build output:\n%s\n' "$name" "$(printf '%s\n' "$out" | indent)"
    actual=$("$exe" 2>"${exe}.stderr"); rc=$?
    if [ "$rc" -ne 0 ]; then fail "${name}: run exited ${rc}"; { printf '%s\n' "$actual"; cat "${exe}.stderr"; } | indent; return 1; fi
    if diff -u "$expected" <(printf '%s\n' "$actual") >"${exe}.diff"; then pass "${name}: builds, runs, output matches"; else
        fail "${name}: unexpected output"; indent < "${exe}.diff"; return 1; fi
}

# expect_linkage <name> dynamic|static: the produced executable's ELF shape.
expect_linkage() {
    local exe="${WORK}/$1" info interp needed
    info=$("$READELF" -h -l -d "$exe" 2>&1)
    interp=$(elf_field "$info" 's/.*Requesting program interpreter: \(.*\)\]/\1/p')
    needed=$(sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' <<<"$info" | sort | tr '\n' ' ')
    if [ "$2" = dynamic ]; then
        if [ "$interp" = "$MUSL_INTERP" ] && [ "$needed" = "${MUSL_SONAME} " ]; then pass "$1: dynamic, musl only"; else
            fail "$1: expected dynamic musl; interpreter='${interp}' needed='${needed}'"; fi
    else
        if [ -z "$interp" ] && [ -z "$needed" ]; then pass "$1: fully static"; else
            fail "$1: expected static; interpreter='${interp}' needed='${needed}'"; fi
    fi
}

# The explicit invocation documented in the README.
DOCUMENTED=(-stdlib=libc++ --unwindlib=libunwind -cxx-isystem "${TC}/include/c++/v1" -L "${TC}/lib" -lc++abi -lunwind)
# Every default spelled out.
EXPLICIT=(-stdlib=libc++ --rtlib=compiler-rt --unwindlib=libunwind -fuse-ld=lld)

section "C programs"
build_run c-default "${TESTS}/c/hello.expected" "$CLANG" "${COMMON[@]}" -O2 "${TESTS}/c/hello.c" && expect_linkage c-default dynamic
build_run c-static "${TESTS}/c/hello.expected" "$CLANG" "${COMMON[@]}" -O2 -static "${TESTS}/c/hello.c" && expect_linkage c-static static
build_run c-explicit "${TESTS}/c/hello.expected" "$CLANG" "${COMMON[@]}" -O2 --rtlib=compiler-rt -fuse-ld=lld "${TESTS}/c/hello.c"
# No options at all: the compiler's own target and sysroot search.
build_run c-bare "${TESTS}/c/hello.expected" "$CLANG" -O2 "${TESTS}/c/hello.c"

section "C++ programs (libc++, libc++abi, libunwind, compiler-rt)"
build_run cxx-default "${TESTS}/cxx/features.expected" "$CLANGXX" "${COMMON[@]}" "${CXXFLAGS[@]}" "${TESTS}/cxx/features.cpp" &&
    expect_linkage cxx-default dynamic
build_run cxx-static "${TESTS}/cxx/features.expected" "$CLANGXX" "${COMMON[@]}" "${CXXFLAGS[@]}" -static "${TESTS}/cxx/features.cpp" &&
    expect_linkage cxx-static static
build_run cxx-explicit "${TESTS}/cxx/features.expected" "$CLANGXX" "${COMMON[@]}" "${CXXFLAGS[@]}" "${EXPLICIT[@]}" "${TESTS}/cxx/features.cpp"
build_run cxx-documented "${TESTS}/cxx/features.expected" "$CLANGXX" "${COMMON[@]}" "${CXXFLAGS[@]}" "${DOCUMENTED[@]}" "${TESTS}/cxx/features.cpp"
build_run cxx-documented-static "${TESTS}/cxx/features.expected" "$CLANGXX" "${COMMON[@]}" "${CXXFLAGS[@]}" -static "${DOCUMENTED[@]}" "${TESTS}/cxx/features.cpp"
build_run cxx-bare "${TESTS}/cxx/features.expected" "$CLANGXX" "${CXXFLAGS[@]}" "${TESTS}/cxx/features.cpp"
build_run cxx-O0 "${TESTS}/cxx/features.expected" "$CLANGXX" "${COMMON[@]}" -std=c++20 -O0 -g "${TESTS}/cxx/features.cpp"
# Found through PATH, the way users invoke it.
build_run cxx-path "${TESTS}/cxx/features.expected" env PATH="${TC}/bin:${PATH}" clang++ "${COMMON[@]}" "${CXXFLAGS[@]}" "${TESTS}/cxx/features.cpp"

# -- ThinLTO ----------------------------------------------------------------------
section "ThinLTO (multi-translation-unit)"
lto_sources=(lto_main.cpp lto_math.cpp lto_text.cpp)
lto_compile() {  # <dir> <extra flags...>: compile the three TUs
    local dir="$1"
    shift
    mkdir -p "$dir"
    for src in "${lto_sources[@]}"; do
        "$CLANGXX" "${COMMON[@]}" -std=c++20 -O2 "$@" -c "${TESTS}/lto/${src}" -o "${dir}/${src%.cpp}.o" || return 1
    done
}
main_calls_math() {  # does main's disassembly mention scale_and_offset? (exe)
    local text
    text=$("${TC}/bin/llvm-objdump" -d --no-show-raw-insn --disassemble-symbols=main "$1") || return 2
    grep -q scale_and_offset <<<"$text"
}
for mode in dynamic static; do
    dir="${WORK}/lto-${mode}"
    flags=(-flto=thin)
    linkflags=(-flto=thin -Rpass=inline)
    [ "$mode" = static ] && linkflags+=(-static)
    if ! out=$(lto_compile "$dir" "${flags[@]}" 2>&1); then fail "lto-${mode}: compile"; printf '%s\n' "$out" | indent; continue; fi
    magic=$(od -An -tx1 -N4 "${dir}/lto_math.o" | tr -d ' \n')
    verdict "lto-${mode}: objects are bitcode (magic ${magic})" test "$magic" = "4243c0de"
    if ! out=$("$CLANGXX" "${COMMON[@]}" "${linkflags[@]}" "${dir}"/*.o -o "${dir}/app" 2>&1); then
        fail "lto-${mode}: link"; printf '%s\n' "$out" | indent; continue; fi
    contains "lto-${mode}: ThinLTO inlined across translation units" "$out" "scale_and_offset"
    actual=$("${dir}/app" 2>&1); rc=$?
    if [ "$rc" -eq 0 ] && [ "$actual" = "$(cat "${TESTS}/lto/lto.expected")" ]; then pass "lto-${mode}: runs, output matches"; else
        fail "lto-${mode}: run exited ${rc}: ${actual}"; fi
    main_calls_math "${dir}/app"; rc=$?
    case "$rc" in
        0) fail "lto-${mode}: main still refers to scale_and_offset" ;;
        1) pass "lto-${mode}: main no longer refers to scale_and_offset" ;;
        *) fail "lto-${mode}: could not disassemble main" ;;
    esac
done
# Control: without LTO the call survives, so the check above can fail.
if lto_compile "${WORK}/nolto" && "$CLANGXX" "${COMMON[@]}" "${WORK}"/nolto/*.o -o "${WORK}/nolto/app" 2>&1 &&
   main_calls_math "${WORK}/nolto/app"; then pass "control: without LTO main calls scale_and_offset"; else fail "control build without LTO"; fi

# -- LLVM utilities and zlib ------------------------------------------------------
section "LLVM utilities"
u="${WORK}/util"
mkdir -p "$u"
if out=$("$CLANG" "${COMMON[@]}" -g -O0 -c "${TESTS}/c/hello.c" -o "${u}/hello.o" 2>&1); then pass "compile with debug info"; else
    fail "compile with debug info"; printf '%s\n' "$out" | indent; fi
contains "llvm-nm lists main" "$("${TC}/bin/llvm-nm" "${u}/hello.o" 2>&1)" " T main"
contains "llvm-objdump disassembles main" "$("${TC}/bin/llvm-objdump" -d "${u}/hello.o" 2>&1)" "<main>:"
contains "llvm-readobj reads the object" "$("${TC}/bin/llvm-readobj" --file-headers "${u}/hello.o" 2>&1)" "Format: elf64"
check "llvm-objcopy copies an object" "${TC}/bin/llvm-objcopy" "${u}/hello.o" "${u}/copy.o"

# zlib: compress with objcopy, then make lld and llvm-symbolizer actually read it.
check "llvm-objcopy compresses debug sections (zlib)" "${TC}/bin/llvm-objcopy" --compress-debug-sections=zlib "${u}/hello.o" "${u}/hello.gz.o"
debug_info_flags() { "$READELF" -SW "$1" | grep -E '\] \.debug_info '; }  # section header line
compressed() { [[ "$(debug_info_flags "$1")" =~ [[:space:]]C[[:space:]] ]]; }
verdict ".debug_info is stored compressed" compressed "${u}/hello.gz.o"
check "llvm-objcopy decompresses debug sections" "${TC}/bin/llvm-objcopy" --decompress-debug-sections "${u}/hello.gz.o" "${u}/hello.plain.o"
if [ -n "$(debug_info_flags "${u}/hello.plain.o")" ] && ! compressed "${u}/hello.plain.o"; then pass "decompressed object is plain"; else
    fail "decompressed object is missing .debug_info or still compressed"; fi
symbolize() {  # <exe>: file:line of main
    local addr
    addr=$("${TC}/bin/llvm-nm" "$1" | awk '$3 == "main" { print "0x" $1 }')
    "${TC}/bin/llvm-symbolizer" --obj="$1" "$addr"
}
if out=$("$CLANG" "${COMMON[@]}" "${u}/hello.gz.o" -o "${u}/from-compressed" 2>&1); then
    contains "lld links compressed debug input; symbolizer resolves main to hello.c" "$(symbolize "${u}/from-compressed")" "hello.c"
else fail "lld link of a compressed-debug object"; printf '%s\n' "$out" | indent; fi
if out=$("$CLANG" "${COMMON[@]}" -g -gz=zlib "${TESTS}/c/hello.c" -Wl,--compress-debug-sections=zlib -o "${u}/gz-output" 2>&1); then
    verdict "lld wrote compressed debug sections" compressed "${u}/gz-output"
    contains "llvm-symbolizer reads zlib-compressed debug info" "$(symbolize "${u}/gz-output")" "hello.c"
else fail "-gz=zlib compile and link"; printf '%s\n' "$out" | indent; fi

# strip, strings, size on a linked executable
"$CLANG" "${COMMON[@]}" -g "${TESTS}/c/hello.c" -o "${u}/hello" 2>&1 | indent
contains "llvm-strings finds text in the executable" "$("${TC}/bin/llvm-strings" "${u}/hello")" "hello from C"
contains "llvm-size reports sections" "$("${TC}/bin/llvm-size" "${u}/hello")" "text"
check "llvm-strip strips an executable" "${TC}/bin/llvm-strip" --strip-all "${u}/hello" -o "${u}/hello.stripped"
verdict "stripped executable is smaller" test "$(stat -c %s "${u}/hello.stripped")" -lt "$(stat -c %s "${u}/hello")"
if out=$("${u}/hello.stripped" 2>&1); then pass "stripped executable still runs"; else fail "stripped executable failed"; printf '%s\n' "$out" | indent; fi

# archives: create, index, and link against one
cat > "${u}/lib.c" <<'EOF'
int from_archive(void) { return 42; }
EOF
cat > "${u}/use.c" <<'EOF'
int from_archive(void);
int main(void) { return from_archive() == 42 ? 0 : 1; }
EOF
"$CLANG" "${COMMON[@]}" -c "${u}/lib.c" -o "${u}/lib.o" && "$CLANG" "${COMMON[@]}" -c "${u}/use.c" -o "${u}/use.o"
check "llvm-ar creates an archive" "${TC}/bin/llvm-ar" rc "${u}/libfoo.a" "${u}/lib.o"
check "llvm-ranlib indexes it" "${TC}/bin/llvm-ranlib" "${u}/libfoo.a"
contains "archive has a symbol index" "$("${TC}/bin/llvm-nm" --print-armap "${u}/libfoo.a" 2>&1)" "from_archive in lib.o"
if out=$("$CLANG" "${COMMON[@]}" "${u}/use.o" -L"$u" -lfoo -o "${u}/use" 2>&1) && "${u}/use"; then pass "link against the archive and run"; else
    fail "link against the archive"; printf '%s\n' "$out" | indent; fi

# -- libclang ---------------------------------------------------------------------
section "libclang"
if out=$("$CLANG" "${COMMON[@]}" -I"${TC}/include" "${TESTS}/libclang/parse.c" -L"${TC}/lib" -lclang \
        -Wl,-rpath,"${TC}/lib" -o "${WORK}/parse-client" 2>&1); then
    actual=$("${WORK}/parse-client" 2>&1); rc=$?
    if [ "$rc" -eq 0 ] && [ "$actual" = "$(cat "${TESTS}/libclang/parse.expected")" ]; then pass "libclang client parses a translation unit with a resource header"; else
        fail "libclang client (exit ${rc})"; printf '%s\n' "$actual" | indent; fi
else fail "build libclang client"; printf '%s\n' "$out" | indent; fi

echo
echo "=== Validation of ${LLVM_VERSION} ${LLVM_ARCH}: ${passed} passed, ${failed} failed ==="
[ "$failed" -eq 0 ] || { echo "Validation FAILED" >&2; exit 1; }
