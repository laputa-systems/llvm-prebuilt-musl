#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LLVM_BUILD_STAGE=stage2 exec "${SCRIPT_DIR}/llvm-musl-stage-runner.sh"
