#!/usr/bin/env bash
# Print the IR for @deep used by dse-dominating-conditions.ll: a chain of <depth>
# single-successor blocks under the edge that establishes "load %x == 0",
# ending in a diamond that establishes "load %y == 7".
set -euo pipefail

depth="${1:?usage: gen-dse-domtree.sh <depth >= 1>}"
[ "$depth" -ge 1 ] || { echo "depth must be >= 1" >&2; exit 1; }

cat <<'IR'
define void @deep(ptr noalias %x, ptr noalias %y) {
entry:
  %v = load i32, ptr %x, align 4
  %c = icmp eq i32 %v, 0
  br i1 %c, label %chain0, label %sibling
IR

for ((i = 0; i < depth; i++)); do
    if [ $((i + 1)) -eq "$depth" ]; then next=leaf; else next="chain$((i + 1))"; fi
    printf 'chain%d:\n  br label %%%s\n' "$i" "$next"
done

cat <<'IR'
leaf:
  %w = load i32, ptr %y, align 4
  %d = icmp eq i32 %w, 7
  br i1 %d, label %arm1, label %arm2
arm1:
  store i32 7, ptr %y, align 4
  store i32 0, ptr %x, align 4
  br label %join
arm2:
  store i32 7, ptr %y, align 4
  store i32 0, ptr %x, align 4
  br label %join
join:
  br label %exit
sibling:
  store i32 0, ptr %x, align 4
  br label %exit
exit:
  ret void
}
IR
