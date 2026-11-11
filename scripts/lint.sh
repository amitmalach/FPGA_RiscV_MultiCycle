#!/usr/bin/env bash
# Mechanical checks that need no EDA tools. Runs every check; exits 1 if any failed.
#
# 1. No ignored by-products under rtl/, sim/ or fw/ except the build outputs
#    the Makefiles own (sim/build/, fw/build/). Catches Vivado writing .Xil/ or
#    clockInfo.txt next to the sources. Also no Vivado by-product directly in
#    the repository root, vivado/, constraints/, docs/ or scripts/: everything
#    Vivado writes belongs under build/.
# 2. Markdown prose lines are at most 100 characters; table rows are exempt.
# 3. vivado/rtl_sources.txt lists exactly the tracked rtl/*.v and rtl/*.vh
#    files: a file missing from the list compiles nowhere and fails nowhere.
# 4. File name equals module name, one word without underscores, for every
#    rtl/*.v, sim/*.v and vivado/*/*.v (the flash register tool and its bench).
# 5. Active-low signals are declared with an _n suffix, never resetn/rstn.
# 6. Section banners ("// ---- name ----...") in rtl/*.v, sim/*.v and
#    vivado/*/*.v end at column 80.
# 7. fw/tests/check_memory_map.sh and its --selftest: every copy of a
#    memory-map value outside rtl/ equals rtl/defines.vh.
# 8. Every `define, parameter and localparam name in rtl/*.v, rtl/*.vh, sim/*.v
#    and vivado/*/*.v is UPPER_CASE ([A-Z][A-Z0-9_]*). The first name of each
#    declaration is checked, with // and single-line /* */ comments stripped.
# 9. sim/tests/check_golden_mirror.sh and its --selftest: the golden-trace
#    summary in docs/baseline.md equals the golden trace.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0

echo "== by-products in the source tree"
allowed='^!! (sim/build/|fw/build/)$'
stray=$(git status --short --ignored -- rtl sim fw | grep '^!!' | grep -Ev "$allowed" || true)
if [ -n "$stray" ]; then
    echo "FAIL: ignored files under rtl/, sim/ or fw/ that no Makefile owns:"
    echo "$stray"
    fail=1
fi

vivado_junk=$(find . vivado constraints docs scripts -maxdepth 1 \
    \( -name .Xil -o -name clockInfo.txt -o -name '*.jou' -o -name '*.log' \
       -o -name '*.str' -o -name '*.pb' -o -name 'hs_err_pid*' \) -print 2>/dev/null | sort -u)
if [ -n "$vivado_junk" ]; then
    echo "FAIL: Vivado by-products outside build/ (run the Tcl scripts from their output directory):"
    echo "$vivado_junk"
    fail=1
fi

echo "== markdown line length"
long=$(git ls-files '*.md' | xargs awk 'length > 100 && $0 !~ /^\|/ {print FILENAME":"FNR": "length" chars"}')
if [ -n "$long" ]; then
    echo "FAIL: prose lines over 100 characters:"
    echo "$long"
    fail=1
fi

echo "== rtl file list"
listed=$(grep -vE '^\s*(#|$)' vivado/rtl_sources.txt | sort)
tracked=$(git ls-files 'rtl/*.v' 'rtl/*.vh' | sort)
if [ "$listed" != "$tracked" ]; then
    echo "FAIL: vivado/rtl_sources.txt and the tracked rtl/ files differ (< list, > tree):"
    diff <(echo "$listed") <(echo "$tracked") | grep '^[<>]'
    fail=1
fi

echo "== module name equals file name"
for f in $(git ls-files 'rtl/*.v' 'sim/*.v' 'vivado/*/*.v'); do
    want=$(basename "$f" .v)
    got=$(grep -oE '^\s*module\s+[A-Za-z_][A-Za-z0-9_]*' "$f" | awk '{print $2}')
    if [ "$got" != "$want" ]; then
        echo "FAIL: $f declares module '${got:-<none>}', expected '$want' (one module per file, same name)"
        fail=1
    elif [[ ! "$got" =~ ^[A-Za-z][A-Za-z0-9]*$ ]]; then
        echo "FAIL: $f: module '$got' is not one word (no underscores)"
        fail=1
    fi
done

echo "== active-low suffix"
bad_n=$(git ls-files 'rtl/*.v' 'sim/*.v' 'vivado/*/*.v' \
    | xargs grep -nE '^\s*(input|output|inout|wire|reg)\b.*\b[A-Za-z_]*(resetn|rstn|nreset|nrst)\b' 2>/dev/null || true)
if [ -n "$bad_n" ]; then
    echo "FAIL: active-low signals take an _n suffix (reset_n):"
    echo "$bad_n"
    fail=1
fi

echo "== section banner width"
bad_banner=$(git ls-files 'rtl/*.v' 'sim/*.v' 'vivado/*/*.v' \
    | xargs awk '/^[[:space:]]*\/\/ ----.*----$/ && length != 80 {print FILENAME":"FNR": "length" chars"}')
if [ -n "$bad_banner" ]; then
    echo "FAIL: section banners end at column 80:"
    echo "$bad_banner"
    fail=1
fi

echo "== firmware memory-map mirrors"
fw/tests/check_memory_map.sh | grep -E '^(FAIL|PASS)' || fail=1
fw/tests/check_memory_map.sh --selftest | grep -E '^(FAIL|PASS)' || fail=1

echo "== UPPER_CASE macros, parameters and localparams"
bad_case=$(git ls-files 'rtl/*.v' 'rtl/*.vh' 'sim/*.v' 'vivado/*/*.v' \
    | xargs perl -ne '
        s{//.*}{}; s{/\*.*?\*/}{}g;
        while (/(?:`define|\b(?:parameter|localparam)\b)\s+(?:(?:integer|real|time|signed|unsigned)\s+)*(?:\[[^\]]*\]\s*)?(?:signed\s+)?([A-Za-z_][A-Za-z0-9_]*)/g) {
            print "$ARGV:$.: $1\n" unless $1 =~ /^[A-Z][A-Z0-9_]*$/;
        }
        close ARGV if eof;' 2>/dev/null || true)
if [ -n "$bad_case" ]; then
    echo "FAIL: macro, parameter and localparam names are UPPER_CASE:"
    echo "$bad_case"
    fail=1
fi

echo "== golden-trace mirrors in docs/baseline.md"
sim/tests/check_golden_mirror.sh | grep -E '^(FAIL|PASS)' || fail=1
sim/tests/check_golden_mirror.sh --selftest | grep -E '^(FAIL|PASS)' || fail=1

[ "$fail" = 0 ] && echo "PASS: lint clean"
exit "$fail"
