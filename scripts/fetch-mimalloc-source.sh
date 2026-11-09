#!/usr/bin/env bash
# Download, verify, and extract the pinned mimalloc source archive.
#
# Environment: MIMALLOC_VERSION, MIMALLOC_SOURCE_SHA256 (see mimalloc-source.env),
#              MIMALLOC_DIR (extraction target), MIMALLOC_DOWNLOAD_DIR (archive cache).
#
# The archive is verified on every run, whether freshly downloaded or cached.
# Extraction happens in "$MIMALLOC_DIR.partial" and is renamed into place only after
# it completes, so an interrupted run never leaves a directory that looks done.
# An existing MIMALLOC_DIR is never modified or removed.
set -euo pipefail

: "${MIMALLOC_VERSION:?}" "${MIMALLOC_SOURCE_SHA256:?}" "${MIMALLOC_DIR:?}" "${MIMALLOC_DOWNLOAD_DIR:?}"

archive_name="mimalloc-${MIMALLOC_VERSION}.tar.gz"
archive="${MIMALLOC_DOWNLOAD_DIR}/${archive_name}"
url="https://github.com/microsoft/mimalloc/archive/refs/tags/v${MIMALLOC_VERSION}.tar.gz"

sha256_of() {
    if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

archive_ok() {
    [ -f "$archive" ] && [ "$(sha256_of "$archive")" = "$MIMALLOC_SOURCE_SHA256" ]
}

if [ -e "$MIMALLOC_DIR" ]; then
    echo "mimalloc source already present: ${MIMALLOC_DIR}"
    exit 0
fi

mkdir -p "$MIMALLOC_DOWNLOAD_DIR"
if archive_ok; then
    echo "Using verified cached archive: ${archive}"
else
    rm -f "$archive" "${archive}.part"
    echo "Downloading ${url}"
    curl -fsSL --retry 3 -o "${archive}.part" "$url"
    mv "${archive}.part" "$archive"
    if ! archive_ok; then
        actual=$(sha256_of "$archive")
        rm -f "$archive"
        echo "ERROR: ${archive_name} sha256 ${actual} does not match pinned ${MIMALLOC_SOURCE_SHA256}" >&2
        exit 1
    fi
fi

rm -rf "${MIMALLOC_DIR}.partial"
mkdir -p "${MIMALLOC_DIR}.partial"
tar -xf "$archive" -C "${MIMALLOC_DIR}.partial" --strip-components=1
mv "${MIMALLOC_DIR}.partial" "$MIMALLOC_DIR"
echo "Extracted mimalloc ${MIMALLOC_VERSION} to ${MIMALLOC_DIR}"
