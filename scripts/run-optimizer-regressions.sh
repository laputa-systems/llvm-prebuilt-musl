#!/usr/bin/env bash
# Run the optimizer regressions in repros/ against the opt built in an LLVM
# build tree, so they exercise the shipped LLVM version plus our patches.
#
#   usage: run-optimizer-regressions.sh <llvm-build-dir>
#
# Each repros/*.ll carries "; RUN:" lines, executed here in bash with pipefail
# instead of lit, so no test-suite infrastructure is needed. In a RUN line, %s
# is the file and %S its directory. opt and FileCheck are built on demand and
# stay in the build tree; they are not distribution components.
set -euo pipefail

build="${1:?usage: run-optimizer-regressions.sh <llvm-build-dir>}"
repros="$(cd "$(dirname "${BASH_SOURCE[0]}")/../repros" && pwd)"

cmake --build "$build" --target opt FileCheck
export PATH="${build}/bin:${PATH}"

ran=0 failed=0
for file in "$repros"/*.ll; do
    while IFS= read -r line; do
        cmd="${line#'; RUN: '}"
        cmd="${cmd//%s/$file}"
        cmd="${cmd//%S/$repros}"
        echo "--- ${file##*/}: ${cmd}"
        ran=$((ran + 1))
        bash -o pipefail -c "$cmd" || { echo "FAILED: ${file##*/}" >&2; failed=$((failed + 1)); }
    done < <(grep '^; RUN: ' "$file")
done

echo "optimizer regressions: ${ran} run, ${failed} failed"
[ "$ran" -gt 0 ] || { echo "ERROR: no RUN lines found in ${repros}" >&2; exit 1; }
[ "$failed" -eq 0 ]
