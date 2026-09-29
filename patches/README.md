# Local LLVM patches

This directory holds the patches applied to the pristine LLVM source tarball
pinned in [`llvm-source.env`](../llvm-source.env) (LLVM 23.1.2).
`scripts/apply-patches.sh` applies them before the build is configured.

## Patch inventory

| Patch | Purpose | Upstream status |
| --- | --- | --- |
| [`0001-llvm23-dse-use-iterative-dominance-walk.patch`](0001-llvm23-dse-use-iterative-dominance-walk.patch) | Replaces the recursive dominator-tree walk in `DSEState::eliminateRedundantStoresViaDominatingConditions()` with an explicit worklist, so a deep dominator tree cannot exhaust the stack (for example on a musl worker thread, whose default stack is 128 KiB, during a ThinLTO link). Traversal order, the lifetime of each condition scope, and the `dse-max-dom-cond-depth` limit are unchanged. | Local. The tagged 23.1.2 sources still use the recursive `VisitNode` lambda. Its depth guard predates the patch; it bounds the recursion at 1024 levels but does not remove the stack use. |

### Fixes that are upstream in 23.1.2 (no longer patched)

LLVM 22 builds of this package carried two backports. Both are present in the
pristine 23.1.2 sources, so the patches are gone; their reproducers remain in
[`../repros`](../repros) as regression tests for the `opt` built from the
pinned sources.

| Behavior | Upstream change | Where in 23.1.2 | Reproducer |
| --- | --- | --- | --- |
| `b - smin(b, a)` is non-negative in `computeKnownBitsAddSub` | [6f68daa](https://github.com/llvm/llvm-project/commit/6f68daa42cab4884102a3688d4c13d732da6defd) | `computeKnownBitsAddSub()` in `ValueTracking.cpp` (`m_c_SMin`) | `instcombine-nonneg-smin-sub.ll` |
| Bounded PHI range recursion in `ScalarEvolution::getRangeRef` (issue [#148253](https://github.com/llvm/llvm-project/issues/148253)) | [PR #152823](https://github.com/llvm/llvm-project/pull/152823), commit [7bc3bb0](https://github.com/llvm/llvm-project/commit/7bc3bb0196d593d57ce5acbecd0b3c26e15b83a5) | `RangeRefPHIAllowedOperands()` in `ScalarEvolution.cpp` | `scev-phi-range-recursion.ll` |

## Regression tests

`scripts/run-optimizer-regressions.sh` runs every `; RUN:` line in
`repros/*.ll` with the `opt` and `FileCheck` built in the build tree, as part of
`make build`. Neither tool is installed in the package.

| Input | Checks |
| --- | --- |
| `dse-dominating-conditions.ll` + `gen-dse-domtree.sh` | A generated function with a chain of N single-successor blocks under the edge `load %x == 0`, ending in a diamond on `load %y == 7`. Stores implied by a dominating condition are removed, including the outer condition N levels down and the nested one in `arm1`; the store in sibling `arm2` and the store in the other arm of the outer branch stay (no condition leaks between scopes). One run uses N = 900 with a 128 KiB stack limit; another lowers `dse-max-dom-cond-depth` to check the limit still stops the walk. |
| `instcombine-nonneg-smin-sub.ll` | `b - smin(b, a)` is proved non-negative (`zext nneg`). |
| `scev-phi-range-recursion.ll` | Loop unrolling of the reduced #148253 input completes with a 250 KiB stack limit. |

Stack limits are applied with `ulimit -s` inside the `bash -c` that runs one
RUN line, so they affect only that test.

### The old DSE failure, measured

Building a second `opt` whose `DeadStoreElimination.cpp` is the pristine 23.1.2
file (the rest of the tree unchanged) and running the depth-900 input from
`gen-dse-domtree.sh` on x86_64:

| Main-thread stack limit | patched walk | pristine recursive walk |
| --- | --- | --- |
| 8 MiB down to 256 KiB | passes | passes |
| 192 KiB, 128 KiB, 96 KiB, 64 KiB | passes | SIGSEGV |

The regression uses 128 KiB, musl's default thread stack size. This is a
reproduction of the stack use on the main thread of `opt`, not of a ThinLTO
worker thread; the frame sizes measured here are for the x86_64 build and are
not an aarch64 measurement.

## Applying patches

`scripts/apply-patches.sh <llvm-project-dir>` applies each patch forward with
zero fuzz. A patch whose reverse applies cleanly is treated as already applied;
anything else fails with instructions to restore a pristine tree. The stamp file
`.llvm-prebuilt-musl-patches` in the source tree records a hash of every patch,
so a changed patch is never skipped because of a stale stamp.

When adding or changing a patch, verify it against the pristine tarball for the
pinned release, add or extend a regression under `repros/`, and describe it in
this file.
