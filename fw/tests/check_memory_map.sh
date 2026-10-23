#!/usr/bin/env bash
# Memory-map mirror check: every constant the firmware repeats from
# rtl/defines.vh (IO base and register offsets, UART busy bit, RAM size and
# base, flash base and code offset) must still equal the RTL value, and so
# must the addresses in the README's memory-map tables. The RAM size has one
# firmware copy, RAM_SIZE in fw/Makefile: the stack top in fw/start*.S and
# the RAM length in fw/memory.ld must spell that symbol, not a number. Runs
# without any tool; `make lint` calls it. Runs every group; exit 1 if any
# value mismatched or was not found.
#
#   check_memory_map.sh             check the working tree (ROOT=<dir> checks another tree)
#   check_memory_map.sh --selftest  prove the check detects drift: copy the mirror files to a
#                                   temporary tree, alter or delete each checked value in
#                                   turn and require a FAIL; the working tree is untouched
set -uo pipefail
ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
DEF="$ROOT/rtl/defines.vh"
FW="$ROOT/fw"
README="$ROOT/README.md"
fail=0

# One mutation per checked value: <file>@<sed -E expression>@<what>. A pattern that
# no longer matches leaves the copy intact, so the check passes and the self-test
# reports it as undetected: a stale mutation fails, it never hides.
MUTATIONS='
fw/io.h@s/^(#define[[:space:]]+IO_BASE[[:space:]]+)0x400000/\10x200000/@IO_BASE changed
fw/io.h@s/^(#define[[:space:]]+IO_LEDS[[:space:]]+)4$/\18/@IO_LEDS changed
fw/io.h@s/^(#define[[:space:]]+IO_UART_DAT[[:space:]]+)8$/\116/@IO_UART_DAT changed
fw/io.h@s/^(#define[[:space:]]+IO_UART_CNTL[[:space:]]+)16$/\1/@IO_UART_CNTL deleted
fw/putchar.S@s/^(\.equ IO_BASE, )0x400000/\10x400001/@IO_BASE changed
fw/putchar.S@s/^(\.equ IO_LEDS, )4$/\12/@IO_LEDS changed
fw/putchar.S@s/^(\.equ IO_UART_DAT, )8$/\1/@IO_UART_DAT deleted
fw/putchar.S@s/^(\.equ IO_UART_CNTL, )16$/\132/@IO_UART_CNTL changed
fw/putchar.S@s/1<<9/1<<8/@UART busy bit changed
fw/start.S@s/^(\.equ IO_BASE, )0x400000/\10x800000/@IO_BASE changed
fw/start.S@s/li   sp,RAM_SIZE/li   sp,0x1800/@stack top typed as a literal
fw/start_spiflash.S@s/^(\.equ IO_BASE, )0x400000/\10x800000/@IO_BASE changed
fw/start_spiflash.S@s/li   sp,RAM_SIZE/li   sp,0x1800/@stack top typed as a literal
fw/memory.ld@s/ORIGIN = 0x00000000/ORIGIN = 0x00000100/@RAM ORIGIN changed
fw/memory.ld@s/ORIGIN = 0x00000000,/ORIGIN = ,/@RAM ORIGIN deleted (a zero value: the empty guard, not the compare, must catch it)
fw/memory.ld@s/LENGTH = RAM_SIZE/LENGTH = 0x1800/@RAM LENGTH typed as a literal
fw/memory.ld@s/ORIGIN = 0x01D00000/ORIGIN = 0x01C00000/@FLASH ORIGIN changed
fw/Makefile@s/^(RAM_SIZE[[:space:]]*=[[:space:]]*)6144$/\18192/@RAM_SIZE changed
fw/Makefile@s/^(FLASH_CODE_OFFSET[[:space:]]*=[[:space:]]*)0xD00000$/\1/@FLASH_CODE_OFFSET deleted
README.md@s/0x0000_17FF/0x0000_1FFF/@RAM top changed
README.md@s/0x0040_0004/0x0040_0002/@IO_LEDS address changed
README.md@s/0x0040_0008/0x0040_0009/@IO_UART_DAT address changed
README.md@s/0x0040_0010/0x0040_0020/@IO_UART_CNTL address changed
README.md@s/0x0100_0000/0x0200_0000/@SPI flash base changed
README.md@s/0x01D0_0000/0x01C0_0000/@flash reset vector changed
README.md@s/`0x01D0_0000`//@flash reset vector deleted
README.md@s/[|] bit 24 [|] read, fetch [|]/| bit twenty-four | read, fetch |/@flash row reworded
'

selftest() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    mkdir -p "$tmp/rtl" "$tmp/fw"
    cp "$DEF" "$tmp/rtl/"; cp "$README" "$tmp/"
    cp "$FW"/io.h "$FW"/putchar.S "$FW"/start.S "$FW"/start_spiflash.S "$FW"/memory.ld "$FW"/Makefile "$tmp/fw/"
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

# Value of a `define in defines.vh, as a decimal string. Verilog literals
# 32'h.. and 32'd.. and plain decimals are accepted; anything else is an error.
vdef() {
    local raw
    raw=$(grep -E "^\`define[[:space:]]+$1[[:space:]]" "$DEF" | awk '{print $3}')
    case "$raw" in
        *\'h*) printf '%d\n' "0x${raw#*\'h}" ;;
        *\'d*) printf '%d\n' "${raw#*\'d}" ;;
        *)     printf '%d\n' "$raw" ;;
    esac
}
# Any C/asm/ld number (0x.. or decimal) as a decimal string.
num() { printf '%d\n' "$1"; }

# expect <where> <name> <mirror value> <rtl value>
expect() {
    local got
    if [ -z "$3" ]; then
        echo "FAIL  $1: $2 is missing (no value found)"
        fail=1
    elif ! got=$(num "$3" 2>/dev/null); then
        echo "FAIL  $1: $2 = '$3' is not a number"
        fail=1
    elif [ "$got" = "$4" ]; then
        echo "ok    $1: $2 = $3"
    else
        echo "FAIL  $1: $2 = $3, rtl/defines.vh gives $4"
        fail=1
    fi
}
# expect_text <where> <name> <mirror text> <required text>: a value that must
# be written as a symbol the build defines, so there is no number to compare.
expect_text() {
    if [ "$3" = "$4" ]; then
        echo "ok    $1: $2 = $3"
    else
        echo "FAIL  $1: $2 = '$3', must be the symbol $4"
        fail=1
    fi
}

for name in IO_BASE IO_LEDS IO_UART_DAT IO_UART_CNTL UART_BUSY_BIT RAM_BASE RAM_WORDS \
            SPIFLASH_BASE SPIFLASH_CODE_OFFSET; do
    grep -qE "^\`define[[:space:]]+$name[[:space:]]" "$DEF" || { echo "FAIL: no \`define $name in $DEF"; exit 2; }
done
IO_BASE=$(vdef IO_BASE);           IO_LEDS=$(vdef IO_LEDS)
IO_UART_DAT=$(vdef IO_UART_DAT);   IO_UART_CNTL=$(vdef IO_UART_CNTL)
UART_BUSY_BIT=$(vdef UART_BUSY_BIT)
RAM_BASE=$(vdef RAM_BASE);         RAM_BYTES=$(( $(vdef RAM_WORDS) * 4 ))
SPIFLASH_BASE=$(vdef SPIFLASH_BASE)
SPIFLASH_CODE_OFFSET=$(vdef SPIFLASH_CODE_OFFSET)
FLASH_ORIGIN=$(( SPIFLASH_BASE + SPIFLASH_CODE_OFFSET ))
RAM_TOP=$(( RAM_BASE + RAM_BYTES - 1 ))

# C header: #define NAME value
cdef() { grep -E "^#define[[:space:]]+$2[[:space:]]" "$FW/$1" | awk '{print $3}'; }
# Assembler: .equ NAME, value
aequ() { grep -E "^\.equ[[:space:]]+$2," "$FW/$1" | sed -E 's/.*,[[:space:]]*//; s/[[:space:]]+$//'; }
# Assembler: li <reg>,<value>  (first match)
ali()  { grep -E "^[[:space:]]*li[[:space:]]+$2," "$FW/$1" | head -1 | sed -E 's/.*,[[:space:]]*//; s/[[:space:]]+$//'; }
# Makefile: NAME = value
mvar() { grep -E "^$2[[:space:]]*=" "$FW/Makefile" | sed -E 's/.*=[[:space:]]*//'; }
# README table row: the $2-th 0x.. address on the first table row matching $1,
# underscores stripped (the README writes 0x0040_0004). Anchor on a cell that
# names the row uniquely (the Select column, a register name, the boot mode),
# never on prose that a rewording would move to another row.
rdaddr() { grep -E '^\|' "$README" | grep -E "$1" | head -1 | grep -oE '0x[0-9A-Fa-f_]+' | sed -n "${2}p" | tr -d _; }
# Linker script MEMORY line: REGION (..) : ORIGIN = x, LENGTH = y
ldfield() { grep -E "^[[:space:]]*$1[[:space:]]*\(" "$FW/memory.ld" | grep -oE "$2[[:space:]]*=[[:space:]]*[^,[:space:]]+" | sed -E 's/.*=[[:space:]]*//'; }

echo "== fw/io.h"
expect io.h IO_BASE      "$(cdef io.h IO_BASE)"      "$IO_BASE"
expect io.h IO_LEDS      "$(cdef io.h IO_LEDS)"      "$IO_LEDS"
expect io.h IO_UART_DAT  "$(cdef io.h IO_UART_DAT)"  "$IO_UART_DAT"
expect io.h IO_UART_CNTL "$(cdef io.h IO_UART_CNTL)" "$IO_UART_CNTL"

echo "== fw/putchar.S"
expect putchar.S IO_BASE      "$(aequ putchar.S IO_BASE)"      "$IO_BASE"
expect putchar.S IO_LEDS      "$(aequ putchar.S IO_LEDS)"      "$IO_LEDS"
expect putchar.S IO_UART_DAT  "$(aequ putchar.S IO_UART_DAT)"  "$IO_UART_DAT"
expect putchar.S IO_UART_CNTL "$(aequ putchar.S IO_UART_CNTL)" "$IO_UART_CNTL"
busy=$(grep -oE 'li[[:space:]]+t0,[[:space:]]*1<<[0-9]+' "$FW/putchar.S" | sed -E 's/.*<<//')
expect putchar.S "UART busy bit (li t0, 1<<n)" "${busy:-missing}" "$UART_BUSY_BIT"

echo "== fw/start.S, fw/start_spiflash.S"
for s in start.S start_spiflash.S; do
    expect "$s" IO_BASE               "$(aequ "$s" IO_BASE)" "$IO_BASE"
    expect_text "$s" "sp (top of RAM)" "$(ali "$s" sp)"       RAM_SIZE
done

echo "== fw/memory.ld"
expect memory.ld "RAM ORIGIN"        "$(ldfield RAM ORIGIN)"   "$RAM_BASE"
expect_text memory.ld "RAM LENGTH"   "$(ldfield RAM LENGTH)"   RAM_SIZE
expect memory.ld "FLASH ORIGIN" "$(ldfield FLASH ORIGIN)" "$FLASH_ORIGIN"

echo "== fw/Makefile"
expect Makefile RAM_SIZE          "$(mvar Makefile RAM_SIZE)"          "$RAM_BYTES"
expect Makefile FLASH_CODE_OFFSET "$(mvar Makefile FLASH_CODE_OFFSET)" "$SPIFLASH_CODE_OFFSET"

echo "== README.md memory-map tables"
expect README.md "RAM top"          "$(rdaddr '\| no region bit set \|' 2)" "$RAM_TOP"
expect README.md IO_LEDS            "$(rdaddr '`IO_LEDS`' 1)"           "$(( IO_BASE + IO_LEDS ))"
expect README.md IO_UART_DAT        "$(rdaddr '`IO_UART_DAT`' 1)"       "$(( IO_BASE + IO_UART_DAT ))"
expect README.md IO_UART_CNTL       "$(rdaddr '`IO_UART_CNTL`' 1)"      "$(( IO_BASE + IO_UART_CNTL ))"
expect README.md "SPI flash base"   "$(rdaddr '\| bit 24 \|' 1)"           "$SPIFLASH_BASE"
expect README.md "flash reset vector" "$(rdaddr '^\| Flash boot' 1)"      "$FLASH_ORIGIN"

[ "$fail" = 0 ] && echo "PASS: firmware and README memory-map mirrors match rtl/defines.vh"
exit "$fail"
