// defines.vh -- SoC-wide constants: bus widths, memory map, boot addresses.
// The single place the memory map is defined. Software mirrors the IO values
// and the flash base in fw/io.h, the UART register offsets and busy bit in
// fw/putchar.S, the LED offset in fw/blinker.S, the IO base in fw/start*.S,
// the RAM size as RAM_SIZE in fw/Makefile (fed to start*.S and memory.ld as a
// symbol) and the flash region in fw/memory.ld; the README's memory-map tables
// repeat the addresses. fw/tests/check_memory_map.sh (lint rule 8) keeps them
// all equal.
// sim/asm/program_asm.v includes this file instead of copying.
`ifndef DEFINES_VH
`define DEFINES_VH

// ---- bus ------------------------------------------------------------------
// ADDR_W and DATA_W are the RV32I word: the modules declare their ports with
// them, but the core's byte-lane slices assume 32, so they are not a knob.
`define ADDR_W   32            // byte address
`define DATA_W   32
`define WMASK_W  4             // one write enable per byte lane
`define LEDS_W   8

// ---- RAM ------------------------------------------------------------------
// Default depth of the on-chip RAM in words (6 KB); the SOC parameter
// RAM_WORDS overrides it. Mirrored once, as RAM_SIZE (bytes) in fw/Makefile; an
// override needs firmware from `make -C fw RAM_SIZE=<bytes> HEX_OUT=<path>`.
`define RAM_WORDS 1536

// ---- clock ----------------------------------------------------------------
`define CLK_HZ    200000000    // Genesys 2 system clock
`define UART_BAUD 115200       // default; the SOC parameter UART_BAUD overrides it

// ---- memory map (byte addresses) -----------------------------------------
// A region is selected by one address bit: its base has exactly that bit set.
//   RAM       : no region bit set
//   IO        : bit 22 set, bit 24 clear
//   SPI flash : bit 24 set; the low 24 bits address 16 MB inside the chip
`define RAM_BASE       32'h00000000
`define IO_BASE        32'h00400000
`define SPIFLASH_BASE  32'h01000000
`define SPIFLASH_ADDR_W 24

// ---- IO registers (byte offsets from IO_BASE, one address bit each) ------
`define IO_LEDS        32'h00000004   // write: LED register
`define IO_UART_DAT    32'h00000008   // write: send one byte
`define IO_UART_CNTL   32'h00000010   // read: UART status
`define UART_BUSY_BIT  9              // status bit: transmitter busy

// ---- boot -----------------------------------------------------------------
// Flash boot: program code sits 13 MB into the chip, after the bitstream
// (~10.9 MB) and the ST_NICCC scene data (12 MB..12.6 MB), 64 KB aligned.
`define SPIFLASH_CODE_OFFSET 32'h00D00000
`define BOOT_ADDR_FLASH      (`SPIFLASH_BASE + `SPIFLASH_CODE_OFFSET)
`define BOOT_ADDR_BRAM       `RAM_BASE

`endif
