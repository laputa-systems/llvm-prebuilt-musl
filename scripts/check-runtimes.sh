#!/bin/sh
# Fail if a runtime that consumers link into their programs carries a build path
# or references GCC's frame registration.
#
#   check-runtimes.sh <package-dir> [build-root]
#
# The runtimes are libc++, libc++abi, libc++experimental, libunwind, everything in
# lib/musl/, and compiler-rt's builtins and crt objects. None may contain a path
# under build-root (default /work, the build container's root for the sources and
# build trees), because it would reach every program linked with them. compiler-rt's
# crtbegin objects must not reference __register_frame_info or
# __deregister_frame_info: even a weak reference becomes a dynamic import of every
# dynamically linked program. The package's own llvm-strings and llvm-nm are used.
#
# Exit status: 0 clean, 1 a runtime fails a check, 2 the package cannot be checked.
set -eu

pkg=${1:?package directory}
root=${2:-/work}
strings="${pkg}/bin/llvm-strings"
nm="${pkg}/bin/llvm-nm"
if [ ! -x "$strings" ] || [ ! -x "$nm" ]; then
    printf 'check-runtimes: no llvm-strings/llvm-nm in %s/bin\n' "$pkg" >&2
    exit 2
fi

for archive in libc++.a libc++abi.a libc++experimental.a libunwind.a; do
    if [ ! -f "${pkg}/lib/${archive}" ]; then
        printf 'check-runtimes: %s/lib/%s is missing\n' "$pkg" "$archive" >&2
        exit 2
    fi
done
found=$(cd "$pkg" && find lib/musl lib/clang/*/lib/linux -type f \( -name '*.a' -o -name '*.o' \))
runtimes=$(LC_ALL=C sort <<EOF
lib/libc++.a
lib/libc++abi.a
lib/libc++experimental.a
lib/libunwind.a
${found}
EOF
)

failures=0
checked=0
while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    checked=$((checked + 1))
    text=$("$strings" "${pkg}/${rel}" </dev/null) || { printf 'check-runtimes: llvm-strings failed on %s\n' "$rel" >&2; exit 2; }
    paths=$(awk -v prefix="${root}/" 'index($0, prefix) && !seen[$0]++ { print "    " $0; if (++n == 3) exit }' <<EOF
${text}
EOF
)
    if [ -n "$paths" ]; then
        printf 'RUNTIME: %s: build paths under %s/:\n%s\n' "$rel" "$root" "$paths"
        failures=$((failures + 1))
    fi
    case "$rel" in
        */clang_rt.crtbegin*.o)
            symbols=$("$nm" "${pkg}/${rel}" </dev/null) || { printf 'check-runtimes: llvm-nm failed on %s\n' "$rel" >&2; exit 2; }
            refs=$(awk '($NF == "__register_frame_info" || $NF == "__deregister_frame_info") && !seen[$NF]++ { printf " %s", $NF }' <<EOF
${symbols}
EOF
)
            if [ -n "$refs" ]; then
                printf 'RUNTIME: %s: references frame registration:%s\n' "$rel" "$refs"
                failures=$((failures + 1))
            fi
            ;;
    esac
done <<EOF
${runtimes}
EOF

printf 'check-runtimes: %d runtime archives and objects checked in %s, %d failing\n' "$checked" "$pkg" "$failures"
[ "$failures" -eq 0 ]
