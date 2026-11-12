#!/bin/sh
# Check one target's release assets in <out_dir> against the validated packages.
# Usage: TARGET=<triple> sh scripts/verify-release.sh [out_dir]      (default: dist/release)
# Every asset must exist, the standard and legacy names must carry the bytes scripts/validate.sh
# just tested, and each manifest must describe this target, version, and sources.lock.json.
set -eu
unset CDPATH

script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
. "$script_dir/sha256.sh"
. "$script_dir/lock.sh"
repo_root=$(cd -- "$script_dir/.." && pwd -P)
out_dir=${1:-$repo_root/dist/release}
triple=${TARGET:?verify-release: set TARGET to a Rust target triple}

fail() { echo "verify-release: $*" >&2; exit 1; }

command -v jaq >/dev/null || fail "jaq is required"

case $triple in
    x86_64-unknown-linux-musl) arch=x86_64 ;;
    aarch64-unknown-linux-musl) arch=aarch64 ;;
    *) fail "unsupported target $triple" ;;
esac

version=$(lock_field llvm-project version)
state_dir=${STATE_DIR:-$repo_root/.work/$arch}
legacy=clang+llvm-$version-$arch-linux-musl
lock_sha256=$(sha256 "$repo_root/sources.lock.json" | awk '{ print $1 }')

for pair in "llvm:" "llvm-dev:-dev"; do
    product=${pair%%:*}
    suffix=${pair#*:}
    name=$product-$version-$triple
    tested=$state_dir/dist/$legacy$suffix.tar.xz
    for asset in "$name.tar.xz" "$legacy$suffix.tar.xz"; do
        [ -f "$out_dir/$asset" ] || fail "$out_dir/$asset missing; run 'make build TARGET=$triple'"
        cmp -s "$tested" "$out_dir/$asset" || fail "$asset differs from the validated $tested"
    done
    [ -f "$out_dir/$name.manifest.json" ] || fail "$out_dir/$name.manifest.json missing"
    jaq -e --arg product "$product" --arg version "$version" --arg target "$triple" --arg lock_sha256 "$lock_sha256" \
        '.schema_version == 1 and .product == $product and .version == $version and .target == $target
         and (.source_revision | test("^[0-9a-f]{40}$")) and .sources_lock_sha256 == $lock_sha256' \
        "$out_dir/$name.manifest.json" >/dev/null || fail "$name.manifest.json does not describe $name"
done

echo "Release assets for $triple match the validated packages"
