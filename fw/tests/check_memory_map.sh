#!/usr/bin/env bash
# Memory-map mirror check: every constant the firmware repeats from
# rtl/defines.vh (IO base and register offsets, UART busy bit, RAM size and
# base, flash base and code offset) must still equal the RTL value. Runs
# without any tool; `make lint` calls it. Exit 1 on the first mismatch group.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEF="$ROOT/rtl/defines.vh"
FW="$ROOT/fw"
fail=0

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
    if [ "$(num "$3")" = "$4" ]; then
        echo "ok    $1: $2 = $3"
    else
        echo "FAIL  $1: $2 = $3, rtl/defines.vh gives $4"
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

# C header: #define NAME value
cdef() { grep -E "^#define[[:space:]]+$2[[:space:]]" "$FW/$1" | awk '{print $3}'; }
# Assembler: .equ NAME, value
aequ() { grep -E "^\.equ[[:space:]]+$2," "$FW/$1" | sed -E 's/.*,[[:space:]]*//; s/[[:space:]]+$//'; }
# Assembler: li <reg>,<value>  (first match)
ali()  { grep -E "^[[:space:]]*li[[:space:]]+$2," "$FW/$1" | head -1 | sed -E 's/.*,[[:space:]]*//; s/[[:space:]]+$//'; }
# Makefile: NAME = value
mvar() { grep -E "^$2[[:space:]]*=" "$FW/Makefile" | sed -E 's/.*=[[:space:]]*//'; }
# Linker script MEMORY line: REGION (..) : ORIGIN = x, LENGTH = y
ldfield() { grep -E "^[[:space:]]*$1[[:space:]]*\(" "$FW/memory.ld" | sed -E "s/.*$2[[:space:]]*=[[:space:]]*([0-9a-fA-Fx]+).*/\1/"; }

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
    expect "$s" IO_BASE          "$(aequ "$s" IO_BASE)" "$IO_BASE"
    expect "$s" "sp (top of RAM)" "$(ali "$s" sp)"       "$(( RAM_BASE + RAM_BYTES ))"
done

echo "== fw/memory.ld"
expect memory.ld "RAM ORIGIN"   "$(ldfield RAM ORIGIN)"   "$RAM_BASE"
expect memory.ld "RAM LENGTH"   "$(ldfield RAM LENGTH)"   "$RAM_BYTES"
expect memory.ld "FLASH ORIGIN" "$(ldfield FLASH ORIGIN)" "$FLASH_ORIGIN"

echo "== fw/Makefile"
expect Makefile RAM_SIZE          "$(mvar Makefile RAM_SIZE)"          "$RAM_BYTES"
expect Makefile FLASH_CODE_OFFSET "$(mvar Makefile FLASH_CODE_OFFSET)" "$SPIFLASH_CODE_OFFSET"

[ "$fail" = 0 ] && echo "PASS: firmware memory-map mirrors match rtl/defines.vh"
exit "$fail"
