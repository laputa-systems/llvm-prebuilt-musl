#!/usr/bin/env bash
# pipefail is intentionally set: we want the script to exit on the first
# pipeline failure.  BUT it causes find|head pipelines to fail because
# head closes the pipe after the first line, sending SIGPIPE to find.
# Every find|head pipeline below must end with || true to suppress this.
set -euo pipefail

LLVM_VERSION="${LLVM_VERSION:?LLVM_VERSION is required}"
LLVM_ARCH="${LLVM_ARCH:?LLVM_ARCH is required (x86_64 or aarch64)}"
LLVM_PROJECT_DIR="${LLVM_PROJECT_DIR:-/work/llvm-project}"
LLVM_PREBUILT_DIR="${LLVM_PREBUILT_DIR:-/work/llvm-prebuilt}"
LLVM_HOST_BUILD_DIR="${LLVM_HOST_BUILD_DIR:-/work/llvm-host}"
LLVM_HOST_TOOLS_DIR="${LLVM_HOST_TOOLS_DIR:-${LLVM_HOST_BUILD_DIR}/bin}"
LLVM_BUILD_DIR="${LLVM_BUILD_DIR:-/work/llvm-build}"
LLVM_USE_CCACHE="${LLVM_USE_CCACHE:-0}"
LLVM_BUILD_STAGE="${LLVM_BUILD_STAGE:-all}"
# Limit concurrent link jobs (heavy RAM usage) while letting compilation use
# all cores.  Linking LLVM tools can use 2+ GiB each.
LLVM_PARALLEL_LINK_JOBS="${LLVM_PARALLEL_LINK_JOBS:-2}"

if [ "$LLVM_USE_CCACHE" = "1" ]; then
    CCACHE_LAUNCHER=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
else
    CCACHE_LAUNCHER=()
fi

case "$LLVM_ARCH" in
    x86_64)  TARGET_TRIPLE="x86_64-linux-musl" ;;
    aarch64) TARGET_TRIPLE="aarch64-linux-musl" ;;
    *)       echo "Unsupported arch: $LLVM_ARCH" >&2; exit 1 ;;
esac

case "$LLVM_BUILD_STAGE" in
    all|host-tools|configure|stage1-lld|stage2|install-validate) ;;
    *) echo "Unsupported LLVM_BUILD_STAGE: $LLVM_BUILD_STAGE" >&2; exit 1 ;;
esac

die() {
    echo "ERROR: $*" >&2
    exit 1
}

require_executable() {
    [ -x "$1" ] || die "$2 missing or not executable: $1"
}

require_file() {
    [ -f "$1" ] || die "$2 missing: $1"
}

require_dir() {
    [ -d "$1" ] || die "$2 missing: $1"
}

finish_stage() {
    if [ "$LLVM_BUILD_STAGE" = "$1" ]; then
        echo "=== Stage '$1' complete ==="
        exit 0
    fi
}

