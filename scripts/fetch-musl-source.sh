#!/usr/bin/env bash
# Download, verify, and extract the pinned musl source archive.
#
# Environment: MUSL_VERSION, MUSL_SOURCE_SHA256 (see musl-source.env),
#              MUSL_DIR (extraction target), MUSL_DOWNLOAD_DIR (archive cache).
#
# The archive is verified on every run, whether freshly downloaded or cached.
# Extraction happens in "$MUSL_DIR.partial" and is renamed into place only after
# it completes, so an interrupted run never leaves a directory that looks done.
# An existing MUSL_DIR is never modified or removed.
set -euo pipefail

: "${MUSL_VERSION:?}" "${MUSL_SOURCE_SHA256:?}" "${MUSL_DIR:?}" "${MUSL_DOWNLOAD_DIR:?}"

archive_name="musl-${MUSL_VERSION}.tar.gz"
archive="${MUSL_DOWNLOAD_DIR}/${archive_name}"
url="https://musl.libc.org/releases/${archive_name}"

sha256_of() {
    if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

archive_ok() {
    [ -f "$archive" ] && [ "$(sha256_of "$archive")" = "$MUSL_SOURCE_SHA256" ]
}

if [ -e "$MUSL_DIR" ]; then
    echo "musl source already present: ${MUSL_DIR}"
    exit 0
fi

mkdir -p "$MUSL_DOWNLOAD_DIR"
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
        echo "ERROR: ${archive_name} sha256 ${actual} does not match pinned ${MUSL_SOURCE_SHA256}" >&2
        exit 1
    fi
fi

rm -rf "${MUSL_DIR}.partial"
mkdir -p "${MUSL_DIR}.partial"
tar -xf "$archive" -C "${MUSL_DIR}.partial" --strip-components=1
mv "${MUSL_DIR}.partial" "$MUSL_DIR"
echo "Extracted musl ${MUSL_VERSION} to ${MUSL_DIR}"
