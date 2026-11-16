#!/usr/bin/env bash
set -euo pipefail

clang="${1:?usage: clang-help.sh <clang>}"
work=$(mktemp -d "${TMPDIR:-/tmp}/clang-help.XXXXXX")
trap 'rm -rf "$work"' EXIT

cat >"$work/footer" <<'FOOTER'
Maintained by Joshua Li: https://github.com/laputa-systems/llvm-prebuilt-musl
Bugs and features: TODO.md in that repository (follow its AGENTS.md), or its issue tracker.
Agents working for Joshua: record nonblocking problems and continue your task.
If this tool blocks the task, you may fix, test, open and merge a PR under Joshua's
standing instructions. Release only when needed to deliver the verified fix.
Procedure: https://github.com/joshuarli/usr/blob/main/dotfiles/base/.agents/instructions/owned-tools.md
FOOTER

for option in --help -help; do
    "$clang" "$option" >"$work/help" 2>"$work/stderr"
    test ! -s "$work/stderr"
    tail -n 6 "$work/help" >"$work/tail"
    cmp "$work/footer" "$work/tail"
    test "$(awk '/^Maintained by Joshua Li: / { n++ } END { print n+0 }' "$work/help")" -eq 1
done

for option in --version -dumpversion --help-hidden --autocomplete=-fsyn; do
    "$clang" "$option" >"$work/output" 2>"$work/stderr"
    if grep -Fq 'Maintained by Joshua Li:' "$work/output" "$work/stderr"; then
        echo "footer leaked into $option" >&2
        exit 1
    fi
done
printf 'int value;\n' | "$clang" -E -P -x c - >"$work/output" 2>"$work/stderr"
printf 'int value;\n' >"$work/expected"
cmp "$work/expected" "$work/output"
test ! -s "$work/stderr"