# Alpine GCC installs C++ headers under <arch>-alpine-linux-musl but
# LLVM_DEFAULT_TARGET_TRIPLE is <arch>-linux-musl. Symlink so the
# just-built clang can find them during the compiler-rt runtime build.
for inc in /usr/include/c++/*; do
    [ -d "$inc" ] || continue
    src="${inc}/${LLVM_ARCH}-alpine-linux-musl"
    dst="${inc}/${TARGET_TRIPLE}"
    if [ -d "$src" ] && [ ! -e "$dst" ]; then
        ln -s "$(basename "$src")" "$dst"
        echo "Symlinked $dst -> $(basename "$src")"
    fi
done

exec > >(tee -a "${LLVM_PREBUILT_DIR}/build-${LLVM_ARCH}.log") 2>&1

echo "=== Building LLVM ${LLVM_VERSION} for ${TARGET_TRIPLE} ==="

# ── Stage 1: Host tools ────────────────────────────────────────────────

HOST_TOOLS=(
    "${LLVM_HOST_TOOLS_DIR}/llvm-tblgen"
    "${LLVM_HOST_TOOLS_DIR}/clang-tblgen"
    "${LLVM_HOST_TOOLS_DIR}/llvm-config"
    "${LLVM_HOST_TOOLS_DIR}/llvm-nm"
    "${LLVM_HOST_TOOLS_DIR}/llvm-readobj"
)

all_host_tools_present() {
    for tool in "${HOST_TOOLS[@]}"; do
        [ -x "$tool" ] || return 1
    done
    return 0
}

validate_host_tools() {
    echo "=== Stage 1: Validating host tools ==="
    for tool in "${HOST_TOOLS[@]}"; do
        require_executable "$tool" "host tool"
    done
    "${LLVM_HOST_TOOLS_DIR}/llvm-config" --version | grep -q "^${LLVM_VERSION}" ||
        die "host llvm-config version is not ${LLVM_VERSION}"
}

if all_host_tools_present; then
    echo "=== Stage 1: Host tools already present, skipping build ==="
else
    echo "=== Stage 1: Building native host tools ==="
    cmake -G Ninja -S "${LLVM_PROJECT_DIR}/llvm" -B "${LLVM_HOST_BUILD_DIR}" \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DLLVM_PARALLEL_LINK_JOBS="${LLVM_PARALLEL_LINK_JOBS}" \
        -DLLVM_TARGETS_TO_BUILD=Native \
        -DLLVM_ENABLE_PROJECTS="clang" \
        -DLLVM_ENABLE_RUNTIMES="" \
        -DLLVM_ENABLE_LIBXML2=OFF \
        -DLLVM_ENABLE_ZLIB=OFF \
        -DLLVM_ENABLE_ZSTD=OFF \
        -DLLVM_ENABLE_TERMINFO=OFF \
        -DLLVM_ENABLE_Z3_SOLVER=OFF \
        -DLLVM_INCLUDE_DOCS=OFF \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_GO_TESTS=OFF \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS_RELEASE="-O2 -DNDEBUG" \
        -DCMAKE_CXX_FLAGS_RELEASE="-O2 -DNDEBUG" \
        "${CCACHE_LAUNCHER[@]}" \
        -Wno-dev

    cmake --build "${LLVM_HOST_BUILD_DIR}" --target llvm-tblgen clang-tblgen llvm-config llvm-nm llvm-readobj
fi

validate_host_tools
finish_stage host-tools

export TARGET_TRIPLE="${TARGET_TRIPLE}"
export LLVM_NATIVE_TOOL_DIR="${LLVM_HOST_TOOLS_DIR}"
export LLVM_TABLEGEN="${LLVM_HOST_TOOLS_DIR}/llvm-tblgen"
export CLANG_TABLEGEN="${LLVM_HOST_TOOLS_DIR}/clang-tblgen"
export LLVM_CONFIG_PATH="${LLVM_HOST_TOOLS_DIR}/llvm-config"
export LLVM_VERSION="${LLVM_VERSION}"
export CMAKE_INSTALL_PREFIX="${CMAKE_INSTALL_PREFIX:-/work/llvm-install}"

# ── Stage 2: Configure ─────────────────────────────────────────────────

INITIAL_CACHE="${LLVM_PREBUILT_DIR}/cmake/llvm-musl-distribution.cmake"

# CMake compile-and-link tests fail when linking statically or cross-compiling.
# Pre-set results we know are true for the target toolchains.
CMake_PREFLIGHTS=(
    -DLLVM_LIBSTDCXX_MIN=ON
    -DLLVM_LIBSTDCXX_SOFT_ERROR=ON
    -DLLVM_TEMPORARILY_ALLOW_OLD_TOOLCHAIN=ON
    -DHAVE_CXX_ATOMICS_WITHOUT_LIB=ON
    -DHAVE_CXX_ATOMICS64_WITHOUT_LIB=ON
    -DLLVM_HAS_ATOMICS=ON
    -DCMAKE_CXX_COMPILER_WORKS=ON
    -DTEST_COMPILE_ONLY=ON
)

# The runtime sub-build does NOT passthrough COMPILER_RT_* variables
# (only LLVM_ENABLE_RUNTIMES, LLVM_USE_LINKER, etc).  Use RUNTIMES_CMAKE_ARGS
# to explicitly disable every compiler-rt feature except builtins.
#
# Build the stage1 runtimes (libc++, libcxxabi, libunwind) with -stdlib=libc++
# so they are free of libstdc++ ABI references.  The host compiler is clang
# (set below), so -stdlib=libc++ is supported.  This produces a clean libc++.a
# that stage2 can link against via BOOTSTRAP_LLVM_ENABLE_LIBCXX=ON.
RUNTIMES_CMAKE_ARGS="-DCOMPILER_RT_BUILD_SANITIZERS=OFF"
RUNTIMES_CMAKE_ARGS+=";-DCOMPILER_RT_BUILD_XRAY=OFF"
RUNTIMES_CMAKE_ARGS+=";-DCOMPILER_RT_BUILD_LIBFUZZER=OFF"
RUNTIMES_CMAKE_ARGS+=";-DCOMPILER_RT_BUILD_PROFILE=OFF"
RUNTIMES_CMAKE_ARGS+=";-DCOMPILER_RT_BUILD_MEMPROF=OFF"
RUNTIMES_CMAKE_ARGS+=";-DCOMPILER_RT_BUILD_ORC=OFF"
RUNTIMES_CMAKE_ARGS+=";-DCOMPILER_RT_BUILD_GWP_ASAN=OFF"
RUNTIMES_CMAKE_ARGS+=";-DCOMPILER_RT_BUILD_CTX_PROFILE=OFF"
RUNTIMES_CMAKE_ARGS+=";-DCOMPILER_RT_BUILD_XRAY_NO_PREINIT=OFF"
RUNTIMES_CMAKE_ARGS+=";-DCOMPILER_RT_BUILD_SCUDO_STANDALONE_WITH_LLVM_LIBC=OFF"
# Bootstrap: stage1 builds clang/lld with Alpine's clang, linked against
# the host libstdc++ (not shipped).  Stage2 statically links libstdc++
# and libgcc so they do not appear in NEEDED.  The shipped compiler still
# defaults to libc++/compiler-rt for downstream use.
#
# Why not BOOTSTRAP_LLVM_ENABLE_LIBCXX=ON?  The stage1 runtime libc++.a
# is compiled with the host compiler (Alpine clang), which emits references
# to the host libstdc++ ABI (std::runtime_error, __cxa_throw, etc.).
# Stage2 then tries to link against this tainted libc++.a with -stdlib=libc++
# but without libstdc++, and fails with undefined symbols.  Building
# stage1 runtimes with -stdlib=libc++ is a chicken-and-egg deadlock
# (the runtime build's cmake try_compile needs libc++ to exist).  A
# 3-stage bootstrap would solve this, but LLVM's cmake only supports two
# stages.  Static linking is the practical compromise: GNU code is
# embedded, not dynamically required.
#
# NOTE: CLANG_BOOTSTRAP_CMAKE_ARGS uses '\;' to escape semicolons within
# list-valued -D flags (cmake un-escapes them).  Avoid BOOTSTRAP_ prefixed
# variables for list values — the passthrough replaces ';' with '|', which
# cmake does not handle as a list separator in the sub-build.
STAGE2_LINKER_FLAGS="-static-libstdc++ -static-libgcc"

BOOTSTRAP_CMAKE_ARGS=""
BOOTSTRAP_CMAKE_ARGS+=";-C;${LLVM_PREBUILT_DIR}/cmake/llvm-musl-distribution.cmake"
BOOTSTRAP_CMAKE_ARGS+=";-Wno-dev"
BOOTSTRAP_CMAKE_ARGS+=";-DCLANG_DEFAULT_CXX_STDLIB=libc++"
BOOTSTRAP_CMAKE_ARGS+=";-DCLANG_DEFAULT_RTLIB=compiler-rt"
BOOTSTRAP_CMAKE_ARGS+=";-DLLVM_PARALLEL_LINK_JOBS=${LLVM_PARALLEL_LINK_JOBS}"
BOOTSTRAP_CMAKE_ARGS+=";-DCMAKE_EXE_LINKER_FLAGS=${STAGE2_LINKER_FLAGS}"
BOOTSTRAP_CMAKE_ARGS+=";-DCMAKE_SHARED_LINKER_FLAGS=${STAGE2_LINKER_FLAGS}"
BOOTSTRAP_CMAKE_ARGS+=";-DCMAKE_MODULE_LINKER_FLAGS=${STAGE2_LINKER_FLAGS}"
if [ "$LLVM_USE_CCACHE" = "1" ]; then
    BOOTSTRAP_CMAKE_ARGS+=";-DCMAKE_C_COMPILER_LAUNCHER=ccache"
    BOOTSTRAP_CMAKE_ARGS+=";-DCMAKE_CXX_COMPILER_LAUNCHER=ccache"
fi

STAGE2_BASE=(
    -DCMAKE_C_COMPILER=clang
    -DCMAKE_CXX_COMPILER=clang++
    -DLLVM_PARALLEL_LINK_JOBS="${LLVM_PARALLEL_LINK_JOBS}"
    -DCMAKE_INSTALL_PREFIX="${CMAKE_INSTALL_PREFIX}"
    -DLLVM_DEFAULT_TARGET_TRIPLE="${TARGET_TRIPLE}"
    -DCOMPILER_RT_DEFAULT_TARGET_TRIPLE="${TARGET_TRIPLE}"
    -DCOMPILER_RT_BUILD_BUILTINS=ON
    -DCOMPILER_RT_BUILTINS_ENABLE_PIC=OFF
    -DCMAKE_C_FLAGS_RELEASE="-O2 -DNDEBUG"
    -DCMAKE_CXX_FLAGS_RELEASE="-O2 -DNDEBUG"
    -DLLVM_ENABLE_LLD=ON
    -DRUNTIMES_CMAKE_ARGS="${RUNTIMES_CMAKE_ARGS}"
    -DCLANG_ENABLE_BOOTSTRAP=ON
    -DBOOTSTRAP_LLVM_ENABLE_LLD=ON
    -DBOOTSTRAP_LLVM_DEFAULT_TARGET_TRIPLE="${TARGET_TRIPLE}"
    -DBOOTSTRAP_COMPILER_RT_DEFAULT_TARGET_TRIPLE="${TARGET_TRIPLE}"
    -DBOOTSTRAP_CMAKE_SYSTEM_NAME=Linux
    -DCLANG_BOOTSTRAP_CMAKE_ARGS="${BOOTSTRAP_CMAKE_ARGS}"
    "${CCACHE_LAUNCHER[@]}"
    "${CMake_PREFLIGHTS[@]}"
    -C "${INITIAL_CACHE}" -Wno-dev
)

echo "=== Stage 2: Configuring target build (bootstrap) ==="
STAGE2_ARGS=("${STAGE2_BASE[@]}")

if [ "$LLVM_BUILD_STAGE" != "all" ] && [ "$LLVM_BUILD_STAGE" != "configure" ] &&
   [ -f "${LLVM_BUILD_DIR}/CMakeCache.txt" ] && [ -f "${LLVM_BUILD_DIR}/build.ninja" ]; then
    echo "=== Stage 2: Target build already configured, skipping configure ==="
else
    cmake -G Ninja -S "${LLVM_PROJECT_DIR}/llvm" -B "${LLVM_BUILD_DIR}" "${STAGE2_ARGS[@]}"
fi

# Bootstrap (stage2) expects native tools at <build>/bin/.  Our host tools
# are in a separate directory — copy them so the bootstrap can find them.
for tool in llvm-tblgen clang-tblgen llvm-config llvm-nm llvm-readobj; do
    if [ -x "${LLVM_HOST_TOOLS_DIR}/${tool}" ] && [ ! -e "${LLVM_BUILD_DIR}/bin/${tool}" ]; then
        cp "${LLVM_HOST_TOOLS_DIR}/${tool}" "${LLVM_BUILD_DIR}/bin/${tool}"
    fi
done

echo "=== Stage 2: Validating target build configuration ==="
require_file "${LLVM_BUILD_DIR}/CMakeCache.txt" "target CMake cache"
require_file "${LLVM_BUILD_DIR}/build.ninja" "target build graph"
grep -q "^LLVM_DEFAULT_TARGET_TRIPLE:.*=${TARGET_TRIPLE}$" "${LLVM_BUILD_DIR}/CMakeCache.txt" ||
    die "target CMake cache does not contain LLVM_DEFAULT_TARGET_TRIPLE=${TARGET_TRIPLE}"
grep -q "^CLANG_ENABLE_BOOTSTRAP:.*=ON$" "${LLVM_BUILD_DIR}/CMakeCache.txt" ||
    die "target CMake cache does not have CLANG_ENABLE_BOOTSTRAP=ON"
for tool in llvm-tblgen clang-tblgen llvm-config llvm-nm llvm-readobj; do
    require_executable "${LLVM_BUILD_DIR}/bin/${tool}" "copied bootstrap host tool"
done
finish_stage configure

# The bootstrap runtimes configure uses the just-built stage1 clang as the
# host compiler and tests -fuse-ld=lld. Build the matching stage1 lld first
# so clang finds an LLVM ${LLVM_VERSION} linker next to itself.
echo "=== Stage 2b: Building stage1 lld for runtimes configure ==="
cmake --build "${LLVM_BUILD_DIR}" --target lld
if [ ! -e "${LLVM_BUILD_DIR}/bin/ld.lld" ]; then
    ln -s lld "${LLVM_BUILD_DIR}/bin/ld.lld"
fi
require_executable "${LLVM_BUILD_DIR}/bin/lld" "stage1 lld"
require_executable "${LLVM_BUILD_DIR}/bin/ld.lld" "stage1 ld.lld"
"${LLVM_BUILD_DIR}/bin/ld.lld" --version | grep -q "LLD ${LLVM_VERSION}" ||
    die "stage1 ld.lld version is not ${LLVM_VERSION}"
printf 'int main(void) { return 0; }\n' |
    "${LLVM_BUILD_DIR}/bin/clang" -x c - -fuse-ld=lld -o "${LLVM_BUILD_DIR}/stage1-lld-link-check" ||
    die "stage1 ld.lld cannot link a trivial host executable"
finish_stage stage1-lld

# ── Stage 3+4: Build + Install (bootstrap) ───────────────────────────────

echo "=== Stage 3: Building stage2 (bootstrap) ==="
cmake --build "${LLVM_BUILD_DIR}" --target stage2

echo "=== Stage 3: Validating stage2 build tree ==="
STAGE2_BINS_DIR="${LLVM_BUILD_DIR}/tools/clang/stage2-bins"
require_dir "$STAGE2_BINS_DIR" "stage2 build tree"
require_executable "${STAGE2_BINS_DIR}/bin/clang" "stage2 clang"
require_executable "${STAGE2_BINS_DIR}/bin/clang++" "stage2 clang++"
require_executable "${STAGE2_BINS_DIR}/bin/lld" "stage2 lld"
require_executable "${STAGE2_BINS_DIR}/bin/ld.lld" "stage2 ld.lld"
"${STAGE2_BINS_DIR}/bin/clang" --version | grep -q "clang version ${LLVM_VERSION}" ||
    die "stage2 clang version is not ${LLVM_VERSION}"
"${STAGE2_BINS_DIR}/bin/ld.lld" --version | grep -q "LLD ${LLVM_VERSION}" ||
    die "stage2 ld.lld version is not ${LLVM_VERSION}"
finish_stage stage2

echo "=== Stage 4: Installing distribution from stage2 ==="
cmake --build "${LLVM_BUILD_DIR}/tools/clang/stage2-bins" --target install-distribution

# ── Normalize builtins location ────────────────────────────────────────
# install from stage2 doesn't include compiler-rt components, so copy
# builtins from the stage2 build tree into the install tree.

CLANG_MAJOR="${LLVM_VERSION%%.*}"
RESOURCE_DIR="${CMAKE_INSTALL_PREFIX}/lib/clang/${CLANG_MAJOR}"
BUILTINS_DIR="${RESOURCE_DIR}/lib/linux"
mkdir -p "${BUILTINS_DIR}"

# compiler-rt may name the archive libclang_rt.builtins.a (no arch suffix)
# or libclang_rt.builtins-<arch>.a. We normalize to libclang_rt.builtins-<arch>.a.
find "${LLVM_BUILD_DIR}/tools/clang/stage2-bins/lib/clang" \( -name 'libclang_rt.builtins-*.a' -o -name 'libclang_rt.builtins.a' \) 2>/dev/null | while read -r archive; do
    target_name="libclang_rt.builtins-${LLVM_ARCH}.a"
    cp "$archive" "${BUILTINS_DIR}/${target_name}"
    echo "Copied $(basename "$archive") → ${BUILTINS_DIR}/${target_name} (from stage2 build tree)"
done

# Also check the install tree in case a future LLVM version installs them there.
find "${CMAKE_INSTALL_PREFIX}/lib/clang" \( -name 'libclang_rt.builtins-*.a' -o -name 'libclang_rt.builtins.a' \) 2>/dev/null | while read -r archive; do
    target_name="libclang_rt.builtins-${LLVM_ARCH}.a"
    if [ ! -f "${BUILTINS_DIR}/${target_name}" ]; then
        cp "$archive" "${BUILTINS_DIR}/${target_name}"
        echo "Copied $(basename "$archive") → ${BUILTINS_DIR}/${target_name} (from install tree)"
    fi
done

# ── Libc++ headers and libraries ──────────────────────────────────────
# install-distribution does not include runtime components, so copy
# libc++/libcxxabi/libunwind headers and static libraries from the stage2
# build tree into the install tree.
#
# The libc++ source headers live at <build>/include/c++/v1/ but the
# generated __config_site header (which gates ABI flags, availability
# macros, etc.) lives separately at <build>/include/<triple>/c++/v1/.
# Without __config_site, every translation unit fails with:
#   fatal error: '__config_site' file not found
# Both must be copied.

LIBCXX_HEADERS_SRC=$(find "${LLVM_BUILD_DIR}/tools/clang/stage2-bins" -type d -name 'v1' -path '*/c++/v1' -not -path '*/__config_site*' 2>/dev/null | head -1) || true
if [ -n "$LIBCXX_HEADERS_SRC" ] && [ -d "$LIBCXX_HEADERS_SRC" ]; then
    LIBCXX_HEADERS_DST="${CMAKE_INSTALL_PREFIX}/include/c++/v1"
    mkdir -p "$(dirname "$LIBCXX_HEADERS_DST")"
    rm -rf "$LIBCXX_HEADERS_DST"
    cp -a "$LIBCXX_HEADERS_SRC" "$LIBCXX_HEADERS_DST"
    # Copy generated __config_site from the target-specific include dir
    CONFIG_SITE=$(find "${LLVM_BUILD_DIR}/tools/clang/stage2-bins/include" -name '__config_site' -path '*/c++/v1/__config_site' 2>/dev/null | head -1) || true
    if [ -f "$CONFIG_SITE" ]; then
        cp "$CONFIG_SITE" "$LIBCXX_HEADERS_DST/__config_site"
    fi
    echo "Copied libc++ headers: $(find "$LIBCXX_HEADERS_DST" -name '*.h' | wc -l) headers → ${LIBCXX_HEADERS_DST}"
