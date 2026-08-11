#!/usr/bin/env bash
# Print a block of source lines ready to paste into docs/design/notes.md.
#
#   scripts/quote_comment.sh [<rev>:]<file> <from> <to>
#
# <from> and <to> are sed addresses: line numbers or /patterns/. Prefer
# patterns anchored on the block's first and last line once the file has
# been edited since it was read, as line numbers go stale with every edit.
# The first and last quoted lines are echoed on stderr so a wrong range shows
# at once.
#
# Tabs are expanded, trailing whitespace dropped and the indentation common
# to the block removed, so relative indentation inside the block survives. A
# block made only of comment lines also loses its "// " prefix; a block that
# mixes code and comments is printed as code, comment markers included.
# Lines still longer than 100 characters are reported on stderr: re-wrap
# those by hand, nothing else.
set -euo pipefail
[ $# -eq 3 ] || { sed -n '2,17p' "$0" >&2; exit 2; }
src=$1; from=$2; to=$3

if [[ $src == *:* ]]; then
    text=$(git show "$src")
else
    text=$(cat "$src")
fi

block=$(printf '%s\n' "$text" | sed -n "${from},${to}p")
[ -n "$block" ] || { echo "no lines match $from,$to in $src" >&2; exit 1; }
printf 'first: %s\nlast:  %s\n' "$(printf '%s\n' "$block" | head -1)" \
                                  "$(printf '%s\n' "$block" | tail -1)" >&2

printf '%s\n' "$block" | expand -t 8 | sed -E 's/[[:space:]]+$//' \
| awk '
    { lines[NR] = $0 }
    /[^ ]/ {
        match($0, /^ */)
        if (min == "" || RLENGTH < min) min = RLENGTH
        if ($0 !~ /^ *\/\//) all_comment = 0
    }
    BEGIN { all_comment = 1 }
    END {
        for (i = 1; i <= NR; i++) {
            l = substr(lines[i], min + 1)
            if (all_comment) sub(/^\/\/ ?/, "", l)
            print l
            if (length(l) > 100) printf "line %d: %d chars, re-wrap by hand\n", i, length(l) > "/dev/stderr"
        }
    }'
