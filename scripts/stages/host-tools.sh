#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LLVM_BUILD_STAGE=host-tools exec "${SCRIPT_DIR}/llvm-musl-stage-runner.sh"
