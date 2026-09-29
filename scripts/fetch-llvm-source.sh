#!/usr/bin/env bash
# Download, verify, and extract the pinned LLVM source archive.
#
# Environment: LLVM_VERSION, LLVM_SOURCE_SHA256 (see llvm-source.env),
#              LLVM_DIR (extraction target), LLVM_DOWNLOAD_DIR (archive cache).
#
# The archive is verified on every run, whether freshly downloaded or cached.
# Extraction happens in "$LLVM_DIR.partial" and is renamed into place only after
# it completes, so an interrupted run never leaves a directory that looks done.
# An existing LLVM_DIR is never modified or removed.
set -euo pipefail

: "${LLVM_VERSION:?}" "${LLVM_SOURCE_SHA256:?}" "${LLVM_DIR:?}" "${LLVM_DOWNLOAD_DIR:?}"

archive_name="llvm-project-${LLVM_VERSION}.src.tar.xz"
archive="${LLVM_DOWNLOAD_DIR}/${archive_name}"
url="https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/${archive_name}"

sha256_of() {
    if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

archive_ok() {
    [ -f "$archive" ] && [ "$(sha256_of "$archive")" = "$LLVM_SOURCE_SHA256" ]
}

if [ -e "$LLVM_DIR" ]; then
    echo "LLVM source already present: ${LLVM_DIR}"
    exit 0
fi

mkdir -p "$LLVM_DOWNLOAD_DIR"
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
        echo "ERROR: ${archive_name} sha256 ${actual} does not match pinned ${LLVM_SOURCE_SHA256}" >&2
        exit 1
    fi
fi

rm -rf "${LLVM_DIR}.partial"
mkdir -p "${LLVM_DIR}.partial"
tar -xf "$archive" -C "${LLVM_DIR}.partial" --strip-components=1
mv "${LLVM_DIR}.partial" "$LLVM_DIR"
echo "Extracted LLVM ${LLVM_VERSION} to ${LLVM_DIR}"