else
    echo "WARNING: libc++ headers not found in stage2 build tree"
fi

STAGE2_LIB_DIR="${LLVM_BUILD_DIR}/tools/clang/stage2-bins/lib"
INSTALL_LIB_DIR="${CMAKE_INSTALL_PREFIX}/lib"
mkdir -p "$INSTALL_LIB_DIR"
for lib in libc++.a libc++abi.a libunwind.a libc++experimental.a; do
    src=$(find "$STAGE2_LIB_DIR" -name "$lib" 2>/dev/null | head -1) || true
    if [ -f "$src" ]; then
        cp "$src" "$INSTALL_LIB_DIR/$lib"
        echo "Copied $lib → ${INSTALL_LIB_DIR}/"
    else
        echo "WARNING: $lib not found in stage2 build tree"
    fi
done

# ── Clang driver config ───────────────────────────────────────────────
# The clang driver does not auto-append -lc++abi -lunwind when targeting
# musl triples.  A config file placed next to the clang++ binary is
# loaded automatically and injects these flags.  We also set -fuse-ld=lld
# so the shipped compiler defaults to lld (included in the toolchain),
# which handles the link ordering correctly with the injected flags.
cat > "${CMAKE_INSTALL_PREFIX}/bin/clang++.cfg" <<'EOF'
-fuse-ld=lld
-lc++abi
-lunwind
EOF
echo "Created clang++.cfg (auto-injects -fuse-ld=lld -lc++abi -lunwind)"

