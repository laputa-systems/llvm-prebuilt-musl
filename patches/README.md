# Local LLVM patches

This directory holds the patches applied to the pristine LLVM source tarball
pinned in [`llvm-source.env`](../llvm-source.env) (currently LLVM 23.1.2).
`scripts/apply-patches.sh` applies them.

## Patch inventory

| Patch | Purpose | Upstream status |
| --- | --- | --- |
| [`0001-llvm23-dse-use-iterative-dominance-walk.patch`](0001-llvm23-dse-use-iterative-dominance-walk.patch) | Replaces the recursive dominator-tree walk in `DSEState::eliminateRedundantStoresViaDominatingConditions()` with an explicit worklist, so deep dominator trees cannot exhaust the stack (for example on a small musl worker-thread stack during ThinLTO). | Local. Present unchanged in the tagged 23.1.2 sources: `VisitNode` is still a recursive lambda. The existing `MaxDepthRecursion` depth guard predates the patch and is preserved, not a fix for the stack use. |

### Fixes that are upstream in 23.1.2 (no longer patched)

Earlier builds of LLVM 22 carried two backports. Both are present in the
23.1.2 sources, verified against the pristine tarball, so the patches were
removed. Their reproducers are kept in [`../repros`](../repros) as regression
tests for the shipped `opt`.

| Behavior | Upstream change | Where in 23.1.2 | Reproducer |
| --- | --- | --- | --- |
| `b - smin(b, a)` is non-negative in `computeKnownBitsAddSub` | [6f68daa](https://github.com/llvm/llvm-project/commit/6f68daa42cab4884102a3688d4c13d732da6defd) | `computeKnownBitsAddSub()` in `ValueTracking.cpp` (`m_c_SMin`) | `repros/instcombine-nonneg-smin-sub.ll` |
| Bounded PHI range recursion in `ScalarEvolution::getRangeRef` (issue [#148253](https://github.com/llvm/llvm-project/issues/148253)) | [PR #152823](https://github.com/llvm/llvm-project/pull/152823), commit [7bc3bb0](https://github.com/llvm/llvm-project/commit/7bc3bb0196d593d57ce5acbecd0b3c26e15b83a5) | `RangeRefPHIAllowedOperands()` in `ScalarEvolution.cpp` | `repros/scev-phi-range-recursion.ll` |

## Applying patches

`scripts/apply-patches.sh <llvm-project-dir>` applies each patch forward with
zero fuzz. A patch whose reverse applies cleanly is treated as already applied;
anything else fails with instructions to restore a pristine tree. The stamp file
`.llvm-prebuilt-musl-patches` in the source tree records a hash of every patch,
so editing a patch invalidates it.

When adding or changing a patch, verify it against the pristine tarball for the
pinned release, add or extend a regression input under `repros/`, and describe
it in this file.
