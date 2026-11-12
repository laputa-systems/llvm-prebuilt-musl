#!/bin/sh
# Download, verify, and extract every input in sources.lock.json.
#
# For each input, <ENV>_DIR is the extraction target (default: $WORK_DIR/<dir>) and
# <ENV>_DOWNLOAD_DIR the archive cache (default: $DOWNLOAD_DIR). <ENV> is the input's `env` field
# (LLVM, MUSL, ZLIB, MIMALLOC). WORK_DIR defaults to ./.work and DOWNLOAD_DIR to $WORK_DIR/download.
#
# The archive is verified on every run, whether freshly downloaded or cached. Extraction happens in
# "<dir>.partial" and is renamed into place only after it completes, so an interrupted run never
# leaves a directory that looks done. An existing extraction target is never modified or removed.
# shellcheck disable=SC2154
set -eu
unset CDPATH

script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
. "$script_dir/sha256.sh"
. "$script_dir/lock.sh"

fail() { echo "fetch-sources: $*" >&2; exit 1; }

command -v jaq >/dev/null 2>&1 || fail "jaq not found"
command -v curl >/dev/null 2>&1 || fail "curl not found"

root_dir=$(cd -- "$script_dir/.." && pwd -P)
work_dir=${WORK_DIR:-$root_dir/.work}
download_dir=${DOWNLOAD_DIR:-$work_dir/download}

archive_ok() {
    [ -f "$1" ] && [ "$(sha256 "$1" | awk '{ print $1 }')" = "$2" ]
}

for name in $(lock_names); do
    version=$(lock_field "$name" version)
    url=$(lock_field "$name" url)
    want=$(lock_field "$name" sha256)
    archive_name=$(lock_field "$name" archive)
    dir_name=$(lock_field "$name" dir)
    prefix=$(lock_field "$name" env)
    [ -n "$version" ] && [ -n "$url" ] && [ -n "$want" ] && [ -n "$archive_name" ] && [ -n "$dir_name" ] && [ -n "$prefix" ] ||
        fail "sources.lock.json input $name needs version, url, sha256, archive, dir, and env"

    eval "dir=\${${prefix}_DIR:-$work_dir/$dir_name}"
    eval "cache=\${${prefix}_DOWNLOAD_DIR:-$download_dir}"
    archive=$cache/$archive_name

    if [ -e "$dir" ]; then
        echo "$name source already present: $dir"
        continue
    fi

    mkdir -p "$cache"
    if archive_ok "$archive" "$want"; then
        echo "Using verified cached archive: $archive"
    else
        rm -f "$archive" "$archive.part"
        echo "Downloading $url"
        curl -fsSL --retry 3 -o "$archive.part" "$url"
        mv "$archive.part" "$archive"
        if ! archive_ok "$archive" "$want"; then
            actual=$(sha256 "$archive" | awk '{ print $1 }')
            rm -f "$archive"
            fail "$archive_name sha256 $actual does not match pinned $want"
        fi
    fi

    rm -rf "$dir.partial"
    mkdir -p "$dir.partial"
    tar -xf "$archive" -C "$dir.partial" --strip-components=1
    mv "$dir.partial" "$dir"
    echo "Extracted $name $version to $dir"
done
