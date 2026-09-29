#!/usr/bin/env bash
# Apply patches/*.patch to an LLVM source tree, strictly and repeatably.
#
#   usage: apply-patches.sh <llvm-project-dir>
#
# Each patch must apply forward with zero fuzz to pristine source, or already be
# applied (its reverse applies cleanly). Anything else is an error: the tree was
# edited by hand, the patch was changed after being applied, or the patch does
# not fit this LLVM release. The stamp records the content hash of every patch,
# so a stale stamp cannot hide a changed patch.
set -euo pipefail

src="${1:?usage: apply-patches.sh <llvm-project-dir>}"
patch_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../patches" && pwd)"
stamp="${src}/.llvm-prebuilt-musl-patches"

sha256_of() {
    if command -v sha256sum >/dev/null; then sha256sum <"$1" | cut -d' ' -f1
    else shasum -a 256 <"$1" | cut -d' ' -f1
    fi
}

shopt -s nullglob
patches=("${patch_dir}"/*.patch)

expected=""
for p in "${patches[@]}"; do
    expected+="$(sha256_of "$p")  ${p##*/}"$'\n'
done

if [ -f "$stamp" ] && [ "$(cat "$stamp")"$'\n' = "$expected" ]; then
    exit 0
fi

try_patch() { patch -d "$src" -p1 -F0 --batch --dry-run "${@:2}" <"$1" >/dev/null 2>&1; }

for p in "${patches[@]}"; do
    name="${p##*/}"
    if try_patch "$p" --forward; then
        patch -d "$src" -p1 -F0 --batch --forward <"$p"
    elif try_patch "$p" --reverse; then
        echo "Patch already applied: ${name}"
    else
        echo "ERROR: ${name} neither applies to nor is already present in ${src}." >&2
        echo "       Restore a pristine source tree (remove it and rerun 'make source')" >&2
        echo "       or rebase the patch onto this LLVM release." >&2
        exit 1
    fi
done

printf '%s' "$expected" >"$stamp"
