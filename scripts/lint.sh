#!/usr/bin/env bash
# Mechanical checks that need no EDA tools. Exit 1 on the first failing group.
#
#   scripts/lint.sh                  all checks below
#   scripts/lint.sh --moves <rev>    only: every file moved since <rev> is a 100 % rename
#
# 1. No ignored by-products under rtl/, sim/, fw/ or docs/design/ except the
#    build outputs the Makefiles own (sim/build/, fw/build/, docs/design/build/,
#    sim/asm/program.hex, program_asm.out). Catches Vivado writing .Xil/ or
#    clockInfo.txt next to the sources and a pdflatex run started by hand beside
#    design.tex. Also no Vivado by-product at the repository root or under
#    vivado/, constraints/, docs/ or scripts/: everything Vivado writes belongs
#    under build/.
# 2. No tracked file refers to a retired path (old Vivado import tree,
#    firmware/, bench_iverilog.v, vivado/sources.tcl); docs/design/notes.md is
#    exempt because it quotes removed comments verbatim. No tracked file, the
#    notes included, uses retired vocabulary either: "tutorial", a tutorial
#    step number (10 to 24), step1.v, "ticket #", "seam 1/2". The published
#    tree describes the design, not where it came from or how it was tidied.
# 3. Markdown prose lines are at most 100 characters; table rows are exempt.
# 4. vivado/rtl_sources.txt lists exactly the tracked rtl/*.v and rtl/*.vh
#    files: a file missing from the list compiles nowhere and fails nowhere.
# 5. File name equals module name, one word without underscores, for every
#    rtl/*.v and sim/*.v (docs/CONTRIBUTING.md). sim/asm/ is exempt: the
#    third-party assembler and the sample program it assembles.
# 6. Active-low signals are declared with an _n suffix, never resetn/rstn.
# 7. Section banners ("// ---- name ----...") in rtl/*.v and sim/*.v end at column 80.
# 8. The firmware's copies of the memory map (fw/io.h, fw/putchar.S, fw/start*.S,
#    fw/memory.ld, fw/Makefile) and the README's memory-map tables equal
#    rtl/defines.vh; start*.S and memory.ld take the RAM size from the one
#    RAM_SIZE in fw/Makefile: fw/tests/check_memory_map.sh, whose --selftest proves it
#    detects a change or deletion of every value it checks.
# 9. Every `define, parameter and localparam name in rtl/*.v, rtl/*.vh, sim/*.v
#    and sim/asm/*.v is UPPER_CASE ([A-Z][A-Z0-9_]*, docs/CONTRIBUTING.md). The
#    first name of each declaration is checked, with // and single-line /* */
#    comments stripped. sim/asm/riscv_assembly.v is exempt: it is third-party
#    (Bruno Levy's assembler, kept as upstream wrote it) and its lower-case
#    localparams are the RISC-V ABI register names (a0, sp, ra, ...) that the
#    assembly programs use as mnemonics.
# 10. The golden-trace summary in docs/baseline.md (cycles, simulated seconds,
#    UART bytes, LED changes) equals the END and LEDS lines of the golden trace:
#    sim/tests/check_golden_mirror.sh, whose --selftest proves it detects a
#    change or deletion of every value it checks.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0

moves_check() {
    local base="$1"
    [ -n "$base" ] || { echo "usage: scripts/lint.sh --moves <rev>" >&2; exit 2; }
    # With -M100% only byte-identical moves are reported as renames; anything
    # else shows up as an add or delete and is listed here.
    local bad
    bad=$(git diff -M100% --name-status --diff-filter=AD "$base" -- . ':!*.md' ':!LICENSE' ':!Makefile' ':!.gitignore' ':!scripts/*' ':!vivado/*')
    if [ -n "$bad" ]; then
        echo "FAIL: not a pure move since $base (A = added, D = deleted):"
        echo "$bad"
        exit 1
    fi
    echo "PASS: every file moved since $base is a byte-identical rename"
    exit 0
}
[ "${1:-}" = "--moves" ] && moves_check "${2:-}"

echo "== by-products in the source tree"
allowed='^!! (sim/build/|fw/build/|docs/design/build/|sim/asm/program\.hex|sim/asm/program_asm\.out)$'
stray=$(git status --short --ignored -- rtl sim fw docs/design | grep '^!!' | grep -Ev "$allowed" || true)
if [ -n "$stray" ]; then
    echo "FAIL: ignored files under rtl/, sim/, fw/ or docs/design/ that no Makefile owns:"
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

