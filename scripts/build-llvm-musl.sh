#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

STAGES=(
    host-tools
    configure
    stage1-lld
    stage2
    install-validate
)

echo "=== Running full LLVM musl build ==="
for stage in "${STAGES[@]}"; do
    "${SCRIPT_DIR}/stages/${stage}.sh"
done
