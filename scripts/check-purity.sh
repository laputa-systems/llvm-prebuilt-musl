#!/usr/bin/env bash
# Fail if anything under a package directory carries glibc or GNU runtime code.
#
#   check-purity.sh <package-dir> <x86_64|aarch64> [tools-dir]
#
# Checks every ELF file and static archive: DT_NEEDED only names musl's libc or a
# library the package ships; the only program interpreter is musl's; no .comment
# section says it came from GCC; and no object defines or references libgcc or
# libstdc++ symbols (std::__cxx11 names, glibc and GCC symbol
# versions). tools-dir supplies llvm-readelf and llvm-nm (default: the package's
# own bin/), so the gate also runs on a dev package that ships neither.
set -euo pipefail

pkg=${1:?package directory}
arch=${2:?architecture}
tools=${3:-${pkg}/bin}
readelf="${tools}/llvm-readelf"
nm="${tools}/llvm-nm"
[ -x "$readelf" ] && [ -x "$nm" ] || { echo "check-purity: no llvm-readelf/llvm-nm in ${tools}" >&2; exit 2; }

loader="/lib/ld-musl-${arch}.so.1"
musl_libc="libc.musl-${arch}.so.1"
shipped_libs=$(cd "$pkg" && find . -name '*.so*' -type f -o -name '*.so*' -type l | sed 's|.*/||' | sort -u)
failures=0
checked=0

fail() {
    echo "IMPURE: $1: $2"
    failures=$((failures + 1))
}

is_elf_or_archive() {
    local magic
    magic=$(head -c 8 "$1" 2>/dev/null | od -An -c | tr -d ' \n')
    case "$magic" in
        177ELF*|'!<arch>'*) return 0 ;;
    esac
    return 1
}

while IFS= read -r -d '' file; do
    is_elf_or_archive "$file" || continue
    checked=$((checked + 1))
    rel=${file#"$pkg"/}

    if [ "$(head -c 4 "$file" | od -An -c | tr -d ' \n')" = '177ELF' ]; then
        while IFS= read -r needed; do
            [ -n "$needed" ] || continue
            if [ "$needed" != "$musl_libc" ] && ! grep -qxF "$needed" <<<"$shipped_libs"; then
                fail "$rel" "DT_NEEDED ${needed}"
            fi
        done < <("$readelf" -d "$file" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
        interp=$("$readelf" -l "$file" 2>/dev/null | sed -n 's/.*\[Requesting program interpreter: \(.*\)\]/\1/p')
        if [ -n "$interp" ] && [ "$interp" != "$loader" ]; then
            fail "$rel" "interpreter ${interp}"
        fi
    fi

    if "$readelf" -p .comment "$file" 2>/dev/null | grep -q 'GCC:'; then
        fail "$rel" ".comment names GCC: $("$readelf" -p .comment "$file" 2>/dev/null | grep -m1 'GCC:' | sed 's/^ *\[ *[0-9a-f]*\] *//')"
    fi

    gnu_symbols=$("$nm" -A "$file" 2>/dev/null |
        grep -E ' (_ZNSt7__cxx11|_ZNKSt7__cxx11)|@GLIBC_|@GLIBCXX_|@GCC_' |
        head -3 || true)
    if [ -n "$gnu_symbols" ]; then
        fail "$rel" "GNU runtime symbols: $(echo "$gnu_symbols" | sed 's/^.*: //' | tr '\n' ' ')"
    fi
done < <(find "$pkg" -type f -print0)

echo "check-purity: ${checked} ELF files and archives checked in ${pkg}, ${failures} impure"
[ "$failures" -eq 0 ]
