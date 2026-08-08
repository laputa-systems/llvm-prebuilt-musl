; RUN: opt -passes=instcombine -S < %s | FileCheck %s
;
; computeKnownBitsAddSub must prove that b - smin(b, a) is non-negative.

define i64 @sub_smin(i32 %a, i32 %b) {
; CHECK-LABEL: define i64 @sub_smin(
; CHECK: %sub = sub nsw i32 %b, %min
; CHECK-NEXT: %ext = zext nneg i32 %sub to i64
  %min = call i32 @llvm.smin.i32(i32 %b, i32 %a)
  %sub = sub nsw i32 %b, %min
  %ext = sext i32 %sub to i64
  ret i64 %ext
}

declare i32 @llvm.smin.i32(i32, i32)
