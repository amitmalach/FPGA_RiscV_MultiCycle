// defines.vh -- SoC-wide constants: bus widths, memory map, boot addresses.
// The single place the memory map is defined. Software mirrors the IO values
// in fw/io.h and fw/putchar.S, the IO base and RAM top in fw/start*.S, the
// regions in fw/memory.ld and fw/Makefile; fw/tests/check_memory_map.sh (lint
// rule 8) keeps them equal.
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
// RAM_WORDS overrides it. Mirrored by RAM_SIZE in fw/Makefile and the RAM
// region in fw/memory.ld (bytes) and the stack top in fw/start*.S.
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
