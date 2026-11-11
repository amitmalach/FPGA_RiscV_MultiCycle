# Design notes

These notes collect every question I had while building this design, each with the answer I
found, so that the next student working on it can look here first instead of losing time on the
same questions. Entries are grouped by the file they explain; the final report cites them by
title.

Sections: [SOC](#soc-rtlsocv), [IOBus](#iobus-rtliobusv), [Processor](#processor-rtlprocessorv),
[Decoder](#decoder-rtldecoderv), [ALU](#alu-rtlaluv), [Control](#control-rtlcontrolv),
[RegisterFile](#registerfile-rtlregisterfilev), [SPIFlash](#spiflash-rtlspiflashv),
[Clockworks](#clockworks-rtlclockworksv), [UartTx](#uarttx-rtluarttxv),
[Memory](#memory-rtlmemoryv), [Firmware build](#firmware-build-fw),
[Board flash writes](#board-flash-writes-vivadoboard_flashtcl).

Pitfalls: ten entries end in a **Pitfall**, a trap that cost time once: its symptom, its cause
and how it is handled now.

1. "UART port names and the pin-direction trap" (SOC)
2. "Bare file name in $readmemh" (Memory)
3. "Explicit initial values on div and sclk (simulation hang)" (SPIFlash)
4. "SRL versus SRA: both shift arms are signed" (ALU)
5. "Flash boot loses its first fetch" (SOC)
6. "Reset lands in WAIT_DATA, not FETCH_INSTR" (Control)
7. "The worst path ends in the register-file write" (Processor)
8. "Writing the flash clears the Quad Enable bit" (Board flash writes)
9. "No stack guard: the stack can run into the program" (Firmware build)
10. "bram.ld line by line, the /DISCARD/ workaround" (Firmware build): debug data loaded into
    the RAM

## SOC (`rtl/SOC.v`)

### UART port names and the pin-direction trap

**Question:** Why does the FPGA transmit on a port called `uart_rx_out`, and what goes wrong if
the two UART pins are swapped?

*Where:* `rtl/SOC.v`, `constraints/Genesys-2-Master.xdc`, `uart_tx_in`, `uart_rx_out`

The names are Digilent's and mix two points of view: TX and RX are the PC's, `_in` and `_out`
the FPGA's. A UART's TXD is always an output and its RXD an input:

| Port | FPGA pin | At the FPGA | On the board | Use here |
|---|---|---|---|---|
| `uart_tx_in` | Y20 | input | driven by the FT232RQ's TXD (pin 30) through buffer IC25D | none: no receiver |
| `uart_rx_out` | Y23 | output | to the FT232RQ's RXD (pin 2) | `UartTx.tx` |

**Pitfall:** reading `_in` as "into the PC" swaps both pins: no byte reaches the PC and the
bridge's receive LED (LD12) stays dark. Handled: `sim/bench.v` decodes the `uart_rx_out` pin as
a receiver does, so a swap in `rtl/SOC.v` fails in simulation (one in the XDC cannot: the bench
binds ports by name).

### Processor bus has no notion of RAM versus device

**Question:** What does the core see of the system, and where is it decided whether an access
goes to the RAM, an IO register or the flash?

*Where:* `rtl/SOC.v`, `rtl/Processor.v`, `rtl/IOBus.v`

| Signal | Width, direction at the core | Meaning |
|---|---|---|
| `mem_addr` | 32, out | byte address: `pc` in `FETCH_INSTR` and `WAIT_INSTR`, `loadstore_addr` otherwise |
| `mem_rstrb` | 1, out | one-cycle read request, in `FETCH_INSTR` and `LOAD` |
| `mem_rdata` | 32, in | the word read, valid the cycle after `mem_rstrb` unless `mem_rbusy` is high |
| `mem_wdata` | 32, out | store data, `rs2` copied into every byte lane it can land in |
| `mem_wmask` | 4, out | byte-lane write enables, non-zero only in `STORE` |
| `mem_rbusy` | 1, in | a read is still in flight: keep waiting |

`IOBus` decides, never the core. `mem_addr` and `mem_wdata` reach the RAM and `IOBus` alike;
`IOBus` turns the strobes into `ram_rstrb`, `ram_wmask`, `spiflash_rstrb` or an IO write, picks
`mem_rdata`, and passes `spiflash_rbusy` on as `mem_rbusy`.

### Flash memory map and boot address

**Question:** Where in the 32 MB flash does flash-boot code live, why there, and how does a
bitstream choose flash boot or BRAM boot?

*Where:* `rtl/defines.vh` (`SPIFLASH_BASE`, `SPIFLASH_DATA_OFFSET`, `SPIFLASH_CODE_OFFSET`,
`BOOT_ADDR_FLASH`, `BOOT_ADDR_BRAM`), `rtl/SOC.v` (`BOOT_ADDR`), `fw/memory.ld`

Flash offset `o` is CPU address `SPIFLASH_BASE + o`, `0x0100_0000 + o`. Each region starts on a
64 KB boundary, the flash's erase sector:

| Flash offset | Contents | Why there |
|---|---|---|
| `0x000000` to `0xAE9E0F` | room for a power-on bitstream, 10.9 MB | configuration reads offset 0; an uncompressed bitstream for this FPGA, `SOC.bit` included, is 11 443 728 bytes |
| `0xC00000` to `0xC9C3E7` | ST_NICCC's scene data, 625 KB | `SPIFLASH_DATA_OFFSET`; `fw/tests/check_memory_map.sh` holds `fw/ST_NICCC.c`'s `ADDR_OFFSET` equal to it, and `vivado/board_flash.tcl` writes nothing below it |
| `0xD00000` to `0xFFFFFF` | flash-boot code, 3 MB, from `BOOT_ADDR_FLASH = 0x01D0_0000` | a sector boundary clear of both: 2136 KB past the bitstream, 399 KB past the scene data |
| above `0xFFFFFF` | unreachable | "Why the core reaches only the lower 16 MB of the flash" |

The boot mode is `SOC`'s `BOOT_ADDR`, the core's reset vector: `BOOT_ADDR_FLASH` by default
(`make bitstream`), `BOOT_ADDR_BRAM`, 0, in `sim/bench.v` and in `vivado/board_bitstream.tcl`
(`-generic BOOT_ADDR=32'h00000000`). In BRAM boot the program is `rtl/firmware.hex`: 6 KB at most.

### Genesys 2 differential clock input

**Question:** How does the board's 200 MHz clock get into the design, and why through `IBUFDS`
and `BUFG`?

*Where:* `rtl/SOC.v`, `sysclk_buffer`, `sysclk_bufg`, `clk`; `constraints/Genesys-2-Master.xdc`

The oscillator drives only an LVDS pair, `sysclk_p` and `sysclk_n` on AD12 and AD11 (XDC:
`IOSTANDARD LVDS`, `create_clock -period 5.000`). `IBUFDS` (`sysclk_buffer`) turns the pair into
one signal; `BUFG` (`sysclk_bufg`) puts it on a global clock network, which reaches every
flip-flop with low skew. Its output, `clk`, is the design's only clock.

### SPI flash CCLK access through STARTUPE2

**Question:** Why does the flash clock leave the FPGA through `STARTUPE2` instead of an
ordinary output port, and how is that primitive wired?

*Where:* `rtl/SOC.v`, `spiflash_cclk_access` (the `STARTUPE2` instance), `spiflash_clk`, `eos`

The flash is the configuration flash. Its chip select and data pins are multi-function (UG470),
released to the design after configuration, so they are ordinary ports. CCLK, B10, is
dedicated: user logic reaches it only through `STARTUPE2`.

| `STARTUPE2` port | Tied to | Meaning |
|---|---|---|
| `USRCCLKO` | `spiflash_clk` | driven onto CCLK once configuration has ended |
| `USRCCLKTS` | 0 | keep driving CCLK, which is high-impedance after configuration otherwise |
| `EOS` | `eos` | end of startup; `IOBus` passes a flash read on only once it is high |
| `USRDONEO`, `USRDONETS`, `KEYCLEARB` | 1 | DONE stays configuration's; the key is not cleared |
| the rest | 0 or open | unused |

In Vivado's simulation model CCLK stays high after end of startup until `USRCCLKO` has risen
twice, so the first transaction loses two clock edges.

### Flash boot loses its first fetch

**Question:** Why does the flash-boot bitstream print nothing straight after it is loaded,
until the CPU RESET button is pressed?

*Where:* `rtl/SOC.v` (`eos`), `rtl/IOBus.v` (`spiflash_rstrb`), `rtl/SPIFlash.v`,
`fw/start_spiflash.S`

Most likely the core's first flash fetch is lost: `lui gp,0x400`, which sets `gp` to `IO_BASE`;
without it the UART writes land in the RAM. Two things can lose it: the first transaction misses
CCLK edges ("SPI flash CCLK access through STARTUPE2"), and `IOBus` drops a read made before end
of startup ("Flash read strobe gated by end-of-startup, 22-bit word address"). ST_NICCC in BRAM
boot, whose first flash access is a data read, draws a wrong first frame for the same reason.

**Pitfall:** after a JTAG load the UART stays silent and the LEDs dark until one press of CPU
RESET. Handled on the board only: press it once after each load. A fix tried and not kept:
`SPIFlash` makes one throwaway read when `eos` rises and holds an earlier request busy.

## IOBus (`rtl/IOBus.v`)

### Address decode: one bit per region, one-hot IO registers, why bit 24

**Question:** How does `IOBus` tell from an address whether it is RAM, an IO register or the
flash, and why is bit 24 the flash bit?

*Where:* `rtl/IOBus.v` (`is_spiflash`, `is_io`, `is_ram`), `rtl/defines.vh`

Each region base has one bit set, and the decode ANDs the address with it: no comparator.

| Select | Condition | Region |
|---|---|---|
| `is_spiflash` | bit 24 set | flash, `0x0100_0000` to `0x01FF_FFFF` |
| `is_io` | bit 22 set, bit 24 clear | IO registers, `IO_BASE = 0x0040_0000` |
| `is_ram` | neither | RAM, from 0 |

Each IO register owns one address bit too:

| Register | Offset | Address bit | Access |
|---|---|---|---|
| `IO_LEDS` | `0x04` | 2 | write |
| `IO_UART_DAT` | `0x08` | 3 | write |
| `IO_UART_CNTL` | `0x10` | 4 | read |

Other addresses alias: `0x0080_0000` is RAM, and a store to `IO_BASE + 0x0C` writes the LEDs and
sends a byte. The next free IO bit is 5, offset `0x20`. Why bit 24: "Why the core reaches only
the lower 16 MB of the flash".

### RAM strobes masked outside RAM space

**Question:** Why does the RAM take its read strobe and write mask from `IOBus` instead of from
the core?

*Where:* `rtl/IOBus.v` (`ram_rstrb`, `ram_wmask`), `rtl/Memory.v`

The RAM sees every address, so a store to an IO register would also write the RAM. `IOBus` ANDs
both with `is_ram`: `ram_rstrb = is_ram & mem_rstrb`, `ram_wmask = {4{is_ram}} & mem_wmask`.

### LED register: reset not gated by the clock enable

**Question:** When does the LED register change, and why does its reset ignore `clk_enable`
while its write does not?

*Where:* `rtl/IOBus.v`, `leds`, `io_write`

`leds` loads `mem_wdata[7:0]` on `io_write` (`clk_enable & is_io & |mem_wmask`) with address bit
2 set. Reset clears it at the next edge whatever `clk_enable` is, so it acts at once. The write
is gated because under a gearbox (`SLOW > 0`) the core holds a store for `2^SLOW` cycles, and it
must act once. A load from `IO_LEDS` returns 0.

### UART send pulse and the status word (bit 9 convention)

**Question:** How does a store send a byte, and how does software find out that the
transmitter is busy?

*Where:* `rtl/IOBus.v` (`uart_valid`, `uart_status`, `io_rdata`), `rtl/defines.vh`
(`UART_BUSY_BIT`), `fw/putchar.S`

A store to `IO_UART_DAT` raises `uart_valid` for one clock with `uart_data = mem_wdata[7:0]`.
`UartTx` ignores `valid` while busy, so a byte stored then is lost. A load from `IO_UART_CNTL`
returns `!uart_ready` at bit `UART_BUSY_BIT`, 9, zeros elsewhere; other IO addresses read 0.
`fw/putchar.S` copies bit 9 (`li t0, 1<<9`), held equal by lint rule 7: it stores the byte, then
loops while busy, so the next store finds the transmitter idle.

### Flash read strobe gated by end-of-startup, 22-bit word address

**Question:** When does `IOBus` start a flash transaction, what becomes of a flash read before
end of startup, and which address does the controller get?

*Where:* `rtl/IOBus.v` (`spiflash_rstrb`, `spiflash_word_addr`), `rtl/SOC.v` (`eos`)

`spiflash_rstrb = clk_enable & is_spiflash & mem_rstrb & spiflash_eos`. The `eos` term keeps the
controller off CCLK while configuration owns it. A read before `eos` is dropped: `mem_rbusy`
stays low and the core takes the receive register's stale contents ("Flash boot loses its first
fetch"). The address is `mem_addr[23:2]`, the word index inside flash space; the controller
reads whole aligned words.

### Only flash reads stall the core, read mux

**Question:** Which device can make the core wait, and how is the word the core reads chosen?

*Where:* `rtl/IOBus.v` (`mem_rbusy`, `mem_rdata`, `io_rdata`)

The RAM answers the cycle after its strobe and the IO status at once, which is when the core
samples, so `mem_rbusy = spiflash_rbusy`. The flash raises it (`rbusy = !spi_cs_n`) from the
edge after its strobe until the last data bit is in. The read mux picks by region: `ram_rdata`,
`spiflash_rdata` (already little-endian) or `io_rdata`. It is combinational on `mem_addr`, which
the core holds through its wait states.

## Processor (`rtl/Processor.v`)

### Why the reset vector is a parameter, and why a jump at address 0 is not enough

**Question:** How does the same hardware boot from the RAM or from the flash, and why is the
start address a hardware parameter rather than a jump stored at address 0?

*Where:* `rtl/Processor.v`, `RESET_PC`, `pc`; `rtl/SOC.v`, `BOOT_ADDR`

`RESET_PC`, the value of `pc` at power-on and on every reset, is the only difference between the
boot modes; `SOC` sets it from `BOOT_ADDR` ("Flash memory map and boot address"). A jump stored
at RAM address 0 works only until the program overwrites it, which flash boot does at once:
`fw/start_spiflash.S` copies `.data` and the fastcode to the start of the RAM. A later reset
would execute that data. A vector held in hardware does not depend on the RAM.

### Why jalr_target is a named wire

**Question:** Why does the JALR target get its own wire instead of being written inline in the
next-pc expression?

*Where:* `rtl/Processor.v`, `jalr_target`, `next_pc`

JALR clears bit 0 of `rs1 + imm_i`. Verilog-2001 cannot part-select an expression,
`{(rs1 + imm_i)[31:1], 1'b0}`, only a named wire, `{jalr_target[31:1], 1'b0}`.

### Store data is broadcast to every lane, the mask selects

**Question:** How does a byte or halfword store reach the right byte of a 32-bit memory word,
and leave the other bytes as they were?

*Where:* `rtl/Processor.v`, `mem_wdata`, `store_wmask`, `loadstore_addr`; `rtl/Memory.v`

`mem_wdata` copies `rs2` into every lane the store could target; the mask, `store_wmask` in
`STORE` and zero otherwise, picks the lanes written:

| Store | `loadstore_addr[1:0]` | `store_wmask` | Lanes written |
|---|---|---|---|
| SB | 00, 01, 10, 11 | 0001, 0010, 0100, 1000 | that lane gets `rs2[7:0]` |
| SH | 00, 10 | 0011, 1100 | lanes 1:0 or 3:2 get `rs2[15:0]` |
| SW | 00 | 1111 | all four get `rs2` |

`Memory` addresses the word by `mem_addr[31:2]` and writes lane `k` only where `mem_wmask[k]` is
set, so the other bytes keep their value. A read returns the whole word; the core selects a
loaded byte or halfword itself. Misaligned stores write wrong lanes; compiled code keeps data
aligned.

### The worst path ends in the register-file write

**Question:** Which path limits the clock, and what would shorten it?

*Where:* `rtl/Processor.v`, `loadstore_addr`, `load_data`; `rtl/IOBus.v`; `docs/baseline.md`

The worst setup path runs from `cpu/instr_reg[3]`, an opcode bit, through the immediate select,
the unregistered `rs1 + imm` adder up to bit 24, `IOBus`'s read mux and the load lane select, to
the register file's LUT RAM: 15 levels, 4.312 ns, 0.219 ns of slack against 5 ns. Vivado times
it as one cycle, although `instr` and `rs1` settle cycles earlier (report, "Implementation
results"). Registering the address, or its region bit, in `EXECUTE` would take the adder off the
path at no cycle cost, since `LOAD` and `STORE` follow `EXECUTE`.

**Pitfall:** one more term in the address decode or the load lanes can miss the 5 ns. Handled:
`make bitstream` fails when timing fails, setup (WNS) or hold (WHS), and a comment at
`loadstore_addr` marks the path.

## Decoder (`rtl/Decoder.v`)

### ADD versus SUB: funct7[5] alone is not enough

**Question:** How does the decoder tell ADD from SUB and SRL from SRA, given that the immediate
forms have no `funct7` field?

*Where:* `rtl/Decoder.v`, `alu_sub`, `alu_sra`

`funct7[5]` (`instr[30]`) picks SUB and SRA in the register form; in the immediate form it is
immediate bit 10. There is no SUBI, so `alu_sub = funct7[5] & instr[5]`, `instr[5]` being 1 only
in the register opcode; otherwise `addi a0, a0, -1` would subtract. SRAI encodes 0100000 in
`imm[11:5]` as SRA does in `funct7`, so `alu_sra = funct7[5]` serves both forms.

## ALU (`rtl/ALU.v`)

### SRL versus SRA: both shift arms are signed

**Question:** Why does the right shift write `$signed(in1)` in both arms, even for the logical
shift?

*Where:* `rtl/ALU.v`, `result`, `sra`

`>>>` fills with the sign bit only if its operand is signed, and a Verilog conditional is
unsigned if either arm is, a type pushed down into the operands. With an unsigned SRL arm, SRA
filled with zeros. `>>` fills with zeros whatever the type, so signing both arms leaves SRL as is.

**Pitfall:** a golden trace recorded with the bug agreed with it; only the comparison with the C
program run natively (`docs/baseline.md`) showed it. Handled: the trace was recaptured, and
`sim/ALUBench.v` checks the four right shifts on negative operands.

### Branch comparator default arm

**Question:** Why does the branch comparator's `case` have a `default` arm when no branch uses
the two missing `funct3` values?

*Where:* `rtl/ALU.v`, `take_branch`

Only six of the eight `funct3` values are branches. In `always @(*)`, a value that left
`take_branch` unassigned would make synthesis infer a latch; `default: take_branch = 1'b0`
assigns it on every path. The `result` case needs none: its eight arms cover every value.

## Control (`rtl/Control.v`)

### Why one instruction takes several cycles

**Question:** Why does one instruction take four to six clock cycles, and what does each state
do?

*Where:* `rtl/Control.v`, `state`

The RAM and the register file read synchronously, and each read needs a state.

| State | Bus | On the edge that leaves it | Next |
|---|---|---|---|
| `FETCH_INSTR` | `pc`, `mem_rstrb` | the memory reads the word | `WAIT_INSTR` |
| `WAIT_INSTR` | `pc` | `latch_instr` | `FETCH_REGS`, once `mem_rbusy` is low |
| `FETCH_REGS` | none | `read_regs`: `rs1`, `rs2` latched | `EXECUTE` |
| `EXECUTE` | none | `update_pc` (not SYSTEM); `write_rd` unless load, store or branch | `LOAD`, `STORE` or `FETCH_INSTR` |
| `LOAD` | `loadstore_addr`, `mem_rstrb` | the memory reads the word | `WAIT_DATA` |
| `WAIT_DATA` | `loadstore_addr` | `write_rd`: `rd` takes `load_data` | `FETCH_INSTR`, once `mem_rbusy` is low |
| `STORE` | `loadstore_addr`, `mem_wdata`, `mem_wmask` | the memory or IO register is written | `FETCH_INSTR` |

From the RAM a store takes 5 cycles, a load 6, any other instruction 4.

### Power-on state matches the reset state

**Question:** Why do `state`, `pc` and `instr` declare an initial value, and why that value?

*Where:* `rtl/Control.v`, `state`; `rtl/Processor.v`, `pc`, `instr`

Configuration loads each flip-flop with its initial value, so declaring the reset values
(`WAIT_DATA`, `RESET_PC`, a NOP) makes the core start as after a reset, with no press. The
register file needs none: an instruction is fetched before any register is read.

### Reset lands in WAIT_DATA, not FETCH_INSTR

**Question:** Why does reset put the FSM in `WAIT_DATA`, a load's state, instead of
`FETCH_INSTR`?

*Where:* `rtl/Control.v`, `state`, `mem_rstrb`; `rtl/SPIFlash.v`

`mem_rstrb` is not gated by reset. In `FETCH_INSTR` it would stay high for the whole press,
millions of cycles, and in flash boot `SPIFlash`, which has no reset, would restart every cycle
with chip select low: a command the flash never finishes. `WAIT_DATA` raises no strobe, lets an
interrupted transaction finish, then goes to `FETCH_INSTR`. Its one `write_rd` is harmless: the
NOP writes x0.

**Pitfall:** with reset into `FETCH_INSTR`, BRAM boot works but in flash boot the first fetch
after a reset press goes wrong. Handled: `rtl/Control.v` resets into `WAIT_DATA`.

### Synchronous reset and the clock enable

**Question:** How can the reset input be asynchronous while the resets it drives are
synchronous, and how do `reset_n` and `clk_enable` act on the core's registers?

*Where:* `rtl/Clockworks.v`, `reset_n`; `rtl/Control.v`, `run`

The input, the CPU RESET button, reaches `reset_n` with no synchroniser or debounce, so it can
change at any moment. The resets are synchronous: `pc`, `instr`, `state`, the LED register and
`UartTx` test `reset_n` only at a clock edge, not gated by `clk_enable`. A press near an edge can
reach one register a cycle before another; a two-flip-flop synchroniser would prevent that, and
there is none.

- `Control` gates its edge strobes, `latch_instr`, `read_regs`, `update_pc` and `write_rd`,
  with `run = clk_enable & reset_n`: the datapath and the register file hold while `clk_enable`
  is low and write nothing during reset.
- `mem_rstrb`, `fetching` and `storing` are plain decodes; `Memory` and `IOBus` gate them.
- `write_rd` is high only in `EXECUTE` and in `WAIT_DATA` once `mem_rbusy` is low: one write
  per instruction at most.

### Instruction fetch stalls on mem_rbusy

**Question:** How does the core wait for an instruction from the flash, which takes far longer
than the RAM's one cycle?

*Where:* `rtl/Control.v`, `WAIT_INSTR`, `latch_instr`, `fetching`

`WAIT_INSTR` holds until `mem_rbusy` is low. From the RAM it is low at once: a fetch takes two
cycles. The flash raises it on the strobe's edge, so it is already high on the first cycle and
no unfinished word is latched. `fetching` keeps `mem_addr` at `pc`, so `IOBus` selects the
flash's data until the word is taken.

### Load stalls on mem_rbusy

**Question:** How does a load from the flash wait for its data, and why is `write_rd` gated by
`mem_rbusy` as well as the state?

*Where:* `rtl/Control.v`, `WAIT_DATA`, `write_rd`

`WAIT_DATA` holds `mem_addr` at `loadstore_addr` until `mem_rbusy` is low. Without the gate,
`rd` would be written every stalled cycle with the half-filled shift register; the last write
would be right, but the gate makes it one write, of valid data.

### STORE needs no wait state

**Question:** Why does the core wait a cycle after every read from the RAM, but a store needs
no wait state?

*Where:* `rtl/Control.v`, `STORE`; `rtl/Memory.v`

The RAM's read is registered, which lets Vivado map it onto block RAM: the word appears the
cycle after `mem_rstrb`, hence `WAIT_INSTR` and `WAIT_DATA`. A write lands on the edge that
ends `STORE`, in the RAM, the LED register or the UART, and returns nothing, so `STORE` goes
straight to `FETCH_INSTR`. A store to flash space does nothing.

### EBREAK and ECALL halt the core

**Question:** What does the core do when it executes EBREAK or ECALL?

*Where:* `rtl/Control.v`, `update_pc`, `is_system`

`update_pc` excludes SYSTEM instructions, so `pc` stays and the core fetches the same
instruction forever: halted in effect, with no trap; `sim/bench.v` ends a run on an LED value or
a cycle limit. Both start-up files end in `ebreak`, reached if `main` returns. CSR instructions
halt the same way, so firmware cannot read `rdcycle`: count cycles in simulation (the golden
trace's `END` line) or timestamp the UART output on the PC.

## RegisterFile (`rtl/RegisterFile.v`)

### x0 reads as zero explicitly

**Question:** How does x0 always read as zero?

*Where:* `rtl/RegisterFile.v`, `regs`, `rd_id`

A write to x0 is dropped, and a read of index 0 returns 0 instead of `regs[0]`, which has no
reset or initial value: X in simulation, and unknown on the FPGA.

## SPIFlash (`rtl/SPIFlash.v`)

### Purpose and the SPI Mode 0 protocol

**Question:** How does the controller read a word from the flash, and what does SPI mode 0 ask
of it?

*Where:* `rtl/SPIFlash.v`, `spi_clk`, `spi_cs_n`, `spi_mosi`, `spi_miso`

Lower `spi_cs_n`, send `03h` and a 24-bit byte address MSB first, then clock in four bytes and
raise chip select: one word per transaction, no burst, no cache. In mode 0 the clock idles low;
the controller changes `spi_mosi` as `spi_clk` falls and samples `spi_miso` as it rises.

### Origin of the module

**Question:** What comes from the upstream controller, and what is new here?

*Where:* `rtl/SPIFlash.v`; upstream, `spi_flash.v` (`SPI_FLASH_READ`) in Bruno Levy's learn-fpga

The shift registers, bit counters, `rbusy = !spi_cs_n` and byte swap are upstream's. New: the
SPI clock is the system clock divided by 6 with edge pulses (upstream: the system clock,
inverted), and the word address is 22 bits, 16 MB (upstream: 20 bits, 4 MB).

### Why the SPI clock is divided by 6

**Question:** Why is the SPI clock a sixth of the system clock, and how is it made?

*Where:* `rtl/SPIFlash.v`, `div`, `sclk`

The `03h` Read allows 50 MHz, a quarter of 200 MHz. `div` counts 0 to 2 and `sclk` flips at each
wrap: 33.3 MHz. Flipping every n cycles gives only even divisors, and 4 would be exactly 50 MHz,
so 6 is the smallest with margin.

### Edge pulses instead of levels

**Question:** What are `sclk_rise` and `sclk_fall`, and why does the logic use them rather than
`sclk`'s level?

*Where:* `rtl/SPIFlash.v`, `sclk_rise`, `sclk_fall`

`sclk_rise` is `div == 2 && !sclk` and `sclk_fall` is `div == 2 && sclk`: each is high for the
one cycle at whose end `sclk` flips. `cmd_addr` shifts on `sclk_fall` and `rcv_data` samples on
`sclk_rise`, one bit per SPI edge. Testing the level would act on all three cycles of a phase.

### Divider held in reset while idle (short first pulse)

**Question:** Why are `div` and `sclk` held at 0 while chip select is high?

*Where:* `rtl/SPIFlash.v`, `div`, `sclk`, `spi_cs_n`

So that every transaction starts at the same phase and its first `spi_clk` pulse is full length.
Keyed off `spi_cs_n`, the hold lasts through the edge that lowers chip select, so the first
rising edge comes three cycles later, with the opcode's first bit already on `spi_mosi`.

### Explicit initial values on div and sclk (simulation hang)

**Question:** Why do `div`, `sclk` and `spi_cs_n` declare initial values, when nothing resets
them?

*Where:* `rtl/SPIFlash.v`, `div`, `sclk`, `spi_cs_n`

In simulation an uninitialised register is `x`, and `x + 1` stays `x`: the divider makes no
edge, the bit counters never reach zero, chip select never rises, and `rbusy` stays high. `div`
and `sclk` declare 0; `spi_cs_n` declares 1, which alone makes the idle branch clear them at the
first edge and keeps the flash deselected from the start. `cmd_addr` and `snd_bitcount` are
loaded by the first `rstrb`, `rcv_bitcount` by the last command bit, and while they are `x` no
branch that tests them is taken.

**Pitfall:** the testbench hangs on the first flash read while the board works, since
configuration gives every flip-flop a value. Handled: these initial values; the core's
registers declare theirs too. A new register without a reset needs one.

### spi_clk forced low while idle

**Question:** Why is `spi_clk` forced to 0 while chip select is high, when `sclk` is held at 0
then anyway?

*Where:* `rtl/SPIFlash.v`, `spi_clk`

The divider sees chip select high one edge late, so `sclk` stays high a cycle after chip select
rises. `spi_clk = spi_cs_n ? 0 : sclk` drops the clock with chip select, to mode 0's idle level.

### Command packing and the 22-bit word address

**Question:** What does `cmd_addr` hold, and why is `word_address` 22 bits wide when the chip
is 32 MB?

*Where:* `rtl/SPIFlash.v`, `cmd_addr`, `word_address`; `rtl/defines.vh`, `SPIFLASH_ADDR_W`

`cmd_addr = {8'h03, word_address, 2'b00}`: the opcode, then the byte address of the word. It
shifts left once per command bit, and `spi_mosi` is its top bit. 22 bits fill the 3-byte
address: "Why the core reaches only the lower 16 MB of the flash".

### Why the core reaches only the lower 16 MB of the flash

**Question:** The S25FL256S holds 32 MB. Why does the core see only the lower 16 MB, and why
is that enough?

*Where:* `rtl/SPIFlash.v` (`cmd_addr`, `word_address`), `rtl/IOBus.v` (`is_spiflash`,
`spiflash_word_addr`), `rtl/defines.vh` (`SPIFLASH_BASE`, `SPIFLASH_ADDR_W`)

Three limits meet at 24 address bits, 16 MB:

| Layer | Limit |
|---|---|
| The flash's command | `03h` Read takes a 3-byte address, made for chips of 16 MB or less |
| The controller | a 22-bit `word_address` and two zero bits fill that address |
| The memory map | flash space is bit 24, `SPIFLASH_BASE = 0x0100_0000`; the 24 bits below it are the offset, `SPIFLASH_ADDR_W` |

The chip's Bank Address Register supplies the missing bit: BAR[0], BA24, is address bit 24 for
every 3-byte command (BAR[7], EXTADD, would make `03h` take a 4-byte address). Both bits are
volatile and clear at power-up, and nothing writes them, so every read lands in the lower 16 MB.

That is enough, and needed: the room for a power-on bitstream (10.9 MB), the scene data at
`0xC00000` and the code window up to `0xFFFFFF` all fit ("Flash memory map and boot address").
Bit 23 as the region bit would leave 8 MB, ending inside the bitstream's room; upstream's 4 MB
would wrap `0xC00000` onto 0. The upper 16 MB stays unused.

### The transaction, cycle by cycle

**Question:** How does one read proceed, edge by edge, without a named-state machine?

*Where:* `rtl/SPIFlash.v`, `snd_bitcount`, `rcv_bitcount`, `busy`

The bit counters are the state; chip select is low until both are zero, so `rbusy` is
`!spi_cs_n`. System-clock edges, from the one that sees `rstrb`:

| Edge | What happens |
|---|---|
| 0 | `spi_cs_n` falls; `cmd_addr` loaded; `snd_bitcount` = 32 |
| 3, 9, ..., 189 | 32 rising edges: the flash samples the opcode and the address |
| 6, 12, ..., 192 | 32 falling edges: `cmd_addr` shifts; the last loads `rcv_bitcount` = 32 |
| 195, 201, ..., 381 | 32 rising edges: `spi_miso` shifts into `rcv_data` |
| 382 | `spi_cs_n` rises, `rbusy` falls, `rdata` holds the word |

The core waits 382 cycles, 1.91 µs. The data phase's falling edges move nothing here: the flash
puts out its next bit on them. Chip select rises whatever the divider's phase: raising it alone
ends a read.

### Starting a transaction is not gated by the SPI edge

**Question:** Why can `rstrb` start a transaction on any cycle, and can it interrupt one in
flight?

*Where:* `rtl/SPIFlash.v`, `rstrb`; `rtl/Control.v`, `mem_rstrb`

With the divider held at 0 while idle any cycle is a clean start, and waiting for an SPI edge
could miss the one-cycle pulse. A strobe mid-transaction would restart it, but none comes: the
core strobes only after seeing `mem_rbusy` low, after a reset too ("Reset lands in WAIT_DATA,
not FETCH_INSTR").

### Arming the receive counter on the last command bit, the trailing 1

**Question:** Why is `rcv_bitcount` loaded on the last command bit, and what are the 1s shifted
into `cmd_addr`?

*Where:* `rtl/SPIFlash.v`, `snd_bitcount`, `rcv_bitcount`, `cmd_addr`

The flash puts out its first data bit after the falling edge that ends the command, so loading
`rcv_bitcount` on that edge lets the next rising edge sample it: no gap. The 1s shifted in reach
`spi_mosi` only after the address, when the flash ignores it.

### Byte order of the received word

**Question:** In what order do the four bytes arrive, and how does `rdata` become a little-endian
word?

*Where:* `rtl/SPIFlash.v`, `rcv_data`, `rdata`

The bytes arrive lowest address first, each MSB first, into a left shift, so the first byte ends
in `rcv_data[31:24]`. `rdata` reverses the byte order, not the bits: `AA BB CC DD` at +0 to +3
arrive as `32'hAABBCCDD` and leave as `32'hDDCCBBAA`, the word the RAM returns for those bytes.

## Clockworks (`rtl/Clockworks.v`)

### What Clockworks provides

**Question:** What does `Clockworks` give the rest of the design, and what does it expect of its
inputs?

*Where:* `rtl/Clockworks.v`, `clk_enable`, `reset_n`, `SLOW`

`clk_enable`, high one cycle in `2^SLOW`, and `reset_n`, the CPU RESET button forwarded as is.
`clk` must already be single-ended; unlike upstream, it builds no PLL and no power-on reset.
`SOC` sets `SLOW` to 0, so it synthesises to no cell.

### Gearbox counter

**Question:** How does `clk_enable` pulse once every `2^SLOW` cycles, and which blocks does it
slow down?

*Where:* `rtl/Clockworks.v`, `div`, `tick`

`div` counts every cycle, and `tick`, which is `clk_enable`, is registered high after `div` was
all ones. The core, the RAM and the LED register advance only on enabled cycles. `UartTx` and
`SPIFlash` run every cycle, so baud rate and SPI clock stay right; `IOBus` gates their start
pulses with `clk_enable`. Nothing sets `SLOW` above 0, so the slowed design is untested.

## UartTx (`rtl/UartTx.v`)

### Frame format and interface

**Question:** What does the transmitter put on the line for one byte, and when does it accept
the next?

*Where:* `rtl/UartTx.v`, `valid`, `ready`, `frame`

8N1: a start bit (0), `data[0]` to `data[7]`, a stop bit (1); the line idles high. `frame` is
loaded with `{1, data, 0}` and shifts right once per bit. `valid` is read only in `IDLE`, so a
byte offered while `ready` is low is dropped.

### Cycles per bit and the counter width

**Question:** How long is one bit, and how wide is the counter that times it?

*Where:* `rtl/UartTx.v`, `CLKS_PER_BIT`, `clk_cnt`

`CLKS_PER_BIT = CLK_HZ / BAUD` = 1736, truncated from 1736.1: 0.006 % fast, well within a
receiver's tolerance. A byte takes 17,360 cycles, 86.8 µs. `clk_cnt` is `$clog2(CLKS_PER_BIT)`
bits, 11. `SOC` passes `` `CLK_HZ`` and its parameter `UART_BAUD`, `` `UART_BAUD`` by default.

### Reset state

**Question:** What does reset do to the transmitter, and how does it start when no reset comes?

*Where:* `rtl/UartTx.v`, `reset_n`, `state`

A synchronous reset puts it in `IDLE` with `ready` and `tx` high; a press mid-byte garbles that
byte. The registers declare no initial values: on the board they start at 0, which is `IDLE`,
and the first edge drives `tx` and `ready` high. In simulation they start as `x` until
`sim/bench.v`'s initial reset.

## Memory (`rtl/Memory.v`)

### RAM size and the firmware load

**Question:** How big is the RAM, and how does the program get into it?

*Where:* `rtl/Memory.v`, `ram`, `WORDS`; `rtl/defines.vh`, `RAM_WORDS`

1536 words, 6 KB, two block-RAM tiles. `$readmemh("firmware.hex", ram)` in an `initial` block
fills it: a simulator at time 0, Vivado at synthesis, into the bitstream as initial values.
`make -C fw` writes the file ("Why the ELF-to-hex conversion exists, endianness").

### Bare file name in $readmemh

**Question:** Where must `firmware.hex` be for a tool to find it?

*Where:* `rtl/Memory.v`, `vivado/create_project.tcl`, `vivado/baseline.tcl`,
`sim/run_regression.sh`, `vivado/board_bitstream.tcl`

In the working directory of the tool that reads it, not `rtl/`:

| Flow | How the image gets there |
|---|---|
| `make bitstream`, the GUI | `create_project.tcl` adds `rtl/firmware.hex` as a Memory File; Vivado copies it into each run directory |
| `make baseline` | `baseline.tcl` copies it into its output directory and runs there |
| `make smoke`, `make check-sim` | `run_regression.sh` links it into `sim/build/` and runs xsim there |
| `board_bitstream.tcl` | the image is built into the output directory, where Vivado runs |

**Pitfall:** a missing file stops nothing: xsim prints `WARNING: File firmware.hex ... cannot be
opened for reading`, iverilog an `ERROR` line, and both run with the RAM at X, so the program
never starts. Vivado run from `rtl/` leaves `.Xil/` and `clockInfo.txt` beside the sources.
Handled: each flow above, and lint rule 1 fails on such by-products.

### Simulation and hardware after a firmware change

**Question:** What must be redone after `rtl/firmware.hex` changes, in simulation and on the
board?

*Where:* `rtl/firmware.hex`, `sim/run_regression.sh`, `vivado/board_bitstream.tcl`

The regression links the current image each run; a new program gives a new trace, so an
intended change needs `make golden`. In the GUI, reset the behavioural simulation so Vivado
refreshes its copy. On the board the image is inside the bitstream: build a new BRAM-boot one
with `vivado/board_bitstream.tcl`. `make bitstream` builds flash boot, which ignores the image.

## Firmware build (`fw/`)

### The toolchain: Ubuntu's riscv64-unknown-elf packages

**Question:** Which RISC-V toolchain builds the firmware, and why that one?

*Where:* `fw/Makefile`, `CROSS`, `XILINX_RV32_ROOT`

Ubuntu 24.04's `gcc-riscv64-unknown-elf` (GCC 13.2.0) and `binutils-riscv64-unknown-elf`
(2.42), from apt; `-march=rv32i -mabi=ilp32` select RV32I and its `libgcc.a`. Another GCC may
emit other code: `make -C fw check` fails against the committed image and the golden trace's
cycle count changes. There is no C library; tinyraytracer's `libm` comes from Vivado's newlib.

### The compiler and linker flags, one by one

**Question:** What does each flag in `fw/Makefile` do, and what goes wrong without it?

*Where:* `fw/Makefile`, `ASFLAGS`, `CFLAGS`, `LDFLAGS`, `link`

| Flag | Given to | Why |
|---|---|---|
| `-march=rv32i` | gcc, as | Without it gcc emits `rv64imafdc` code, which the core cannot decode, with no error |
| `-mabi=ilp32` | gcc, as | 32-bit `int`, `long` and pointers, no float registers, as the `.S` files assume |
| `--defsym RAM_SIZE=6144` | as, ld | The stack top in `start*.S`, the RAM length in `memory.ld` |
| `-O2` | gcc | The committed image and the golden trace are `-O2`'s |
| `-fno-pic` | gcc | Code for its one link address, no global offset table |
| `-fno-stack-protector` | gcc | No canary check, which calls the absent `__stack_chk_fail` |
| `-I.` | gcc | `<stdio.h>` resolves to the stub `fw/stdio.h` |
| `-m elf32lriscv` | ld | 32-bit little-endian RISC-V ELF |
| `-nostdlib` | ld | No host start-up files or libraries: `start*.S` is the entry |
| `-mno-relax`, `--no-relax` | as, ld | No linker relaxation (below) |
| `--no-warn-rwx-segments` | ld | One writable, executable RAM is the intended layout |
| `-T bram.ld` or `-T spiflash.ld` | ld | The boot mode's layout |
| `--start-group libgcc.a [libm] --end-group` | ld | Last: "Why libgcc.a is required and why it goes last" |

Relaxation would only shorten code (mandelbrot from 3408 to 3280 bytes), since no linker script
defines `__global_pointer$`; it stays off so the image stays the committed one and `gp`, which
holds `IO_BASE`, never serves `gp`-relative data. gcc's objects still request it, so ld's
`--no-relax` is the switch that matters; `start_spiflash.S` also wraps `li gp,IO_BASE` in
`.option norelax`.

### bram.ld line by line, the /DISCARD/ workaround

**Question:** How does `bram.ld` lay a program out in the RAM, and why does it discard two
sections?

*Where:* `fw/bram.ld`, `fw/memory.ld`, `fw/start.S`

| Line | Effect |
|---|---|
| `INCLUDE memory.ld` | Region `RAM`: origin 0, length `RAM_SIZE`; ld fails if the program does not fit |
| `/DISCARD/ : { *(.riscv.attributes) *(.comment) }` | Drops two metadata sections before the catch-all can take them |
| `everything : { ... } >RAM` | One output section for code, constants, data and `.bss` alike |
| `*/start.o (.text)` | `start.S` first, at address 0, the BRAM-boot reset vector |
| `*(.*)` | Every other section of every input, in link order |

`.riscv.attributes` (the ISA an object was built for) and `.comment` (gcc's version) are not
meant to be loaded; `*(.*)` would put them between the functions. `*/start.o` only orders the
file; the `link` macro names `start.o` on the command line. As `.data` and `.bss` are in the
image, `start.S` copies nothing; the RAM has no reset, so after a reset press globals keep the
last run's values.

**Pitfall:** `*(.*)` also loads the DWARF sections of `libgcc.a`'s `muldi3.o` and `div.o`: 1084
of mandelbrot's 3408 bytes, never fetched but taken from the stack's room (`.insn` nonsense in
`objdump -D`). Not handled: `*(.debug*)` in `/DISCARD/` (a 2324-byte image) would change the
committed image. `spiflash.ld` names its input sections, so it loads none of these.

### Support objects every C program needs

**Question:** What do the support objects linked into every program provide, and why is each
one there?

*Where:* `fw/Makefile` `LIBOBJS`

| Object | Provides |
|---|---|
| `putchar.S` | `putchar`: stores the byte, then polls the busy bit; all output ends here. Lint rule 7 holds its offsets and busy bit equal to `rtl/defines.vh` |
| `print.c` | a small `printf` (`%s`, `%d`, `%c`, `%x`), `puts`, `print_string`, `print_dec`, `print_hex` |
| `wait.S` | `wait`, a delay loop of 2^17 iterations, about 5.24 ms (blinker, sieve) |
| `memcpy.c` | `memcpy`, which gcc calls for struct and array copies on its own; its `no-tree-loop-distribute-patterns` pragma stops gcc turning its loop into a `memcpy` call |
| `errno.c` | `__errno`, through which `libm` (tinyraytracer's `powf`) reports errors |

Named on the ld command line, they are linked whole whether used or not.

### The missing stdio.h and the stub header

**Question:** How do the demos that `#include <stdio.h>` compile when the toolchain has no C
library, and which headers does a new program need a stub for?

*Where:* `fw/stdio.h`, `fw/Makefile` `CFLAGS`

Ubuntu's package has none: `#include <stdio.h>` fails with `fatal error: stdio.h: No such file
or directory`.
`fw/stdio.h` declares `printf` and `putchar`, and `-I.` puts it ahead of every other include
path, newlib's included. gcc's own headers (`<stdint.h>`, `<stddef.h>`, `<stdarg.h>`) work; any
C-library header needs a stub declaring what the program calls, and an object defining it. The
demos include `<unistd.h>` and `<stdlib.h>` only under `#ifdef __linux__`, for a native build.

### Why libgcc.a is required and why it goes last

**Question:** Why must every program link `libgcc.a`, and why does it come last on the ld
command line?

*Where:* `fw/Makefile` `LIBGCC`, `link`

The core has no multiply or divide: gcc calls `__mulsi3`, `__divsi3` and the like, and the
soft-float routines, all in `libgcc.a`; without it the link fails with ``undefined reference to
`__mulsi3'``. The Makefile asks gcc for the copy matching the flags
(`-print-libgcc-file-name`) instead of a fixed path. ld takes from an archive only members that
resolve symbols already undefined, so it comes after every object; `--start-group` lets ld
rescan it with tinyraytracer's `libm`, which calls it. In flash boot, `spiflash.ld` copies
`muldi3.o` and `div.o` into the RAM with the other hot code.

### Why the ELF-to-hex conversion exists, endianness

**Question:** Why is the linked ELF converted to a hex file, and in what byte order are the
words written?

*Where:* `fw/Makefile` (the `$(HEX_OUT)` rule), `rtl/Memory.v` `$readmemh`

`$readmemh` reads hex text, not ELF. Two steps:

1. `$(OBJCOPY) -O binary --pad-to=$(RAM_SIZE) <elf> <bin>`: the bytes from address 0, in memory
   order, padded with zeros to the whole RAM.
2. `od -An -v -tx4 -w16 --endian=little <bin>`, then `sed 's/^ //; s/$/ /'` into
   `firmware.hex`: four 32-bit words a line, 384 lines, 1536 words; `-v` writes runs of zeros
   out instead of a `*`.

`$readmemh` reads a token most significant digit first, and RISC-V is little-endian, so each
word is printed from its highest byte down: mandelbrot's first instruction, `lui gp,0x400`, is
`b7 01 40 00` in memory and `004001b7` in the file. The flash build stops at `objcopy -O binary`,
the bytes as they sit in the flash, and `fw/tools/write_mcs.tcl` wraps them in an MCS file.

### No stack guard: the stack can run into the program

**Question:** Does anything keep the stack from overwriting the program?

*Where:* `fw/start.S`, `fw/start_spiflash.S` (`li sp,RAM_SIZE`), `fw/memory.ld`

No. The stack grows down from `RAM_SIZE` into the RAM that holds the program, data and, in flash
boot, the copied code. The linker's `RAM` region (`LENGTH = RAM_SIZE`) rejects only an image
larger than the RAM; nothing reserves room for the stack. mandelbrot, 852 words, leaves it 2736
bytes.

**Pitfall:** a program that has grown wanders into garbage or prints nonsense, with no warning:
the stack has overwritten it. Not handled: the linker checks only that the image fits the RAM.

## Board flash writes (`vivado/board_flash.tcl`)

### Writing the flash clears the Quad Enable bit

**Question:** Why can a flash write stop the board from booting at power-on, and how is that
prevented?

*Where:* `vivado/board_flash.tcl`, `vivado/flashregs/FlashRegs.v`, `vivado/README.md`

With `PROGRAM.SKIP_QE_BIT_ERASE` at its default, 0, Vivado's `program_hw_cfgmem` clears the
S25FL256S's non-volatile Quad Enable bit (configuration register 1, bit 1), which the factory
bitstream at offset 0 needs to read the flash four bits wide. A write with an SPIx4 `.prm` does
not set it back, and Vivado's Tcl has no command that reads the flash's registers.

**Pitfall:** after a flash write the board no longer boots at power-on: DONE off, no error flag,
the mode pins right, the flash intact. Handled: `board_flash.tcl write` sets
`PROGRAM.SKIP_QE_BIT_ERASE` to 1; `FlashRegs.v`, loaded over JTAG, prints the flash's registers
on the UART and, built with `WRITE_REGS=1`, restores the bit.
