; Store elimination through dominating conditions (DSE) over a deep dominator
; tree. The IR comes from gen-dse-domtree.sh: a chain of <depth> blocks under the
; edge "load %x == 0", then a diamond on "load %y == 7" whose arms are siblings
; in the dominator tree.
;
; Positive: the outer condition, established <depth> blocks up, still removes the
; stores of 0 to %x, and the diamond's condition removes the store in arm1.
; Negative: arm2 is a sibling of arm1, so arm1's condition must not leak into it
; (its store of 7 stays); the store in the other arm of the outer branch is not
; implied by "load %x == 0" either.
;
; The depth-900 run is limited to 128 KiB of stack, musl's default thread stack
; size (the walk may nest up to dse-max-dom-cond-depth = 1024 levels). With the
; recursive walk of pristine 23.1.2 that run dies with SIGSEGV whenever the limit
; is 192 KiB or less (measured on x86_64); the iterative walk passes down to
; 64 KiB. The last run checks that the dse-max-dom-cond-depth limit still stops
; the walk.
;
; RUN: bash %S/gen-dse-domtree.sh 3 | opt -aa-pipeline=basic-aa -passes='dse,verify<memoryssa>' -S | FileCheck %s
; RUN: ulimit -s 128; bash %S/gen-dse-domtree.sh 900 | opt -aa-pipeline=basic-aa -passes='dse,verify<memoryssa>' -S | FileCheck %s
; RUN: bash %S/gen-dse-domtree.sh 900 | opt -aa-pipeline=basic-aa -passes='dse,verify<memoryssa>' -dse-max-dom-cond-depth=100 -S | FileCheck %s --check-prefix=LIMIT

; CHECK-LABEL: define void @deep(
; CHECK: arm1:
; CHECK-NOT: store
; CHECK: br label %join
; CHECK: arm2:
; CHECK-NEXT: store i32 7, ptr %y
; CHECK-NOT: store
; CHECK: br label %join
; CHECK: sibling:
; CHECK-NEXT: store i32 0, ptr %x

; LIMIT-LABEL: define void @deep(
; LIMIT: arm1:
; LIMIT-NEXT: store i32 7, ptr %y
; LIMIT-NEXT: store i32 0, ptr %x
