#!/bin/sh
# Name one target's finished packages as release assets.
# Usage: TARGET=<triple> sh scripts/package.sh [out_dir]      (default: dist/release)
# Input: <state_dir>/dist/clang+llvm-<version>-<arch>-linux-musl{,-dev}.tar.xz, written by
# scripts/build.sh (state_dir defaults to .work/<arch>).
#
# Each package is published twice with identical bytes: as llvm[-dev]-<version>-<triple>.tar.xz
# with a .manifest.json (the fleet's build-repository layout), and under its original
# clang+llvm-<version>-<arch>-linux-musl[-dev].tar.xz name, which existing consumers pin.
set -eu
unset CDPATH

script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
. "$script_dir/sha256.sh"
. "$script_dir/lock.sh"
repo_root=$(cd -- "$script_dir/.." && pwd -P)
out_dir=${1:-$repo_root/dist/release}
triple=${TARGET:?package: set TARGET to a Rust target triple}

fail() { echo "package: $*" >&2; exit 1; }

for tool in jaq git; do
    command -v "$tool" >/dev/null || fail "$tool is required"
done

case $triple in
    x86_64-unknown-linux-musl) arch=x86_64 ;;
    aarch64-unknown-linux-musl) arch=aarch64 ;;
    *) fail "unsupported target $triple" ;;
esac

version=$(lock_field llvm-project version)
musl_version=$(lock_field musl version)
[ -n "$version" ] || fail "cannot read the llvm-project version from sources.lock.json"
state_dir=${STATE_DIR:-$repo_root/.work/$arch}
legacy=clang+llvm-$version-$arch-linux-musl

for suffix in "" -dev; do
    [ -f "$state_dir/dist/$legacy$suffix.tar.xz" ] || fail "$state_dir/dist/$legacy$suffix.tar.xz missing; run 'make build TARGET=$triple' first"
done

commit=$(git -C "$repo_root" rev-parse HEAD)
if [ -n "$(git -C "$repo_root" status --porcelain)" ]; then dirty=true; else dirty=false; fi
lock_sha256=$(sha256 "$repo_root/sources.lock.json" | awk '{ print $1 }')

mkdir -p "$out_dir"
out_dir=$(cd -- "$out_dir" && pwd -P)
stage=$(mktemp -d "$out_dir/.stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT

for pair in "llvm:" "llvm-dev:-dev"; do
    product=${pair%%:*}
    suffix=${pair#*:}
    name=$product-$version-$triple
    cp "$state_dir/dist/$legacy$suffix.tar.xz" "$stage/$name.tar.xz"
    cp "$state_dir/dist/$legacy$suffix.tar.xz" "$stage/$legacy$suffix.tar.xz"
    jaq -n \
        --arg product "$product" --arg version "$version" --arg target "$triple" \
        --arg commit "$commit" --arg lock_sha256 "$lock_sha256" --argjson dirty "$dirty" \
        --arg musl_version "$musl_version" --arg legacy "$legacy$suffix.tar.xz" \
        '{schema_version: 1, product: $product, version: $version, target: $target,
          source_revision: $commit, sources_lock_sha256: $lock_sha256, build_dirty: $dirty,
          musl_version: $musl_version, legacy_asset: $legacy}' > "$stage/$name.manifest.json"
done

rm -f "$out_dir"/llvm-*-"$triple".tar.xz "$out_dir"/llvm-*-"$triple".manifest.json \
    "$out_dir/$legacy.tar.xz" "$out_dir/$legacy-dev.tar.xz"
mv "$stage"/*.tar.xz "$stage"/*.manifest.json "$out_dir"/

echo "Packaged $triple in $out_dir"
