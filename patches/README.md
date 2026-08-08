# Local LLVM patches

This directory contains narrowly scoped patches carried by the prebuilt musl
toolchain. The patches are version-qualified because the LLVM 22 investigation
found two independent optimizer defects, while LLVM 23.1.0-rc2 already
contains the upstream fixes for those LLVM 22 defects.

The active release workflow builds LLVM `23.1.0-rc2`. It applies the LLVM 23
DSE patch below; the LLVM 22 backports remain here with their regression inputs
so the investigation is reproducible and the fixes can be compared against
the 22.1.8 baseline.

## Patch inventory

| Patch | LLVM version | Purpose | Upstream status |
| --- | --- | --- | --- |
| [`0001-llvm23-dse-use-iterative-dominance-walk.patch`](0001-llvm23-dse-use-iterative-dominance-walk.patch) | 23 | Replaces the recursive Dead Store Elimination dominator-tree walk with an explicit worklist. The recursive walk can exhaust the stack during Bun's ThinLTO link. | Local LLVM 23.1.0-rc2 workaround. |
| [`0002-llvm22-instcombine-recognize-non-negative-subtraction-patterns.patch`](0002-llvm22-instcombine-recognize-non-negative-subtraction-patterns.patch) | 22 | Teaches `computeKnownBitsAddSub` that `b - smin(b, a)` is non-negative, allowing InstCombine to preserve that fact through extensions. | Backport of [LLVM commit 6f68daa](https://github.com/llvm/llvm-project/commit/6f68daa42cab4884102a3688d4c13d732da6defd). |
| [`0003-llvm22-scev-limit-getrangeref-phi-recursion.patch`](0003-llvm22-scev-limit-getrangeref-phi-recursion.patch) | 22 | Limits recursive ScalarEvolution PHI range analysis in `getRangeRef`, preventing stack exhaustion through cyclic PHIs. | Port of [LLVM PR #152823](https://github.com/llvm/llvm-project/pull/152823), merged as [7bc3bb0](https://github.com/llvm/llvm-project/commit/7bc3bb0196d593d57ce5acbecd0b3c26e15b83a5). |

The two LLVM 22 fixes are separate. The `computeKnownBitsAddSub` issue is an
analysis gap; the reported ThinLTO SIGSEGV was the separate ScalarEvolution
recursion failure described in [LLVM issue #148253](https://github.com/llvm/llvm-project/issues/148253).
Neither fix is present in pristine upstream LLVM 22.1.8. LLVM 23.1.0-rc2
contains both upstream fixes, so the version-qualified LLVM 22 patches are not
applied to the current release build.

## Reproductions

The `computeKnownBitsAddSub` input is a one-function InstCombine regression:

```sh
opt -passes=instcombine -S \
  < repros/llvm22-compute-known-bits-addsub.ll \
  | FileCheck repros/llvm22-compute-known-bits-addsub.ll
```

The patched output contains `zext nneg`; an LLVM 22.1.8 build without patch
0002 leaves the signed extension unchanged.

The reduced ScalarEvolution control input is
[`repros/llvm22-scev-phi-range-recursion.ll`](../repros/llvm22-scev-phi-range-recursion.ll).
With an unpatched LLVM 22 `opt`, the reduced input reproduces the failure with
a deliberately small stack:

```sh
ulimit -s 250
opt -passes=loop-unroll -disable-output \
  repros/llvm22-scev-phi-range-recursion.ll
```

The unpatched tool exits with `SIGSEGV`; the patched tool exits successfully.
The original upstream reproducer from issue #148253 also crashes with a normal
host stack. The reduced input is kept as a compact control case, not as a
replacement for the upstream report.

## Applying patches

[`scripts/llvm-musl-stage-runner.sh`](../scripts/llvm-musl-stage-runner.sh)
selects patches by the `-llvm22-` or `-llvm23-` component in each filename. It
also fingerprints the selected patch files in the source-tree marker, so a
changed patch cannot be silently skipped by a stale build directory.

When adding or changing a patch:

1. Keep the filename version-qualified and describe the reason in this file.
2. Verify both forward and reverse `patch --dry-run` application against a
   pristine source tree.
3. Run the relevant reproduction or LLVM regression test.
4. Rebuild the prebuilt artifact and run the 81 install-validation checks.
5. For Bun integration, use the native amd64 target
   `make x86_84-static-musl-llvm23-local`; it performs the static ThinLTO link
   and runtime checks inside Alpine.

The completed LLVM 23 validation produced a static x86-64 Bun binary and
passed the full ThinLTO link without either LLVM 22 failure mode.
