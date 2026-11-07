#!/usr/bin/env bash
# Create musl's empty stub archives (EMPTY_LIB_NAMES in musl's Makefile) with
# the package's llvm-ar: everything lives in libc.a, but objects such as
# libunwind's carry dependent-library entries for dl and pthread that lld
# resolves by searching for these files.
#
#   usage: install-musl-stubs.sh <llvm-ar> <musl-lib-dir>
set -euo pipefail

AR="${1:?usage: install-musl-stubs.sh <llvm-ar> <musl-lib-dir>}"
DIR="${2:?usage: install-musl-stubs.sh <llvm-ar> <musl-lib-dir>}"

for name in m rt pthread crypt util xnet resolv dl; do
    rm -f "${DIR}/lib${name}.a"
    "$AR" rc "${DIR}/lib${name}.a"
    chmod 644 "${DIR}/lib${name}.a"
done
