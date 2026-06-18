// defines.vh -- SoC-wide constants: bus widths and the memory map.
// The single place the memory map is defined.
`ifndef DEFINES_VH
`define DEFINES_VH

// ---- bus ------------------------------------------------------------------
// ADDR_W and DATA_W are the RV32I word: the modules declare their ports with
// them, but the byte-lane logic assumes 32, so they are not a knob.
`define ADDR_W   32            // byte address
`define DATA_W   32
`define WMASK_W  4             // one write enable per byte lane
`define LEDS_W   8

// ---- RAM ------------------------------------------------------------------
// Default depth of the on-chip RAM in words (6 KB); the SOC parameter
// RAM_WORDS overrides it.
`define RAM_WORDS 1536

// ---- clock ----------------------------------------------------------------
`define CLK_HZ    200000000    // Genesys 2 system clock

// ---- memory map (byte addresses) -----------------------------------------
// A region is selected by one address bit: its base has exactly that bit set.
//   RAM       : no region bit set
//   IO        : bit 22 set
`define RAM_BASE       32'h00000000
`define IO_BASE        32'h00400000

// ---- IO registers (byte offsets from IO_BASE, one address bit each) ------
`define IO_LEDS        32'h00000004   // write: LED register

`endif