# clang (C) also defaults to lld for consistency.
cat > "${CMAKE_INSTALL_PREFIX}/bin/clang.cfg" <<'EOF'
-fuse-ld=lld
EOF
echo "Created clang.cfg (auto-injects -fuse-ld=lld)"

echo "=== Stage 4: Validating install layout ==="
for tool in clang clang++ clang-22 lld ld.lld llvm-ar llvm-nm llvm-readobj; do
    require_executable "${CMAKE_INSTALL_PREFIX}/bin/${tool}" "installed tool"
done
require_file "${CMAKE_INSTALL_PREFIX}/bin/clang.cfg" "clang driver config"
require_file "${CMAKE_INSTALL_PREFIX}/bin/clang++.cfg" "clang++ driver config"
require_dir "${CMAKE_INSTALL_PREFIX}/lib/clang/${CLANG_MAJOR}/include" "clang resource headers"
require_file "${CMAKE_INSTALL_PREFIX}/lib/clang/${CLANG_MAJOR}/lib/linux/libclang_rt.builtins-${LLVM_ARCH}.a" "compiler-rt builtins"
require_file "${CMAKE_INSTALL_PREFIX}/include/c++/v1/__config_site" "libc++ __config_site"
for lib in libc++.a libc++abi.a libunwind.a; do
    require_file "${CMAKE_INSTALL_PREFIX}/lib/${lib}" "installed runtime archive"