echo "== retired paths"
retired='bench_iverilog\.v|vivado/sources\.tcl|(^|[^a-z_/])firmware/'
hits=$(git ls-files | grep -v '^docs/design/notes\.md$' | xargs grep -nE "$retired" 2>/dev/null | grep -v '^scripts/lint.sh:' || true)
if [ -n "$hits" ]; then
    echo "FAIL: references to paths that no longer exist:"
    echo "$hits"
    fail=1
fi
vocabulary='[Tt]utorial|\b[Ss]teps? ?(1[0-9]|2[0-4])\b|step1\.v|ticket #|seam [12]'
hits=$(git ls-files | xargs grep -nE "$vocabulary" 2>/dev/null | grep -v '^scripts/lint.sh:' || true)
if [ -n "$hits" ]; then
    echo "FAIL: retired vocabulary (tutorial, step numbers, step1.v, ticket #, seam):"
    echo "$hits"
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
for f in $(git ls-files 'rtl/*.v' 'sim/*.v' | grep -v '^sim/asm/'); do
    want=$(basename "$f" .v)
    got=$(grep -oE '^\s*module\s+[A-Za-z_][A-Za-z0-9_]*' "$f" | awk '{print $2}')
    if [ "$got" != "$want" ]; then
        echo "FAIL: $f declares module '${got:-<none>}', expected '$want' (one module per file, same name)"
        fail=1
    elif [[ ! "$got" =~ ^[A-Za-z][A-Za-z0-9]*$ ]]; then
        echo "FAIL: $f: module '$got' is not one word (docs/CONTRIBUTING.md, Naming: no underscores)"
        fail=1
    fi
done

echo "== active-low suffix"
bad_n=$(git ls-files 'rtl/*.v' 'sim/*.v' \
    | xargs grep -nE '^\s*(input|output|inout|wire|reg)\b.*\b[A-Za-z_]*(resetn|rstn|nreset|nrst)\b' 2>/dev/null || true)
if [ -n "$bad_n" ]; then
    echo "FAIL: active-low signals take an _n suffix (reset_n), see docs/CONTRIBUTING.md:"
    echo "$bad_n"
    fail=1
fi

echo "== section banner width"
bad_banner=$(git ls-files 'rtl/*.v' 'sim/*.v' \
    | xargs awk '/^[[:space:]]*\/\/ ----.*----$/ && length != 80 {print FILENAME":"FNR": "length" chars"}')
if [ -n "$bad_banner" ]; then
    echo "FAIL: section banners end at column 80 (docs/CONTRIBUTING.md):"
    echo "$bad_banner"
    fail=1
fi

echo "== firmware and README memory-map mirrors"
fw/tests/check_memory_map.sh | grep -E '^(FAIL|PASS)' || fail=1
fw/tests/check_memory_map.sh --selftest | grep -E '^(FAIL|PASS)' || fail=1

echo "== UPPER_CASE macros, parameters and localparams"
bad_case=$(git ls-files 'rtl/*.v' 'rtl/*.vh' 'sim/*.v' 'sim/asm/*.v' \
    | grep -v '^sim/asm/riscv_assembly\.v$' \
    | xargs perl -ne '
        s{//.*}{}; s{/\*.*?\*/}{}g;
        while (/(?:`define|\b(?:parameter|localparam)\b)\s+(?:(?:integer|real|time|signed|unsigned)\s+)*(?:\[[^\]]*\]\s*)?(?:signed\s+)?([A-Za-z_][A-Za-z0-9_]*)/g) {
            print "$ARGV:$.: $1\n" unless $1 =~ /^[A-Z][A-Z0-9_]*$/;
        }
        close ARGV if eof;' 2>/dev/null || true)
if [ -n "$bad_case" ]; then
    echo "FAIL: macro, parameter and localparam names are UPPER_CASE (docs/CONTRIBUTING.md):"
    echo "$bad_case"
    fail=1
fi

echo "== golden-trace mirrors in docs/baseline.md"
sim/tests/check_golden_mirror.sh | grep -E '^(FAIL|PASS)' || fail=1
sim/tests/check_golden_mirror.sh --selftest | grep -E '^(FAIL|PASS)' || fail=1

[ "$fail" = 0 ] && echo "PASS: lint clean"
exit "$fail"
