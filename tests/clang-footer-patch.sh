#!/usr/bin/env bash
set -euo pipefail

pristine="${1:?usage: clang-footer-patch.sh <pristine Driver.cpp>}"
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:?set TMPDIR to scratch}/clang-footer-patch.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/clang/lib/Driver"
cp "$pristine" "$work/clang/lib/Driver/Driver.cpp"
footer_patch="$repo/patches/0002-clang-primary-help-footer.patch"

patch -d "$work" -p1 -F0 --batch --forward <"$footer_patch"
test "$(awk '/Maintained by Joshua Li:/ { n++ } END { print n+0 }' "$work/clang/lib/Driver/Driver.cpp")" -eq 1
if patch -d "$work" -p1 -F0 --batch --dry-run --forward <"$footer_patch"; then
    echo 'applied footer unexpectedly accepts a second forward patch' >&2
    exit 1
fi
patch -d "$work" -p1 -F0 --batch --reverse <"$footer_patch"
cmp "$pristine" "$work/clang/lib/Driver/Driver.cpp"