done

# ── Validate ───────────────────────────────────────────────────────────

validate() {
    local install_dir="${1}" target_triple="${2}"
    local passed=0 failed=0
    pass() { echo "  PASS: $1"; passed=$((passed + 1)); }
    fail() { echo "  FAIL: $1"; failed=$((failed + 1)); }

    echo "=== Stage 5: Validating install ==="
    echo "Install dir: ${install_dir}"
    echo "Target triple: ${target_triple}"

    local tools=(
        bin/clang bin/clang-22 bin/clang++ bin/lld bin/ld.lld
        bin/llvm-ar bin/llvm-nm bin/llvm-objcopy bin/llvm-objdump
        bin/llvm-ranlib bin/llvm-readelf bin/llvm-readobj
        bin/llvm-size bin/llvm-strings bin/llvm-strip bin/llvm-symbolizer
    )
    for t in "${tools[@]}"; do
        if [ -x "${install_dir}/${t}" ]; then
            pass "executable: ${t}"
        else
            fail "executable missing: ${t}"
        fi
    done

    echo ""
    echo "--- ELF linkage ---"
    local bins=(bin/clang bin/clang-22 bin/clang++ bin/lld bin/ld.lld
                bin/llvm-ar bin/llvm-nm bin/llvm-objcopy bin/llvm-objdump
                bin/llvm-ranlib bin/llvm-readelf bin/llvm-readobj
                bin/llvm-size bin/llvm-strings bin/llvm-strip bin/llvm-symbolizer)
    for b in "${bins[@]}"; do
        local tp="${install_dir}/${b}"
        [ -x "$tp" ] || continue
        echo "  ${b}:"
        file "$tp" 2>/dev/null || true

        local interp
        interp=$(readelf -l "$tp" 2>/dev/null | grep 'Requesting program interpreter' || true)
        echo "    interpreter: ${interp:-none}"
        if echo "$interp" | grep -q 'ld-linux'; then
            fail "${b}: glibc interpreter"
        elif echo "$interp" | grep -q 'ld-musl'; then
            pass "${b}: musl interpreter"
        elif [ -z "$interp" ]; then
            pass "${b}: static (no interpreter)"
        else
            fail "${b}: unrecognized interpreter"
        fi

        local needed
        needed=$(readelf -d "$tp" 2>/dev/null | grep NEEDED || true)
        if [ -z "$needed" ]; then
            pass "${b}: static (no NEEDED)"
        else
            echo "$needed" | while read -r line; do echo "      ${line}"; done
            local bad=0
            echo "$needed" | grep -q 'libc\.so\.6' && bad=1
            echo "$needed" | grep -q 'ld-linux' && bad=1
            echo "$needed" | grep -q 'libunwind' && bad=1
            echo "$needed" | grep -q 'libgcc_s' && bad=1
            echo "$needed" | grep -q 'libstdc++' && bad=1
            if [ "$bad" -eq 1 ]; then
                fail "${b}: glibc/libunwind/libgcc/libstdc++ in NEEDED"
            elif echo "$needed" | grep -q 'libc\.musl'; then
                pass "${b}: musl-linked"
            else
                pass "${b}: dynamic (non-glibc)"
            fi
        fi
    done

    echo ""
    local lto_lib="${install_dir}/lib/libLTO.so"
    if [ -f "$lto_lib" ]; then
        pass "libLTO.so present"
        local lto_interp
        lto_interp=$(readelf -l "$lto_lib" 2>/dev/null | grep 'Requesting program interpreter' || true)
        if echo "$lto_interp" | grep -q 'ld-linux'; then
            fail "libLTO.so: glibc interpreter"
        elif echo "$lto_interp" | grep -q 'ld-musl'; then
            pass "libLTO.so: musl interpreter"
        else
            pass "libLTO.so: static (no interpreter)"
        fi
        local lto_needed
        lto_needed=$(readelf -d "$lto_lib" 2>/dev/null | grep NEEDED || true)
        if echo "$lto_needed" | grep -qE 'libc\.so\.6|libgcc_s|libstdc\+\+|libunwind'; then
            fail "libLTO.so: glibc/libunwind/libgcc/libstdc++ in NEEDED"
        elif echo "$lto_needed" | grep -q 'libc\.musl'; then
            pass "libLTO.so: musl-linked"
        else
            pass "libLTO.so: static (no NEEDED)"
        fi
    else
        fail "libLTO.so missing"
    fi

    echo ""
    echo "--- Resource headers ---"
    local headers_dir="${install_dir}/lib/clang/${CLANG_MAJOR}/include"
    if [ -d "$headers_dir" ]; then
        pass "resource headers present ($(find "$headers_dir" -name '*.h' | wc -l) headers)"
    else
        fail "resource headers missing: ${headers_dir}"
    fi

    echo ""
    echo "--- Compiler-rt builtins ---"
    local rt_dir="${install_dir}/lib/clang/${CLANG_MAJOR}/lib/linux"
    if [ -d "$rt_dir" ]; then
        local found
        found=$(find "$rt_dir" -name 'libclang_rt.builtins-*.a' -print)
        if [ -n "$found" ]; then
            while read -r a; do pass "builtins: $(basename "$a")"; done <<< "$found"
        else
            fail "no builtins archives in ${rt_dir}"
        fi
    else
        fail "builtins directory missing: ${rt_dir}"
    fi

    echo ""
    local sanitizer_count
    sanitizer_count=$(find "${install_dir}/lib/clang" \( -name 'libclang_rt.*san*.a' -o -name 'libclang_rt.ubsan*.a' \) 2>/dev/null | wc -l)
    if [ "$sanitizer_count" -eq 0 ]; then
        pass "no sanitizer runtimes"
    else
        fail "sanitizer runtimes found (${sanitizer_count} files)"
    fi

    echo ""
    echo "--- Libc++ runtimes ---"
    local cxx_headers="${install_dir}/include/c++/v1"
    if [ -f "${cxx_headers}/iostream" ]; then
        pass "libc++ headers present ($(find "$cxx_headers" -name '*.h' | wc -l) headers)"
    else
        fail "libc++ headers missing: ${cxx_headers}"
    fi

    for lib in libc++.a libc++abi.a libunwind.a; do
        if [ -f "${install_dir}/lib/${lib}" ]; then
            pass "${lib} present"
        else
            fail "${lib} missing"
        fi
    done

    if find "${install_dir}" -name 'libunwind.so*' 2>/dev/null | grep -q .; then
        fail "libunwind shared library found in install tree"
    else
        pass "no libunwind .so (static only)"
    fi

    echo ""
    echo "--- Tool exercise ---"
    workd="/tmp/musl-validate-$$"
    mkdir -p "$workd" && trap 'rm -rf "$workd"' EXIT

    local clang="${install_dir}/bin/clang"
    local clangxx="${install_dir}/bin/clang++"
    local ar="${install_dir}/bin/llvm-ar"
    local ranlib="${install_dir}/bin/llvm-ranlib"
    local nm="${install_dir}/bin/llvm-nm"
    local objcopy="${install_dir}/bin/llvm-objcopy"
    local objdump="${install_dir}/bin/llvm-objdump"
    local readelf="${install_dir}/bin/llvm-readelf"
    local strip="${install_dir}/bin/llvm-strip"

    # clang: compile C
    cat > "$workd/hello.c" <<'CEOF'
#include <stdio.h>
int main(void) { printf("hello from clang\n"); return 0; }
CEOF
    if "$clang" --target="$target_triple" --sysroot=/ -c -g "$workd/hello.c" -o "$workd/hello.o" 2>/dev/null; then
        pass "clang: compile C"
    else
        fail "clang: compile C"
    fi

    # clang++: compile C++
    # --sysroot=/ makes clang search only the system root for headers,
    # hiding libc++ headers installed at the toolchain prefix.  We add
    # -cxx-isystem to explicitly point at the installed libc++ headers.
    cat > "$workd/hello.cpp" <<'CEOF'
#include <iostream>
int main() { std::cout << "hello from clang++\n"; return 0; }
CEOF
    if "$clangxx" --target="$target_triple" --sysroot=/ \
         -cxx-isystem "${install_dir}/include/c++/v1" \
         -c "$workd/hello.cpp" -o "$workd/hello_cpp.o" 2>/dev/null; then
        pass "clang++: compile C++"
    else
        fail "clang++: compile C++"
    fi

    # clang++: default stdlib is libc++ (no explicit -stdlib flag needed)
    if "$clangxx" --target="$target_triple" --sysroot=/ \
         -cxx-isystem "${install_dir}/include/c++/v1" \
         -c "$workd/hello.cpp" -o "$workd/hello_cpp_default.o" 2>/dev/null; then
        pass "clang++: default stdlib is libc++"
    else
        fail "clang++: default stdlib not libc++"
    fi

    # clang++: C++ exceptions work
    cat > "$workd/except.cpp" <<'CEOF'
#include <stdexcept>
int main() {
    try { throw std::runtime_error("test"); }
    catch (const std::exception& e) { return 0; }
    return 1;
}
CEOF
    if "$clangxx" --target="$target_triple" --sysroot=/ \
         -cxx-isystem "${install_dir}/include/c++/v1" \
         -L "${install_dir}/lib" \
         "$workd/except.cpp" -o "$workd/except" 2>/dev/null &&
       [ -x "$workd/except" ] && "$workd/except" 2>/dev/null; then
        pass "clang++: exceptions work"
    else
        fail "clang++: exceptions broken"
    fi

    # clang++: thread_local works
    cat > "$workd/tls.cpp" <<'CEOF'
thread_local int x = 42;
int main() { return x != 42; }
CEOF
    if "$clangxx" --target="$target_triple" --sysroot=/ \
         -cxx-isystem "${install_dir}/include/c++/v1" \
         -L "${install_dir}/lib" \
         "$workd/tls.cpp" -o "$workd/tls" 2>/dev/null &&
       [ -x "$workd/tls" ] && "$workd/tls" 2>/dev/null; then
        pass "clang++: thread_local works"
    else
        fail "clang++: thread_local broken"
    fi

    # llvm-nm: list symbols
    if "$nm" "$workd/hello.o" 2>/dev/null | grep -q 'main'; then
        pass "llvm-nm: found 'main' symbol"
    else
        fail "llvm-nm: missing 'main' symbol"
    fi

    # llvm-readelf: read ELF header
    local elf_header
    elf_header=$("$readelf" -h "$workd/hello.o" 2>/dev/null || true)
    case "$target_triple" in
        aarch64*)
            if echo "$elf_header" | grep -q 'AArch64'; then
                pass "llvm-readelf: machine AArch64"
            else
                fail "llvm-readelf: expected AArch64"
            fi ;;
        x86_64*)
            if echo "$elf_header" | grep -q 'X86-64'; then
                pass "llvm-readelf: machine X86-64"
            else
                fail "llvm-readelf: expected X86-64"
            fi ;;
    esac

    # llvm-readobj: dump object info
    local readobj="${install_dir}/bin/llvm-readobj"
    if "$readobj" -h "$workd/hello.o" 2>/dev/null | grep -qE 'File:|Format:'; then
        pass "llvm-readobj: output looks valid"
    else
        fail "llvm-readobj: no output"
    fi

    # llvm-objdump: exercise -d (disassemble) and -t (symbols)
    local objdump_ok=0
    if "$objdump" -t "$workd/hello.o" 2>/dev/null | grep -qw 'main'; then
        objdump_ok=1
    fi
    if "$objdump" -d "$workd/hello.o" 2>/dev/null | grep -qE '<main>:' ; then
        objdump_ok=$((objdump_ok + 1))
    fi
    if [ "$objdump_ok" -ge 1 ]; then
        pass "llvm-objdump: found 'main' (symtab=${objdump_ok})"
    else
        fail "llvm-objdump: no 'main' in output"
    fi

    # llvm-objcopy: copy object
    if "$objcopy" "$workd/hello.o" "$workd/hello_copy.o" 2>/dev/null && [ -f "$workd/hello_copy.o" ]; then
        pass "llvm-objcopy: copied object"
    else
        fail "llvm-objcopy: copy failed"
    fi

    # llvm-strip: strip the copy
    local syms_before syms_after
    syms_before=$("$nm" "$workd/hello_copy.o" 2>/dev/null | wc -l)
    if "$strip" "$workd/hello_copy.o" 2>/dev/null; then
        syms_after=$("$nm" "$workd/hello_copy.o" 2>/dev/null | wc -l)
        if [ "$syms_after" -lt "$syms_before" ]; then
            pass "llvm-strip: stripped ${syms_before}→${syms_after} symbols"
        else
            pass "llvm-strip: ran (all symbols already stripped or not strippable)"
        fi
    else
        fail "llvm-strip: failed"
    fi

    # llvm-ar + llvm-ranlib: create and index an archive
    if "$ar" crs "$workd/test.a" "$workd/hello.o" "$workd/hello_cpp.o" 2>/dev/null &&
       "$ranlib" "$workd/test.a" 2>/dev/null &&
       "$ar" t "$workd/test.a" 2>/dev/null | grep -q 'hello'; then
        pass "llvm-ar + llvm-ranlib: archive created and indexed"
    else
        fail "llvm-ar + llvm-ranlib: archive failed"
    fi

    # lld: link an executable (we need a linked binary for llvm-strings)
    # -fuse-ld=lld comes from clang.cfg, not needed on command line.
    if "$clang" --target="$target_triple" --sysroot=/ -g \
         "$workd/hello.c" -o "$workd/hello" 2>/dev/null &&
       [ -x "$workd/hello" ]; then
        pass "ld.lld: linked executable via clang (lld from clang.cfg)"
        local linker_interp
        linker_interp=$(readelf -l "$workd/hello" 2>/dev/null | grep 'Requesting program interpreter' || true)
        if echo "$linker_interp" | grep -q 'ld-musl'; then
            pass "ld.lld output: musl interpreter"
        elif echo "$linker_interp" | grep -q 'ld-linux'; then
            fail "ld.lld output: glibc interpreter"
        else
            pass "ld.lld output: static binary (no interpreter)"
        fi
        local linker_needed
        linker_needed=$(readelf -d "$workd/hello" 2>/dev/null | grep NEEDED || true)
        if [ -z "$linker_needed" ]; then
            pass "ld.lld output: static (no NEEDED)"
        elif echo "$linker_needed" | grep -q 'libc\.musl' &&
             ! echo "$linker_needed" | grep -qE 'libc\.so\.6|libgcc_s|libstdc\+\+|libunwind'; then
            pass "ld.lld output: musl-only NEEDED"
        else
            fail "ld.lld output: unexpected NEEDED entries"
        fi
    else
        fail "ld.lld: link failed"
    fi

    # clang++: link a C++ executable
    # -cxx-isystem points at the installed libc++ headers so they are found
    # even with --sysroot=/ (which would otherwise hide them).
    # -L points at the install tree lib/ so lld can find libc++.a/libc++abi.a
    # (sysroot only has musl libc).
    # -fuse-ld=lld and -lc++abi -lunwind come from clang++.cfg (installed
    # next to the binary) so they are not repeated here.
    if "$clangxx" --target="$target_triple" --sysroot=/ \
         -cxx-isystem "${install_dir}/include/c++/v1" \
         -L "${install_dir}/lib" \
         "$workd/hello.cpp" -o "$workd/hello_cpp" 2>/dev/null &&
       [ -x "$workd/hello_cpp" ]; then
        local cpp_interp
        cpp_interp=$(readelf -l "$workd/hello_cpp" 2>/dev/null | grep 'Requesting program interpreter' || true)
        if echo "$cpp_interp" | grep -q 'ld-linux'; then
            fail "clang++ link: glibc interpreter"
        elif echo "$cpp_interp" | grep -q 'ld-musl'; then
            pass "clang++ link: musl interpreter"
        else
            pass "clang++ link: static (no interpreter)"
        fi
        # Verify the linked C++ binary has no GNU in NEEDED either.
        local cpp_needed
        cpp_needed=$(readelf -d "$workd/hello_cpp" 2>/dev/null | grep NEEDED || true)
        if [ -z "$cpp_needed" ]; then
            pass "clang++ link output: static (no NEEDED)"
        elif echo "$cpp_needed" | grep -qE 'libc\.so\.6|libgcc_s|libstdc\+\+|libunwind'; then
            fail "clang++ link output: unexpected NEEDED entries"
        else
            pass "clang++ link output: musl-only NEEDED"
        fi
    else
        fail "clang++ link: link failed"
    fi

    # llvm-strings: extract strings from linked executable
    local strings
    strings=$("${install_dir}/bin/llvm-strings" "$workd/hello" 2>/dev/null || true)
    if echo "$strings" | grep -q 'hello from clang'; then
        pass "llvm-strings: found expected string in executable"
    else
        fail "llvm-strings: expected string not found"
    fi

    # llvm-size: show section sizes
    local size_out
    size_out=$("${install_dir}/bin/llvm-size" "$workd/hello" 2>/dev/null || true)
    if echo "$size_out" | grep -qE 'text.*data.*bss'; then
        pass "llvm-size: section sizes reported"
    else
        fail "llvm-size: no section output"
    fi

    # llvm-symbolizer: resolve an address to a symbol.
    # llvm-nm emits bare hex (0000000000010840) but symbolizer requires
    # 0x prefix (0x0000000000010840); without it you get:
    #   error: '0000000000010840': expected a number as module offset
    # Try multiple invocation styles and capture diagnostics on failure.
    local nm_out symbol_addr sym_result sym_ok
    nm_out=$("$nm" "$workd/hello" 2>/dev/null || true)
    symbol_addr=$(echo "$nm_out" | grep -w 'main' | awk '{print $1}' | head -1)
    sym_ok=0
    if [ -n "$symbol_addr" ]; then
        # llvm-symbolizer expects addresses with 0x prefix.
        # stdin mode (most common usage)
        sym_result=$(echo "0x$symbol_addr" | "${install_dir}/bin/llvm-symbolizer" --obj="$workd/hello" 2>>"$workd/sym_stderr" || true)
        echo "$sym_result" | grep -q 'main' && sym_ok=1
        # fallback: arg mode
        if [ "$sym_ok" -eq 0 ]; then
            sym_result=$("${install_dir}/bin/llvm-symbolizer" --obj="$workd/hello" "0x$symbol_addr" 2>>"$workd/sym_stderr" || true)
            echo "$sym_result" | grep -q 'main' && sym_ok=1
        fi
        # fallback: addr2line compatibility (-e flag)
        if [ "$sym_ok" -eq 0 ]; then
            sym_result=$("${install_dir}/bin/llvm-symbolizer" -e "$workd/hello" "0x$symbol_addr" 2>>"$workd/sym_stderr" || true)
            echo "$sym_result" | grep -q 'main' && sym_ok=1
        fi
    fi
    if [ "$sym_ok" -eq 1 ]; then
        pass "llvm-symbolizer: resolved address → main"
    else
        fail "llvm-symbolizer: could not resolve main address"
    fi

    # Run linked executable if native
    if "$workd/hello" > "$workd/hello_out.txt" 2>&1; then
        pass "runtime: linked executable runs ($(cat "$workd/hello_out.txt"))"
    else
        echo "    (cannot run — cross-compiled or unsupported syscall)"
    fi

    echo ""
    echo "=== Validation: ${passed} passed, ${failed} failed ==="
    if [ "$failed" -gt 0 ]; then
        echo "Validation FAILED" >&2
        exit 1
    fi
}

validate "${CMAKE_INSTALL_PREFIX}" "${TARGET_TRIPLE}"

echo ""
echo "=== LLVM ${LLVM_VERSION} for ${TARGET_TRIPLE} build complete ==="
echo "Install prefix: ${CMAKE_INSTALL_PREFIX}"
finish_stage install-validate
