#!/usr/bin/env bash
# Golden-trace mirror check: the run summary in docs/baseline.md (cycles
# simulated, the simulated seconds they make at CLK_HZ, UART bytes, LED
# changes) must equal the END and LEDS lines of sim/golden/mandelbrot_bram.txt,
# so a re-captured golden trace cannot leave the baseline document behind.
# Runs without any tool; `make lint` calls it. Exit 1 on any mismatch or
# missing row.
#
#   check_golden_mirror.sh             check the working tree (ROOT=<dir> checks another tree)
#   check_golden_mirror.sh --selftest  prove the check detects drift: copy the files to a
#                                      temporary tree, alter or delete each checked value in
#                                      turn and require a FAIL; the working tree is untouched
set -uo pipefail
ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
GOLDEN="$ROOT/sim/golden/mandelbrot_bram.txt"
DOC="$ROOT/docs/baseline.md"
DEF="$ROOT/rtl/defines.vh"
fail=0

# One mutation per checked value: <file>@<sed -E expression>@<what>. The
# expressions match the shape of a row, not today's numbers, so re-capturing
# the golden trace leaves them valid; one that stops matching leaves the copy
# intact and the self-test reports it as undetected.
MUTATIONS='
docs/baseline.md@s/^([|] Cycles simulated [|] )/\11/@cycle count changed
docs/baseline.md@s/[(]([0-9.]+) s at /(1\1 s at /@simulated seconds changed
docs/baseline.md@/^[|] Cycles simulated [|]/d@cycles row deleted
docs/baseline.md@s/^([|] UART bytes [|] )/\11/@UART byte count changed
docs/baseline.md@s/^([|] LED changes [|] )/\11/@LED change count changed
docs/baseline.md@s/`LEDS ([0-9]+)/`LEDS 1\1/@LED line changed
sim/golden/mandelbrot_bram.txt@s/ cycles=/ cycles=1/@golden cycle count changed
'

selftest() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    mkdir -p "$tmp/docs" "$tmp/rtl" "$tmp/sim/golden"
    cp "$DOC" "$tmp/docs/"; cp "$DEF" "$tmp/rtl/"; cp "$GOLDEN" "$tmp/sim/golden/"
    if ! ROOT="$tmp" bash "$0" >/dev/null; then
        echo "FAIL  selftest: the unmodified copy does not pass"; exit 1
    fi
    local n=0 file expr what
    while IFS='@' read -r file expr what; do
        [ -n "$file" ] || continue
        sed -i -E "$expr" "$tmp/$file"
        if ROOT="$tmp" bash "$0" >/dev/null; then
            echo "FAIL  selftest: $file: $what was not detected"; fail=1
        else
            echo "ok    selftest: $file: $what detected"
        fi
        cp "$ROOT/$file" "$tmp/$file"
        n=$((n + 1))
    done <<< "$MUTATIONS"
    [ "$fail" = 0 ] && echo "PASS: selftest: all $n mutations detected"
    exit "$fail"
}
[ "${1:-}" = "--selftest" ] && selftest

# Text of a docs/baseline.md table row after its label, or empty.
row() { grep -E "^\| $1 \|" "$DOC" | head -n 1 | sed -E "s/^\| $1 \| //"; }
# Leading number of a row, digit-group spaces removed ("11 014 (..." -> 11014).
lead() { sed -nE 's/^([0-9][0-9 ]*) [(].*/\1/p' <<< "$1" | tr -d ' '; }

# expect <name> <docs value> <golden value>
expect() {
    if [ -z "$2" ]; then
        echo "FAIL  docs/baseline.md: $1 not found"
        fail=1
    elif [ "$2" != "$3" ]; then
        echo "FAIL  docs/baseline.md: $1 is $2, the golden trace says $3"
        fail=1
    else
        echo "ok    $1 = $3"
    fi
}

end=$(grep '^END ' "$GOLDEN")
cycles=$(sed -nE 's/.* cycles=([0-9]+).*/\1/p' <<< "$end")
bytes=$(sed -nE 's/.* uart_bytes=([0-9]+).*/\1/p' <<< "$end")
clk=$(grep -E '^`define[[:space:]]+CLK_HZ[[:space:]]' "$DEF" | awk '{print $3}')
[ -n "$cycles" ] && [ -n "$bytes" ] && [ -n "$clk" ] \
    || { echo "FAIL  no END line in the golden trace, or no CLK_HZ in rtl/defines.vh"; exit 1; }

r=$(row 'Cycles simulated')
expect 'cycles simulated' "$(lead "$r")" "$cycles"
expect 'simulated seconds' "$(sed -nE 's/^[0-9 ]+[(]([0-9.]+) s at .*/\1/p' <<< "$r")" \
    "$(awk -v c="$cycles" -v f="$clk" 'BEGIN { printf "%.3f", c / f }')"
expect 'UART bytes' "$(lead "$(row 'UART bytes')")" "$bytes"
r=$(row 'LED changes')
expect 'LED changes' "$(lead "$r")" "$(grep -c '^LEDS ' "$GOLDEN")"
expect 'LED lines' "$(grep -oE '`LEDS [^`]*`' <<< "$r" | tr -d '`' | paste -sd '|')" \
    "$(grep '^LEDS ' "$GOLDEN" | paste -sd '|')"

[ "$fail" = 0 ] && echo "PASS: docs/baseline.md matches the golden trace"
exit "$fail"
