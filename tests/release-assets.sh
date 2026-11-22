#!/bin/sh
set -eu
unset CDPATH

repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$repo"
script_dir=$repo/scripts
. ./scripts/lock.sh
version=$(lock_field llvm-project version)
mkdir -p .work/tmp
scratch=$(mktemp -d "$repo/.work/tmp/release-assets.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

expect_rejection() {
    if message=$(TARGET=$target STATE_DIR=$state sh scripts/verify-release.sh "$out" 2>&1); then
        printf '%s\n' "$target unexpectedly accepted invalid release assets" >&2
        exit 1
    fi
    case "$message" in
        *"$1"*) ;;
        *) printf '%s\n' "$message" >&2; exit 1 ;;
    esac
}

for arch in x86_64 aarch64; do
    target=$arch-unknown-linux-musl
    state=$scratch/$arch
    out=$state/release
    legacy=clang+llvm-$version-$arch-linux-musl
    standard=llvm-$version-$target
    manifest=$out/$standard.manifest.json
    mkdir -p "$state/dist"
    printf '%s\n' 'runtime toolchain fixture' > "$state/dist/$legacy.tar.xz"
    printf '%s\n' 'development toolchain fixture' > "$state/dist/$legacy-dev.tar.xz"
    TARGET=$target STATE_DIR=$state sh scripts/package.sh "$out"
    TARGET=$target STATE_DIR=$state sh scripts/verify-release.sh "$out"

    printf '%s\n' 'different package contents' > "$out/$legacy.tar.xz"
    expect_rejection "$legacy.tar.xz differs from the validated"
    cp "$state/dist/$legacy.tar.xz" "$out/$legacy.tar.xz"

    jaq '.sources_lock_sha256 = "stale"' "$manifest" > "$state/stale.json"
    mv "$state/stale.json" "$manifest"
    expect_rejection "$standard.manifest.json does not describe $standard"
done
