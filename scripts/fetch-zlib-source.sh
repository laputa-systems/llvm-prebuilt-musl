#!/usr/bin/env bash
# Download, verify, and extract the pinned zlib source archive.
#
# Environment: ZLIB_VERSION, ZLIB_SOURCE_SHA256 (see zlib-source.env),
#              ZLIB_DIR (extraction target), ZLIB_DOWNLOAD_DIR (archive cache).
#
# The archive is verified on every run, whether freshly downloaded or cached.
# Extraction happens in "$ZLIB_DIR.partial" and is renamed into place only after
# it completes, so an interrupted run never leaves a directory that looks done.
# An existing ZLIB_DIR is never modified or removed.
set -euo pipefail

: "${ZLIB_VERSION:?}" "${ZLIB_SOURCE_SHA256:?}" "${ZLIB_DIR:?}" "${ZLIB_DOWNLOAD_DIR:?}"

archive_name="zlib-${ZLIB_VERSION}.tar.gz"
archive="${ZLIB_DOWNLOAD_DIR}/${archive_name}"
url="https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/${archive_name}"

sha256_of() {
    if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

archive_ok() {
    [ -f "$archive" ] && [ "$(sha256_of "$archive")" = "$ZLIB_SOURCE_SHA256" ]
}

if [ -e "$ZLIB_DIR" ]; then
    echo "zlib source already present: ${ZLIB_DIR}"
    exit 0
fi

mkdir -p "$ZLIB_DOWNLOAD_DIR"
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
        echo "ERROR: ${archive_name} sha256 ${actual} does not match pinned ${ZLIB_SOURCE_SHA256}" >&2
        exit 1
    fi
fi

rm -rf "${ZLIB_DIR}.partial"
mkdir -p "${ZLIB_DIR}.partial"
tar -xf "$archive" -C "${ZLIB_DIR}.partial" --strip-components=1
mv "${ZLIB_DIR}.partial" "$ZLIB_DIR"
echo "Extracted zlib ${ZLIB_VERSION} to ${ZLIB_DIR}"
