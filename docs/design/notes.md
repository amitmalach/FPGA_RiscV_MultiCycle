# Design notes

The reasoning behind the RTL and the firmware, where the code alone does not say why. Each
entry answers one question, stated under its title, names the files and signals it concerns,
and answers in the current names. An entry describes the design as it is now and changes in
the same commit as the code it describes. Entries are grouped by the file that holds the thing
they explain. The final report cites them by title.

Sections: [SOC](#soc-rtlsocv), [IOBus](#iobus-rtliobusv),
[Processor](#processor-rtlprocessorv), [Decoder](#decoder-rtldecoderv), [ALU](#alu-rtlaluv),
[Control](#control-rtlcontrolv), [RegisterFile](#registerfile-rtlregisterfilev),
[SPIFlash](#spiflash-rtlspiflashv), [Clockworks](#clockworks-rtlclockworksv),
[UartTx](#uarttx-rtluarttxv), [Memory](#memory-rtlmemoryv), [Firmware build](#firmware-build-fw),
[Board flash writes](#board-flash-writes-docsdesignscriptsboard_flashtcl),
[program_asm](#program_asm-simasmprogram_asmv).

Pitfalls: ten entries end in a **Pitfall** paragraph, a trap that cost time once, with the
symptom as it showed and how the design or the repository now handles it:

1. "UART port names and the pin-direction trap" (SOC)
2. "Bare file name in $readmemh" (Memory)
3. "Explicit initial values on div and sclk (simulation hang)" (SPIFlash)
4. "SRL versus SRA: both shift arms are signed" (ALU)
5. "Flash boot loses its first fetch" (SOC)
6. "Reset lands in WAIT_DATA, not FETCH_INSTR" (Control)
7. "The worst path ends in the register-file write" (Processor)
8. "Writing the flash clears the Quad Enable bit" (Board flash writes)
9. "firmware_words arguments, -max_addr as a stack guard" (Firmware build): the stack runs into
   the program
10. "bram.ld line by line, the /DISCARD/ workaround" (Firmware build): debug data loaded into
    the RAM

## SOC (`rtl/SOC.v`)

The top level, wiring only: the clock buffers, `Clockworks`, the core, `IOBus`, the RAM,
`UartTx`, `SPIFlash` and `STARTUPE2`. Its port names are frozen: the constraints file and the
testbench bind to them.

### UART port names and the pin-direction trap

**Question:** Why does the FPGA transmit on a port called `uart_rx_out`, and what goes wrong if
the two UART pins are swapped?

*Where:* `rtl/SOC.v`, `constraints/Genesys-2-Master.xdc`, `uart_tx_in`, `uart_rx_out`,
`UartTx.tx`

The two names are Digilent's (`Sch=uart_tx_in`, `Sch=uart_rx_out` in the master XDC), and each
mixes two points of view. TX and RX are the PC's: Digilent's reference manual names directions
from the DTE, the PC. `_in` and `_out` are the FPGA's. Read one half at a time and both agree
with the port directions:

| Port | FPGA pin | At the FPGA | Path on the board (schematic) | Use here |
|---|---|---|---|---|
| `uart_tx_in` | Y20 | input | FT232RQ (IC16) TXD, pin 30, net `UART_TX`, buffer IC25D, net `UART_TX_IN` | none: there is no receiver, the input has no load |
| `uart_rx_out` | Y23 | output | net `UART_RX_OUT` to FT232RQ RXD, pin 2 | `UartTx.tx`, the transmitter |

What settles it without any naming convention: a UART's TXD is always an output and its RXD
always an input. The bridge drives TXD, so that net must be an FPGA input; it listens on RXD,
so that net must be an FPGA output.

The trap is reading `_in` as "into the PC", which swaps both pins. The transmitter then drives
Y20 against the output of IC25D, the bridge's RXD hears nothing, no byte reaches the PC and
its receive LED (LD12) stays dark, while everything inside the FPGA looks right. A swap made
in `rtl/SOC.v` shows in simulation, because `sim/bench.v` decodes the `uart_rx_out` pin as a
receiver would. A swap of the two `PACKAGE_PIN` lines in the XDC does not: the testbench
binds ports by name, not by pin.

The bridge presents the serial stream to the PC as a virtual COM port (`/dev/ttyUSB*` on
Linux). Receiving would need a receiver module and a readable "byte received" IO register;
`uart_tx_in` is already constrained for it.

**Pitfall:** not one byte reaches the PC and the bridge's activity LED never blinks, while the
design looks healthy in simulation: a testbench that prints what the core handed the UART,
instead of decoding the pin, cannot see the swap. Handled: the ports of `SOC` keep the board's
names and directions, and `sim/bench.v` decodes the `uart_rx_out` pin as a receiver does.

### Processor bus has no notion of RAM versus device

**Question:** What does the core see of the system, and where is it decided whether an access
goes to the RAM, an IO register or the flash?

*Where:* `rtl/SOC.v`, `rtl/Processor.v`, `rtl/IOBus.v`, `mem_addr`, `mem_rstrb`, `mem_rdata`,
`mem_wdata`, `mem_wmask`, `mem_rbusy`

The core has six bus ports and nothing that names a device:

| Signal | Width, direction at the core | Meaning |
|---|---|---|
| `mem_addr` | 32, out | byte address: `pc` in `FETCH_INSTR` and `WAIT_INSTR`, `loadstore_addr` otherwise |
| `mem_rstrb` | 1, out | one-cycle read request, in `FETCH_INSTR` and `LOAD` |
| `mem_rdata` | 32, in | the word read, valid the cycle after `mem_rstrb` unless `mem_rbusy` is high |
| `mem_wdata` | 32, out | store data, `rs2` copied into every byte lane it can land in |
| `mem_wmask` | 4, out | byte-lane write enables, non-zero only in `STORE`; the write happens on that edge |
| `mem_rbusy` | 1, in | a read is still in flight: keep waiting |

The split happens in `rtl/SOC.v` and `rtl/IOBus.v`, never in the core. `mem_addr` and
`mem_wdata` are plain wires that fan out to `IOBus` and to the RAM alike: the RAM takes them
straight from the core. What `IOBus` steers are the controls and the answer: it turns
`mem_rstrb` into `ram_rstrb` or `spiflash_rstrb`, `mem_wmask` into `ram_wmask` or an LED or
UART write, picks `mem_rdata` from the RAM, the flash or the IO status word, and passes
`spiflash_rbusy` on as `mem_rbusy`. So the core has one bus; the address and write data are
broadcast on it, and `IOBus` decides who acts on them.

### Flash memory map and boot address

**Question:** Where in the 32 MB flash does flash-boot code live, why there, and how does a
bitstream choose flash boot or BRAM boot?

*Where:* `rtl/defines.vh` (`SPIFLASH_BASE`, `SPIFLASH_CODE_OFFSET`, `BOOT_ADDR_FLASH`,
`BOOT_ADDR_BRAM`), `rtl/SOC.v` (`BOOT_ADDR`), `rtl/Processor.v` (`RESET_PC`), `fw/memory.ld`

Flash byte `o` of the chip is at CPU address `SPIFLASH_BASE + o`, `0x0100_0000 + o`. The chip
is shared, and each region follows from what was already on it:

| Flash offset | Contents | Why there |
|---|---|---|
| `0x000000` to `0xAE9E0F` | the bitstream, about 10.9 MB | configuration reads it from offset 0 at power-on; each `SOC.bit` built for this report is 11 443 728 bytes (`0xAE9E10`), since an uncompressed 7-series bitstream holds every configuration frame whatever the design |
| `0xC00000` to `0xC9C3E7` | ST_NICCC's scene data, 639 976 bytes | `ADDR_OFFSET` in `fw/ST_NICCC.c` |
| `0xD00000` to `0xFFFFFF` | flash-boot code, 3 MB; `BOOT_ADDR_FLASH = 0x01D0_0000` | a 64 KB sector boundary clear of both (the flash erases in 64 KB sectors), 2136 KB past the bitstream and 399 KB past the scene data |
| above `0xFFFFFF` | unreachable | the controller's 22-bit word address reaches 16 MB |

The boot mode is the reset vector. `SOC`'s parameter `BOOT_ADDR` becomes the core's
`RESET_PC`. It defaults to `BOOT_ADDR_FLASH`; BRAM boot sets it to `BOOT_ADDR_BRAM`, 0, at
synthesis (`docs/design/scripts/board_bitstream.tcl` passes `-generic BOOT_ADDR=32'h00000000`)
or in the instance (`sim/bench.v`, which has no flash model). In BRAM boot the program is
`rtl/firmware.hex`, read into the RAM at synthesis, so it must fit in 6 KB. No source changes.

### Genesys 2 differential clock input

**Question:** How does the board's 200 MHz clock get into the design, and why through `IBUFDS`
and `BUFG`?

*Where:* `rtl/SOC.v`, `sysclk_p`, `sysclk_n`, `clk_ibuf`, `clk`, `sysclk_buffer`,
`sysclk_bufg`, `clockworks`; `constraints/Genesys-2-Master.xdc`

The oscillator drives only an LVDS pair, on AD12 and AD11, a clock-capable pair in bank 33; the
XDC sets `IOSTANDARD LVDS` on both and `create_clock -period 5.000` on `sysclk_p`. Two Xilinx
primitives bring it in:

| Instance | Primitive | Does |
|---|---|---|
| `sysclk_buffer` | `IBUFDS` | turns the pair into one single-ended signal, `clk_ibuf` |
| `sysclk_bufg` | `BUFG` | puts it on a global clock network, which reaches every flip-flop with low skew |

Its output, `clk`, is the design's only clock. `clockworks` derives two signals from it and
the button: `clk_enable`, high one cycle in `2^SLOW` (`SLOW` is 0 in `SOC.v`, so the constant
1), and `reset_n`, the `RESET` button forwarded, active-low.

### SPI flash CCLK access through STARTUPE2

**Question:** Why does the flash clock leave the FPGA through `STARTUPE2` instead of an
ordinary output port, and how is that primitive wired?

*Where:* `rtl/SOC.v`, `spiflash_cclk_access` (the `STARTUPE2` instance), `spiflash_clk`, `eos`

The flash also holds the bitstream, so its pins are configuration pins. UG470 classes chip
select and the data pins as multi-function: configuration uses them, then releases them to the
design. So `spiflash_csn`, `spiflash_mosi` and `spiflash_miso` are ordinary ports with
`PACKAGE_PIN` lines. CCLK, B10, is dedicated: no port can claim it, and user logic reaches it
only through `STARTUPE2`, a primitive built into every 7-series device. Its port names are
Xilinx's; the instance name `spiflash_cclk_access` is this design's.

| `STARTUPE2` port | Tied to | Meaning |
|---|---|---|
| `USRCCLKO` | `spiflash_clk` | the clock driven onto CCLK once configuration has ended; `SPIFlash` holds it low while `spi_cs_n` is high |
| `USRCCLKTS` | 0 | never tri-state CCLK: CCLK is high-impedance after configuration unless told to stay driven |
| `EOS` | `eos` | end of startup; `IOBus` passes a flash read on only once it is high |
| `USRDONEO`, `USRDONETS` | 1, 1 | the DONE pin stays configuration's: the user drive is tri-stated |
| `KEYCLEARB` | 1 | do not clear the encryption key |
| `CLK`, `GSR`, `GTS`, `PACK` | 0 | unused |
| `CFGCLK`, `CFGMCLK`, `PREQ` | open | unused |

The hand-over is not immediate: in Vivado's simulation model, CCLK stays high after end of
startup until `USRCCLKO` has risen twice, so the first transaction after configuration loses
two clock edges (the report's section "CCLK and STARTUPE2", and "Flash boot loses its first
fetch" below).

### Flash boot loses its first fetch

**Question:** Why does the flash-boot bitstream print nothing straight after it is loaded,
until the CPU RESET button is pressed?

*Where:* `rtl/SOC.v` (`spiflash_cclk_access`, `eos`), `rtl/IOBus.v` (`spiflash_rstrb`),
`rtl/SPIFlash.v`, `fw/start_spiflash.S`

Most likely the core's first fetch from the flash is lost straight after configuration. That
fetch is `lui gp,0x400`, the first instruction of `fw/start_spiflash.S`, which sets `gp` to
`IO_BASE`; without it the UART writes land in the RAM instead. Two things can lose it.
`STARTUPE2` passes `USRCCLKO` to the CCLK pin only after a few edges, so the first transaction
misses clock edges and the flash misreads its command ("SPI flash CCLK access through
STARTUPE2"). And `IOBus` drops, rather than stalls, a fetch requested before end of startup
("Flash read strobe gated by end-of-startup, 22-bit word address"). ST_NICCC shows the same
loss in BRAM boot, where the first flash access is a data read: its first frame came out
wrong, while the frames after it were drawn from the right data.

**Pitfall:** with the flash-boot bitstream loaded over JTAG, no byte arrives on the UART and
the LEDs stay dark; one press of the CPU RESET button, and the demo runs from then on.
Handled on the board only: press the reset button once after each load. A candidate fix, not
kept in the repository, made the board print straight after the load: `eos` moves into
`SPIFlash`, which makes one throwaway read as soon as `eos` rises and holds a read requested
before that, busy, until it can start it. It cost about 25 LUTs and 25 flip-flops more and met
timing with 0.334 ns of slack.

## IOBus (`rtl/IOBus.v`)

Address decode, the LED register, the UART and flash handshakes, and the read multiplexer. The
addresses come from `rtl/defines.vh`.

### Address decode: one bit per region, one-hot IO registers, why bit 24

**Question:** How does `IOBus` tell from an address whether it is RAM, an IO register or the
flash, and why is bit 24 the flash bit?

*Where:* `rtl/IOBus.v` (`is_spiflash`, `is_io`, `is_ram`), `rtl/defines.vh` (`IO_BASE`,
`SPIFLASH_BASE`, `IO_LEDS`, `IO_UART_DAT`, `IO_UART_CNTL`)

Each region base has exactly one bit set, and the decode ANDs the address with it. No
comparator, no range check:

| Select | Condition | Region |
|---|---|---|
| `is_spiflash` | bit 24 set | flash, `0x0100_0000` to `0x01FF_FFFF` |
| `is_io` | bit 22 set, bit 24 clear | IO registers, `IO_BASE = 0x0040_0000` |
| `is_ram` | neither | RAM, from `0x0000_0000` |

Inside IO space each register owns one address bit too, tested alone (one-hot), so the
register on word-address bit N sits at byte offset `1 << (N + 2)`:

| Register | Offset | Address bit | Access |
|---|---|---|---|
| `IO_LEDS` | `0x04` | 2 | write |
| `IO_UART_DAT` | `0x08` | 3 | write |
| `IO_UART_CNTL` | `0x10` | 4 | read |

Only these bits are looked at, so other addresses alias: `0x0080_0000` is RAM, and a store to
`IO_BASE + 0x0C` writes the LEDs and sends a byte. The next free IO bit is bit 5, offset `0x20`.

Why bit 24: the bits below the region bit are the offset inside the flash. Bit 24 leaves 24
bits, 16 MB, exactly the three address bytes of the flash's `03h` Read command. Bit 23 would
leave an 8 MB window, which ends inside the 10.9 MB bitstream ("Flash memory map and boot
address").

### RAM strobes masked outside RAM space

**Question:** Why does the RAM take its read strobe and write mask from `IOBus` instead of from
the core?

*Where:* `rtl/IOBus.v` (`ram_rstrb`, `ram_wmask`), `rtl/SOC.v`, `rtl/Memory.v`

The RAM takes `mem_addr` and `mem_wdata` straight from the core, so it sees every access,
including those meant for IO or the flash. Without a mask, a store to an IO register would
also be a write to the RAM. `IOBus` ANDs both controls with `is_ram`:
`ram_rstrb = is_ram & mem_rstrb` and `ram_wmask = {4{is_ram}} & mem_wmask`, the replication
turning the one-bit select into a four-bit mask. Neither is gated by `clk_enable` here:
`Memory` gates its own read and write with it.

### LED register: reset not gated by the clock enable

**Question:** When does the LED register change, and why does its reset ignore `clk_enable`
while its write does not?

*Where:* `rtl/IOBus.v`, `leds` (the `SOC` port `LEDS`), `io_write`

`leds` is eight flip-flops driving `LEDS[7:0]`. It loads `mem_wdata[7:0]` on `io_write`
(`clk_enable & is_io & |mem_wmask`) with address bit 2 (`IO_LEDS`) set, and holds otherwise.
`reset_n` low clears it at the next clock edge whatever `clk_enable` is, so a reset always
takes effect at once, even with a gearbox (`SLOW > 0`). The write is gated because under a
gearbox the core holds a store's address and mask for `2^SLOW` cycles: the gate makes the
store act once, on the enabled edge, as it does on the RAM and the UART. The register has no
read-back: a load from `IO_LEDS` returns 0.

### UART send pulse and the status word (bit 9 convention)

**Question:** How does a store send a byte, and how does software find out that the
transmitter is busy?

*Where:* `rtl/IOBus.v` (`uart_valid`, `uart_data`, `uart_ready`, `uart_status`, `io_rdata`),
`rtl/defines.vh` (`UART_BUSY_BIT`), `fw/putchar.S`

Sending: `uart_valid = io_write & |(mem_addr & IO_UART_DAT)`, high for one clock when the core
stores to `IO_BASE + 0x08`, and `uart_data = mem_wdata[7:0]`. `UartTx` takes the byte and
holds `ready` low until the stop bit has gone; it ignores `valid` meanwhile, so a byte stored
while it is busy is lost.

Status: RISC-V has only loads and stores, so a status is read by loading from an address.
`io_rdata` is combinational, with no stored value behind it: when address bit 4
(`IO_UART_CNTL`) is set it is `uart_status`, which carries `!uart_ready`, busy, at bit
`UART_BUSY_BIT`, 9, and zeros elsewhere; at any other IO address it is 0. Bit 9 is a convention
between `rtl/defines.vh` and the firmware's copy (`li t0, 1<<9` in `fw/putchar.S`), held equal
by lint rule 8. `putchar` stores the byte, then loops while the busy bit reads 1, so it returns
once the byte has left and the next store finds the transmitter idle.

### Flash read strobe gated by end-of-startup, 22-bit word address

**Question:** When does `IOBus` start a flash transaction, what becomes of a flash read before
end of startup, and which address does the controller get?

*Where:* `rtl/IOBus.v` (`spiflash_rstrb`, `spiflash_word_addr`, `spiflash_eos`), `rtl/SOC.v`
(`eos`), `rtl/SPIFlash.v` (`word_address`)

`spiflash_rstrb = clk_enable & is_spiflash & mem_rstrb & spiflash_eos`: one clock, the
controller's start pulse. `eos` comes from `STARTUPE2`, and the gate keeps the controller from
clocking a CCLK that the configuration logic still owns. It drops such a read rather than
holding it: `spiflash_rbusy` stays low, the core does not stall, and it takes the stale
contents of the controller's receive register as its answer. Whether the core's first fetch
after configuration can come before `eos` is not settled; "Flash boot loses its first fetch"
discusses it.

The address: `spiflash_word_addr = mem_addr[23:2]`, 22 bits, the word index inside the 16 MB
window. Bits 31 to 24 hold the region bit and are dropped; bits 1 and 0 are dropped because
the controller reads whole aligned words and the core picks out bytes and halfwords itself.
`SPIFlash` turns the index back into a byte address ("Command packing and the 22-bit word
address").

### Only flash reads stall the core, read mux

**Question:** Which device can make the core wait, and how is the word the core reads chosen?

*Where:* `rtl/IOBus.v` (`mem_rbusy`, `mem_rdata`, `io_rdata`)

The RAM answers the cycle after its strobe (a registered block-RAM read) and the IO status is
combinational, and the core samples one cycle after its strobe anyway, so neither needs a busy
signal: `mem_rbusy = spiflash_rbusy`. The flash raises it (`rbusy = !spi_cs_n`) from the
cycle after its strobe until the last data bit is in, and the core's `WAIT_INSTR` and
`WAIT_DATA` states hold until it drops. The read multiplexer selects by the region of the
current address:

| Region | `mem_rdata` |
|---|---|
| `is_ram` | `ram_rdata` |
| `is_spiflash` | `spiflash_rdata`, the received word, byte-swapped to little-endian |
| IO | `io_rdata`: the UART status at `IO_UART_CNTL`, 0 elsewhere |

The select is combinational on `mem_addr`, which the core holds through its wait states, so
the choice stays valid until the core takes the word.

## Processor (`rtl/Processor.v`)

The core's top: it instantiates `Decoder`, `Control`, `RegisterFile` and `ALU` and keeps the
datapath glue (`pc`, `instr`, the next-pc and load/store adders, lane alignment, the write-back
mux and the bus outputs).

### Why the reset vector is a parameter, and why a jump at address 0 is not enough

**Question:** How does the same hardware boot from the RAM or from the flash, and why is the
start address a hardware parameter rather than a jump stored at address 0?

*Where:* `rtl/Processor.v`, `RESET_PC`, `pc`; `rtl/SOC.v`, `BOOT_ADDR`; `rtl/defines.vh`

`RESET_PC` is the value `pc` takes at power-on and on every reset. It is the only difference
between the two boot modes:

| Setting | Value | Who uses it |
|---|---|---|
| `Processor` default | `RAM_BASE`, 0 | none: `SOC` always passes its own `BOOT_ADDR` |
| `SOC` default, `BOOT_ADDR_FLASH` | `0x01D0_0000`, the flash code window | `make bitstream` |
| `BOOT_ADDR_BRAM` | 0 | `sim/bench.v`, the BRAM-boot bitstream of `docs/design/scripts/board_bitstream.tcl` |

A fixed vector of 0 with a jump to the flash stored at RAM address 0 would work only until the
program overwrites that word. In flash boot it does so at once: `fw/memory.ld` puts the RAM at
0, `fw/spiflash.ld` places `.data` and the fastcode first in it, and `fw/start_spiflash.S`
copies them there before `main`. A later press of the reset button would then execute that
data. A vector held in hardware lands on the entry point whatever the RAM contains.

### Why jalr_target is a named wire

**Question:** Why does the JALR target get its own wire instead of being written inline in the
next-pc expression?

*Where:* `rtl/Processor.v`, `jalr_target`, `next_pc`

JALR jumps to `rs1 + imm_i` with bit 0 cleared, as RV32I requires. Verilog-2001 cannot
part-select an expression: `{(rs1 + imm_i)[31:1], 1'b0}` is not legal, while slicing a named
wire, `{jalr_target[31:1], 1'b0}`, is. The branch and JAL targets need no such step, because
`imm_b` and `imm_j` already have bit 0 at zero.

### Store data is broadcast to every lane, the mask selects

**Question:** How does a byte or halfword store reach the right byte of a 32-bit memory word?

*Where:* `rtl/Processor.v`, `mem_wdata`, `store_wmask`, `mem_wmask`, `loadstore_addr`

The memory always takes a whole word, `mem_wdata`, plus a four-bit byte mask, `mem_wmask`, one
bit per byte lane. `mem_wdata` copies `rs2` into every lane the store could target, and the
mask alone decides which lanes are written; this is simpler than a multiplexer per access
width. `mem_wmask` is `store_wmask` in `STORE` and zero in every other state.

| Store | `loadstore_addr[1:0]` | `store_wmask` | Lanes written |
|---|---|---|---|
| SB | 00, 01, 10, 11 | 0001, 0010, 0100, 1000 | that one lane gets `rs2[7:0]` |
| SH | 00 | 0011 | lanes 1:0 get `rs2[15:0]` |
| SH | 10 | 1100 | lanes 3:2 get `rs2[15:0]` |
| SW | 00 | 1111 | all four get `rs2` |

Misaligned stores are not supported: the halfword mask ignores address bit 0 and the word mask
both low bits, so such a store writes wrong lanes. Compiled code keeps its data aligned. The IO
registers sit at word-aligned offsets, so they always receive `rs2[7:0]` on lane 0.

### The worst path ends in the register-file write

**Question:** Which path limits the clock, and what would shorten it?

*Where:* `rtl/Processor.v`, `loadstore_addr`, `load_data`, `wb_data`; `rtl/IOBus.v`, the read
mux; `rtl/RegisterFile.v`; `docs/baseline.md`

The load-store address, `rs1 + imm`, is not registered, so every cycle of a load computes it
again. The worst setup path starts at `cpu/instr_reg[3]`, an opcode bit, chooses the I- or
S-immediate, adds it to `rs1` in a carry chain as far as bit 24, the flash region's bit, uses
that bit in `IOBus`'s read mux, cuts out the loaded byte or halfword and ends at the data input
of the register file's LUT RAM: 15 levels and 4.312 ns, 70 % of it routing, against the 5 ns
of the 200 MHz clock, a slack of 0.219 ns. Vivado times it as a one-cycle path, although
`instr` and `rs1` settle cycles before any write; the report's chapter "Implementation results"
explains why that bound is pessimistic.

**Pitfall:** a small change on the load path, one more term in the address decode or in the
load lanes, can miss the 5 ns. Not handled yet: a comment at `loadstore_addr` marks it.
Register the address in `EXECUTE`, or only its region bit, and the adder leaves the path;
`LOAD` and `STORE` follow `EXECUTE`, so the register costs no cycle.

## Decoder (`rtl/Decoder.v`)

Combinational decode of `instr` into class flags, register indices, function fields and the
five immediates.

### ADD versus SUB: funct7[5] alone is not enough

**Question:** How does the decoder tell ADD from SUB and SRL from SRA, given that the immediate
forms have no `funct7` field?

*Where:* `rtl/Decoder.v`, `alu_sub`, `alu_sra`, `funct7`, `instr[5]`

ADD and SUB share `funct3` 000, SRL and SRA share 101, and in the register form `funct7[5]`
(`instr[30]`) picks the second of each pair. In the immediate form, `instr[30]` is bit 10 of
the immediate:

- There is no SUBI, so `alu_sub = funct7[5] & instr[5]`. `instr[5]` is 1 only in the
  register opcode (0110011, against 0010011 for the immediate form); without it,
  `addi a0, a0, -1`, whose immediate sets bit 30, would subtract.
- SRAI does exist, and encodes 0100000 in `imm[11:5]` just as SRA does in `funct7`, so
  `alu_sra = funct7[5]` serves both forms. The extra bit does not disturb the shift amount,
  which the ALU takes from bits 4:0 only.

## ALU (`rtl/ALU.v`)

The eight RV32I operations and the branch comparator, combinational.

### SRL versus SRA: both shift arms are signed

**Question:** Why does the right shift write `$signed(in1)` in both arms, even for the logical
shift?

*Where:* `rtl/ALU.v`, `result`, `sra`, `shamt`

`>>>` shifts arithmetically, copying the sign bit, only when its operand is signed. In
Verilog, a conditional expression is unsigned if either arm is, and that type is pushed down
into the operands. The earlier code, `sra ? ($signed(in1) >>> shamt) : (in1 >> shamt)`, had
an unsigned arm, so `>>>` filled with zeros and SRA and SRAI behaved as SRL. The fix signs both
arms: `>>` fills with zeros whatever the operand's type, so SRL is unchanged.

The bug showed in the mandelbrot output. Compared with the C program run natively
(`docs/baseline.md`), an earlier golden trace diverged at row 8, pixel 36, where `srai` of
-1544416 by 9 gave `0x007FF437` instead of `0xFFFFF437`. The golden trace was captured again
after the fix, and `sim/ALUBench.v` now checks SRA, SRAI, SRL and SRLI on negative operands.
The sign fill cost 54 LUTs, 930 to 984.

**Pitfall:** the golden trace recorded the wrong shift and agreed with it, since a trace cannot
catch a bug that was there when it was recorded; only the comparison with the C program run
natively showed it. Handled: both arms are signed, and the unit bench holds the four right
shifts to the specification.

### Branch comparator default arm

**Question:** Why does the branch comparator's `case` have a `default` arm when no branch uses
the two missing `funct3` values?

*Where:* `rtl/ALU.v`, `take_branch`

`funct3` has eight values and only six are branches (010 and 011 are not). The block is
`always @(*)`: if some input value left `take_branch` unassigned, synthesis would have to keep
its previous value and infer a latch. `default: take_branch = 1'b0` assigns it on every path,
so the block stays combinational. The `result` case needs no default, because its eight arms
cover every value of `funct3`.

## Control (`rtl/Control.v`)

The seven-state FSM that sequences each instruction and raises the strobes the datapath obeys.

### Why one instruction takes several cycles

**Question:** Why does one instruction take four to six clock cycles, and what does each state
do?

*Where:* `rtl/Control.v`, `state`, `FETCH_INSTR` to `STORE`; `rtl/Processor.v`, `mem_addr`

Two reads in each instruction are synchronous: the RAM returns a word the cycle after its
strobe (`rtl/Memory.v`), and the register file latches `rs1` and `rs2` on an edge
(`rtl/RegisterFile.v`). Each needs a state of its own.

| State | Bus (`mem_addr`, strobes) | On the edge that leaves it | Next |
|---|---|---|---|
| `FETCH_INSTR` | `pc`, `mem_rstrb` | the memory reads the word | `WAIT_INSTR` |
| `WAIT_INSTR` | `pc` | `latch_instr`: `instr` takes `mem_rdata` | `FETCH_REGS`, once `mem_rbusy` is low |
| `FETCH_REGS` | none | `read_regs`: `rs1`, `rs2` latched | `EXECUTE` |
| `EXECUTE` | none | `update_pc` (not SYSTEM); `write_rd` unless load, store or branch | `LOAD`, `STORE` or `FETCH_INSTR` |
| `LOAD` | `loadstore_addr`, `mem_rstrb` | the memory reads the word | `WAIT_DATA` |
| `WAIT_DATA` | `loadstore_addr` | `write_rd`: `rd` takes `load_data` | `FETCH_INSTR`, once `mem_rbusy` is low |
| `STORE` | `loadstore_addr`, `mem_wdata`, `mem_wmask` | the memory or IO register is written | `FETCH_INSTR` |

From the RAM, an ALU, branch, jump, LUI, AUIPC or SYSTEM instruction takes 4 cycles, a store 5
and a load 6.

### Power-on state matches the reset state

**Question:** Why do `state`, `pc` and `instr` declare an initial value, and why that value?

*Where:* `rtl/Control.v`, `state`; `rtl/Processor.v`, `pc`, `instr`

Each is declared with the value its reset branch gives it: `state = WAIT_DATA`,
`pc = RESET_PC`, `instr = NOP` (`add x0, x0, x0`). Configuration loads a 7-series flip-flop
with its initial value, so the core leaves configuration exactly as a press of the reset
button would leave it, and runs without one. `WAIT_DATA` rather than `FETCH_INSTR` keeps
`mem_rstrb` low from the first edge ("Reset lands in WAIT_DATA, not FETCH_INSTR"). The register
file has neither an initial value nor a reset, because an instruction is always fetched before
a register is read.

### Reset lands in WAIT_DATA, not FETCH_INSTR

**Question:** Why does reset put the FSM in `WAIT_DATA`, a load's state, instead of
`FETCH_INSTR`?

*Where:* `rtl/Control.v`, `state`, `mem_rstrb`; `rtl/IOBus.v`, `spiflash_rstrb`;
`rtl/SPIFlash.v`, `spi_cs_n`

`mem_rstrb` is a plain decode of `FETCH_INSTR` and `LOAD`, not gated by `reset_n`, and a press
of the button lasts millions of cycles. Resetting into `FETCH_INSTR` would therefore:

1. hold `mem_rstrb` high for the whole press, with `mem_addr = pc = RESET_PC`;
2. in flash boot, where that address is in flash space, make `IOBus` raise `spiflash_rstrb` on
   every cycle;
3. make `SPIFlash`, which has no reset, restart on every strobe: it reloads `cmd_addr` and its
   bit counter and keeps `spi_cs_n` low, so the flash sees its clock running and MOSI at 0 with
   no deselect, a command it never finishes and that leaves its command decoder out of step.

`WAIT_DATA` raises no strobe, so the flash stays deselected for the whole press. Once reset is
released, `WAIT_DATA` waits for `mem_rbusy` to be low, which also lets a flash transaction that
the press interrupted finish, and moves to `FETCH_INSTR`, which issues one clean strobe. The
cost is one cycle per reset. `WAIT_DATA` also raises `write_rd` on that cycle, which is
harmless: `instr` is the NOP, whose `rd` is x0, and `RegisterFile` never writes x0. The choice
is unconditional because it is equally correct in BRAM boot, where `mem_rbusy` is never high.

**Pitfall:** with the reset state changed to `FETCH_INSTR`, the obvious choice, nothing shows
in BRAM boot, while in flash boot the first fetch after a press of the reset button goes
wrong. Handled: `rtl/Control.v` resets into `WAIT_DATA`.

### Synchronous reset and the clock enable

**Question:** How can the reset input be asynchronous while the resets it drives are
synchronous, and how do `reset_n` and `clk_enable` act on the core's registers?

*Where:* `rtl/Clockworks.v`, `reset_n`; `rtl/Control.v`, `run`, `state`; `rtl/Processor.v`,
`pc`, `instr`; `rtl/IOBus.v`, `leds`; `rtl/UartTx.v`; `rtl/RegisterFile.v`

The two words describe different things. The *input* is asynchronous: `reset_n` is the CPU
RESET button, active-low, forwarded by `Clockworks` as it is. No synchroniser brings it into
the clock domain and no debounce filters it, so it can change at any moment between two clock
edges. The *resets* are synchronous: every register that resets tests `reset_n` only at a
rising edge of `clk`, inside `always @(posedge clk)`, and none has it in its sensitivity list,
which is what makes a reset synchronous. Three places have one: the core's `pc`, `instr` and
FSM `state`, the LED register in `IOBus`, and the transmitter in `UartTx` ("Reset state").
A press or a release that lands close to an edge can reach one of these registers a cycle
before another, or leave one metastable for a moment; a two-flip-flop synchroniser in
`Clockworks` would remove that risk, and the design has none.

- The reset is not gated by `clk_enable`, so it acts on any edge. In the core it resets `pc`,
  `instr` and `state` ("Power-on state matches the reset state").
- `Control` qualifies the four edge strobes, `latch_instr`, `read_regs`, `update_pc` and
  `write_rd`, with `run = clk_enable & reset_n`. The datapath registers and the register file
  test only those strobes, so with `clk_enable` low the core holds every register, and during
  reset no register of the register file is written.
- The plain decodes `fetching`, `mem_rstrb` and `storing` carry neither qualifier; their
  consumers, `Memory` and `IOBus`, gate them with `clk_enable` themselves.
- `write_rd` is high only in `EXECUTE`, for instructions other than load, store and branch, and
  in `WAIT_DATA` once `mem_rbusy` is low, so `rd` is written at most once per instruction.

### Instruction fetch stalls on mem_rbusy

**Question:** How does the core wait for an instruction from the flash, which takes far longer
than the RAM's one cycle?

*Where:* `rtl/Control.v`, `WAIT_INSTR`, `latch_instr`, `fetching`; `rtl/IOBus.v`, `mem_rbusy`;
`rtl/SPIFlash.v`, `rbusy`

`WAIT_INSTR` holds, leaving `instr` alone, while `mem_rbusy` is high; `latch_instr` and the
move to `FETCH_REGS` both wait for it to drop. Only the flash raises it ("Only flash reads stall
the core, read mux"). From the RAM it is low on the first cycle of `WAIT_INSTR`, so a fetch
takes two cycles. From the flash, `spi_cs_n` falls on the strobe's edge, so `mem_rbusy` is
already high on that first cycle and no unfinished word is latched. `fetching` keeps
`mem_addr` at `pc` through `WAIT_INSTR`: `IOBus` picks the read data by the address's region
every cycle, so the address must stay in flash space until the word is taken.

### Load stalls on mem_rbusy

**Question:** How does a load from the flash wait for its data, and why is `write_rd` gated by
`mem_rbusy` as well as the state?

*Where:* `rtl/Control.v`, `WAIT_DATA`, `write_rd`; `rtl/Processor.v`, `load_data`

`WAIT_DATA` stalls as `WAIT_INSTR` does, with `mem_addr` held at `loadstore_addr` (`rs1` and
`instr` do not change): a load from the RAM or the IO registers spends one cycle there, a load
from the flash a whole SPI transaction.

`write_rd` in `WAIT_DATA` is gated by `!mem_rbusy` as well. Without the gate, `rd` would be
written on every stalled cycle with the flash controller's half-filled shift register. The last
write would still be right, and the address would not move even when `rd` is `rs1`, since it
comes from the copy of `rs1` latched in `FETCH_REGS`; the gate makes it one write, of valid
data. `loadstore_addr` and `load_data`, the lane select and sign extension of `mem_rdata`, are
combinational, and the path through them to the `rd` write is the design's worst setup path.

### STORE needs no wait state

**Question:** Why does a load need a wait state and a store does not?

*Where:* `rtl/Control.v`, `STORE`, `storing`; `rtl/Processor.v`, `mem_wmask`;
`rtl/Memory.v`

In `STORE` the core drives `mem_addr = loadstore_addr`, the lane-copied `mem_wdata` and
`mem_wmask = store_wmask` for one cycle. The write lands on the edge that ends that cycle: the
RAM writes the masked bytes, the LED register latches, or the UART takes its `uart_valid`
pulse. A write returns nothing to the core, so `STORE` goes straight to `FETCH_INSTR`. A read
needs `WAIT_DATA` because the RAM's read output is registered and appears a cycle after the
strobe. A store to flash space does nothing.

### EBREAK and ECALL halt the core

**Question:** What does the core do when it executes EBREAK or ECALL?

*Where:* `rtl/Control.v`, `update_pc`, `is_system`; `fw/start.S`, `fw/start_spiflash.S`

`update_pc` is `run & (state == EXECUTE) & !is_system`, so a SYSTEM instruction leaves `pc`
where it is and the FSM fetches the same instruction again, forever. The core is halted in
effect, but its FSM keeps cycling through the four states; from the flash, each pass is a full
SPI transaction. There is no trap and nothing stops a simulation: `sim/bench.v` ends a run on
an LED value or a cycle limit. Both start-up files end in `ebreak`, reached if `main` returns.

CSR instructions share the SYSTEM opcode and halt the same way, so firmware cannot read the
cycle or instruction counters (`rdcycle`, `rdinstret`). To time code, count cycles in
simulation (the golden trace's `END` line) or timestamp the UART output on the PC
(`docs/design/scripts/uart_capture.py`).

## RegisterFile (`rtl/RegisterFile.v`)

The 32 integer registers, read synchronously on `read_en` and written on `write_en`.

### x0 reads as zero explicitly

**Question:** How does x0 always read as zero?

*Where:* `rtl/RegisterFile.v`, `regs`, `rs1`, `rs2`, `rd_id`

Two guards hold it. A write to `rd_id` 0 is dropped, so `regs[0]` is never written, and a read
of index 0 returns 0 instead of `regs[0]`. The second guard is needed because `regs` has no
reset and no initial value: in simulation `regs[0]` is X until written, which is never, and
the design does not rely on the value the array powers up with on the FPGA either.

## SPIFlash (`rtl/SPIFlash.v`)

The read controller for the board's S25FL256S flash: one request reads one 32-bit word with the
plain `03h` Read command, in SPI mode 0. Instruction fetches in flash boot and loads from the
flash region both end here.

### Purpose and the SPI Mode 0 protocol

**Question:** How does the controller read a word from the flash, and what does SPI mode 0 ask
of it?

*Where:* `rtl/SPIFlash.v`, `spi_clk`, `spi_cs_n`, `spi_mosi`, `spi_miso`

The controller drives chip select (`spi_cs_n`, active-low), the clock (`spi_clk`) and the
command line (`spi_mosi`); the flash answers on `spi_miso`. A Read is: lower chip select, send
`03h` and a 24-bit byte address, MSB first, 32 bits in all, then keep clocking while the flash
returns the bytes from that address on. The controller takes four bytes, one word, and raises
chip select. There is no burst and no cache: every word is a transaction of its own.

In mode 0 the clock idles low, the flash samples `spi_mosi` on each rising edge and changes
`spi_miso` after each falling edge. The controller does the mirror image: it changes `spi_mosi`
on the system-clock edge that lowers `spi_clk` and samples `spi_miso` on the edge that raises
it, so each bit is read half an SPI period after the other side changed it.

### Origin of the module

**Question:** What comes from the upstream controller, and what is new here?

*Where:* `rtl/SPIFlash.v`; upstream, the `SPI_FLASH_READ` variant of `spi_flash.v` in Bruno
Levy's learn-fpga

The shift registers, the two bit counters, `rbusy = !spi_cs_n` and the byte swap are those of
the upstream module's simplest variant, plain `03h` reads on one data line. The rest differs:

| | Upstream | Here |
|---|---|---|
| SPI clock | the system clock, inverted, gated by chip select | the system clock divided by 6, with edge pulses |
| Word address | 20 bits, padded with two zero bits: 4 MB | 22 bits, the whole 24-bit address: 16 MB |
| Port names | `CLK`, `CS_N`, `MOSI`, `MISO` | `spi_clk`, `spi_cs_n`, `spi_mosi`, `spi_miso` |

### Why the SPI clock is divided by 6

**Question:** Why is the SPI clock a sixth of the system clock, and how is it made?

*Where:* `rtl/SPIFlash.v`, `div`, `sclk`

The S25FL256S accepts the `03h` Read at up to 50 MHz. Fed the 200 MHz system clock directly,
as the upstream controller is on boards with slower clocks, the flash would run at four times
its limit. `div` counts 0, 1, 2 and `sclk` flips each time it wraps, so `sclk` is high for
three cycles and low for three: one SPI period is six system cycles, 30 ns, 33.3 MHz. Flipping
a clock every n cycles gives only even divisors, and 4 would be exactly 50 MHz, with no margin,
so 6 is the smallest that leaves some. A transaction of 64 SPI clocks therefore keeps the core
waiting 382 system cycles ("The transaction, cycle by cycle").

### Edge pulses instead of levels

**Question:** What are `sclk_rise` and `sclk_fall`, and why does the logic use them rather than
`sclk`'s level?

*Where:* `rtl/SPIFlash.v`, `sclk_rise`, `sclk_fall`

`sclk_rise` is `div == 2 && !sclk` and `sclk_fall` is `div == 2 && sclk`: each is high for the
one system cycle at whose end `sclk` flips, once per SPI period. The shift registers act on that
same edge, so a bit moves once per SPI clock edge: `cmd_addr` shifts as `spi_clk` falls and
`rcv_data` samples `spi_miso` as it rises. Testing the level instead would act on each of the
three cycles `sclk` spends high or low, and move three bits instead of one.

### Divider held in reset while idle (short first pulse)

**Question:** Why are `div` and `sclk` held at 0 while chip select is high?

*Where:* `rtl/SPIFlash.v`, `div`, `sclk`, `spi_cs_n`

So that every transaction starts at the same divider phase and its first `spi_clk` pulse is as
long as the other 63. A free-running divider would be at any phase when chip select falls: the
first low or high phase could last one or two cycles instead of three, or `spi_clk` could rise
in the very cycle chip select falls. The hold is keyed off `spi_cs_n`, not `rstrb`: on the edge
that lowers chip select the divider block still reads its old value, 1, so `div` and `sclk` stay
0 through that edge and count from the next one. The first rising edge of `spi_clk` comes three
cycles after chip select falls, a full low phase, with the opcode's first bit already on
`spi_mosi`.

### Explicit initial values on div and sclk (simulation hang)

**Question:** Why do `div`, `sclk` and `spi_cs_n` declare initial values, when nothing resets
them?

*Where:* `rtl/SPIFlash.v`, `div`, `sclk`, `spi_cs_n`

`SPIFlash` has no reset input. In simulation a register without an initial value starts as `x`,
and `x + 1` stays `x`: a divider stuck at `x` makes no edge, the bit counters never reach zero,
chip select never rises, and `rbusy`, the core's `mem_rbusy`, stays high, so the simulated core
hangs on its first flash read. Configuration gives every flip-flop a definite value, so the board
never shows it.

The RTL guards against it twice. `div` and `sclk` declare 0, and `spi_cs_n` declares 1, which on
its own makes the idle branch clear `div` and `sclk` at the first clock edge. In iverilog,
removing only the initial values of `div` and `sclk` still gives a working read; removing all
three hangs the first read, with `spi_cs_n` low and `div` at `x`. `spi_cs_n`'s 1 also keeps the
flash deselected and `rbusy` low from the start. The other registers need none: `cmd_addr` and
`snd_bitcount` are loaded by the first `rstrb`, `rcv_bitcount` by the last command bit, and while
they are `x` no branch that tests them is taken.

**Pitfall:** the simulation runs but the flash controller never starts its clock, and the
testbench hangs, while the same RTL works on the board. Handled: the initial values above, and
the core's registers declare their reset values as initial values. A new counter needs one
too.

### spi_clk forced low while idle

**Question:** Why is `spi_clk` forced to 0 while chip select is high, when `sclk` is held at 0
then anyway?

*Where:* `rtl/SPIFlash.v`, `spi_clk`, `sclk`, `spi_cs_n`

`spi_clk` is `spi_cs_n ? 0 : sclk`. The divider sees chip select high only on the edge after the
one that raises it, so at the end of a transaction `sclk`, high since the last data bit was
sampled, stays high one cycle after chip select rises. The mux takes `spi_clk` low on the same
edge as chip select rises, so the clock is low whenever the flash is deselected, mode 0's idle
level; without it the clock would fall one cycle later, while the flash ignores it. At the start
of a transaction the mux changes nothing, since `sclk` is already 0. The same mux cuts the last
high phase of `spi_clk` to one system cycle, after the last bit is already in.

### Command packing and the 22-bit word address

**Question:** What does `cmd_addr` hold, and why is `word_address` 22 bits wide when the chip
is 32 MB?

*Where:* `rtl/SPIFlash.v`, `cmd_addr`, `word_address`, `spi_mosi`; `rtl/defines.vh`,
`SPIFLASH_ADDR_W`

`cmd_addr` is loaded with the whole command on the `rstrb` edge and shifts left once per
command bit, so `spi_mosi`, its top bit, is always the bit on the wire:

| Bits | Value | Meaning |
|---|---|---|
| 31:24 | `8'h03` | the Read opcode |
| 23:2 | `word_address` | the word index, `mem_addr[23:2]` |
| 1:0 | `2'b00` | a word is 4 bytes, so its byte address is `word_address * 4` |

`03h` takes a three-byte address, 24 bits, 16 MB, and 22 word-address bits plus two zero bits
fill it exactly. `SPIFLASH_ADDR_W`, 24, sets both this width and the size of the flash region
in the memory map. The whole 16 MB is needed: the scene data at `0xC00000` and the code at
`0xD00000` sit above the 10.9 MB bitstream ("Flash memory map and boot address"). The upstream
controller's 20 bits reached 4 MB and would wrap such offsets onto the bitstream: `0xC00000`
modulo 4 MB is 0. The chip's upper 16 MB is out of reach ("Why the core reaches only the
lower 16 MB of the flash").

### Why the core reaches only the lower 16 MB of the flash

**Question:** The S25FL256S holds 32 MB. Why does the core see only the lower 16 MB, and what
would reaching the rest take?

*Where:* `rtl/SPIFlash.v` (`cmd_addr`, `word_address`), `rtl/IOBus.v` (`is_spiflash`,
`spiflash_word_addr`), `rtl/defines.vh` (`SPIFLASH_BASE`, `SPIFLASH_ADDR_W`)

Three limits meet at the same place, 24 address bits, which reach 2^24 bytes, 16 MB:

| Layer | Limit | Why 24 bits |
|---|---|---|
| The flash's command | `03h`, Read, followed by a 3-byte address | the classic SPI Read, made for chips of 16 MB and less ("Purpose and the SPI Mode 0 protocol") |
| The controller | `word_address`, 22 bits, then two zero bits | it fills the command's address field exactly ("Command packing and the 22-bit word address") |
| The memory map | flash space is selected by bit 24, `SPIFLASH_BASE = 0x0100_0000`, and `IOBus` passes `mem_addr[23:2]` | the bits below the region bit are the offset inside the flash ("Address decode: one bit per region, one-hot IO registers, why bit 24") |

How the chip completes a 3-byte address: the S25FL256S has twice the memory a 3-byte address
can reach, and its datasheet splits it into two banks of 16 MB. Its Bank Address Register
(BAR) supplies the missing bit: BAR[0], BA24, is address bit 24 for every 3-byte command, and
BAR[7], EXTADD, set to 1, would make the same `03h` take a 4-byte address instead. Both bits
are volatile and clear at power-up, so a 3-byte address lands in bank 0, the lower 16 MB, and
nothing in the design writes the BAR.

Why 16 MB is enough: everything the design keeps in the flash lies in the lower half. The room
for a power-on bitstream is at offset 0, where configuration always reads, the scene data at
`0xC00000`, and the code window fills the last 3 MB of the half, `0xD00000` to `0xFFFFFF`
("Flash memory map and boot address"). The upper 16 MB stays unused.

What the whole chip would take, all three layers together:

1. A 4-byte address on the wire: the 4-byte Read, `4READ 13h`, with 32 address bits, so that
   `cmd_addr` grows by a byte. That adds 8 SPI clocks, 48 system cycles, to every transaction,
   about 430 cycles of `mem_rbusy` instead of 382, and so slows every word read from the flash.
   The alternative keeps `03h` and writes BA24 with Bank Register Write, `BRWR 17h`, before a
   read in the other bank: no cost per read, but a second command and state in the controller.
2. A 25-bit offset: `SPIFLASH_ADDR_W` 25 and a 23-bit `word_address`.
3. A region bit above it: `SPIFLASH_BASE` at bit 25, `0x0200_0000`. The flash boot address
   moves with it, and the firmware's copies of the memory map follow (lint rule 8).

None of it is needed while every region fits in the lower half.

### The transaction, cycle by cycle

**Question:** How does one read proceed, edge by edge, without a named-state machine?

*Where:* `rtl/SPIFlash.v`, `snd_bitcount`, `rcv_bitcount`, `sclk_rise`, `sclk_fall`, `busy`

The two bit counters are the state: `sending` while `snd_bitcount` is non-zero, `receiving` while
`rcv_bitcount` is, and chip select low from `rstrb` until both are zero, so `rbusy` is simply
`!spi_cs_n`. Counting system-clock edges from the one that sees `rstrb` (an iverilog run of
the module gives these numbers):

| Edge | What happens |
|---|---|
| 0 | `rstrb` seen: `spi_cs_n` falls, `rbusy` rises; `cmd_addr` loaded, so `spi_mosi` shows the opcode's bit 7; `snd_bitcount` = 32 |
| 3, 9, ..., 189 | 32 rising edges of `spi_clk`: the flash samples the opcode and the address |
| 6, 12, ..., 192 | 32 falling edges while sending: `cmd_addr` shifts, `snd_bitcount` counts down; the one at 192 takes it to 0 and loads `rcv_bitcount` = 32 |
| 195, 201, ..., 381 | 32 rising edges while receiving: `spi_miso` shifts into `rcv_data` |
| 382 | `busy` is 0: `spi_cs_n` rises, `rbusy` falls, `rdata` holds the word |

`rbusy` is high for 382 cycles, 1.91 µs, 64 SPI clocks; `WAIT_INSTR` or `WAIT_DATA` takes the word
on the next edge. The falling edges of the data phase move nothing in the controller: the flash
puts its next bit out on them. Chip select rises on the first edge at which `busy` is 0,
whatever the divider's phase: waiting for an SPI edge would add latency for nothing, since
raising chip select alone ends a read.

### Starting a transaction is not gated by the SPI edge

**Question:** Why can `rstrb` start a transaction on any cycle, and can it interrupt one in
flight?

*Where:* `rtl/SPIFlash.v`, `rstrb`; `rtl/Control.v`, `mem_rstrb`, `state`

`rstrb` is a one-cycle pulse, and waiting for an SPI edge could miss it. With the divider held at
0 while idle, any cycle is a clean start anyway. The `rstrb` branch has priority over the rest,
so a strobe during a transaction would restart it, but none comes: the core raises `mem_rstrb`
only in `FETCH_INSTR` and `LOAD`, and reaches either only after `WAIT_INSTR` or `WAIT_DATA` has
seen `mem_rbusy` low, after a reset too ("Reset lands in WAIT_DATA, not FETCH_INSTR").

### Arming the receive counter on the last command bit, the trailing 1

**Question:** Why is `rcv_bitcount` loaded on the last command bit, and what are the 1s shifted
into `cmd_addr`?

*Where:* `rtl/SPIFlash.v`, `snd_bitcount`, `rcv_bitcount`, `cmd_addr`

The falling edge that takes `snd_bitcount` from 1 to 0 also loads `rcv_bitcount` with 32. The
flash puts the first data bit out after that same falling edge, so the next rising edge, three
cycles later, samples it: no gap between the command and the data. Each shift moves a 1 into the
bottom of `cmd_addr`. The 32nd shift, on that same edge, brings the first of them to `spi_mosi`,
after the last address bit was sampled, and `spi_mosi` stays 1 through the data phase, when a
Read ignores it, and while idle, when chip select is high. The flash never takes one of them as a
command bit, so their value does not matter.

### Byte order of the received word

**Question:** In what order do the four bytes arrive, and how does `rdata` become a little-endian
word?

*Where:* `rtl/SPIFlash.v`, `rcv_data`, `rdata`

The flash returns the bytes at increasing addresses, each MSB first, and `rcv_data` shifts left,
so the first byte, the one at the lowest address, ends in `rcv_data[31:24]`. RISC-V is
little-endian: the byte at the lowest address is the word's least significant byte. `rdata`
reverses the order of the four bytes, not the bits within them:

| `rdata` lane | From `rcv_data` | Byte at flash address |
|---|---|---|
| `[7:0]` | `[31:24]` | +0 |
| `[15:8]` | `[23:16]` | +1 |
| `[23:16]` | `[15:8]` | +2 |
| `[31:24]` | `[7:0]` | +3 |

Bytes `AA BB CC DD` at +0 to +3 arrive as `rcv_data = 32'hAABBCCDD` and leave as
`rdata = 32'hDDCCBBAA`, the word the RAM returns for the same four bytes, so code and data read
the same from the flash as from the RAM.

## Clockworks (`rtl/Clockworks.v`)

The clock enable and the reset that the rest of the design uses, derived from the system clock
and the CPU RESET button. Adapted from Bruno Levy's `clockworks.v`; the file header says what
was kept.

### What Clockworks provides

**Question:** What does `Clockworks` give the rest of the design, and what does it expect of its
inputs?

*Where:* `rtl/Clockworks.v`, `clk_enable`, `reset_n`, `SLOW`; its instance `clockworks` in
`rtl/SOC.v`

Two outputs: `clk_enable`, high one cycle in `2^SLOW` ("Gearbox counter"), and `reset_n`, the
CPU RESET button (`SOC` port `RESET`, 0 while pressed) forwarded unchanged, with no
synchroniser and no debounce. `clk` must already be single-ended: `SOC` brings the board's
differential pair in through `IBUFDS` and `BUFG` first. The upstream module also built a PLL and
a power-on reset; both were removed. `SOC` sets `SLOW` to 0, so `Clockworks` is two wires and
synthesises to no cell.

### Gearbox counter

**Question:** How does `clk_enable` pulse once every `2^SLOW` cycles, and which blocks does it
slow down?

*Where:* `rtl/Clockworks.v`, `div`, `tick`, `clk_enable`

With `SLOW` above 0, `div` is a `SLOW`-bit counter that increments every cycle, and `tick`, which
is `clk_enable`, is registered high in the cycle after `div` was all ones: exactly one cycle in
`2^SLOW`. A press of the button clears both, so `clk_enable` is low during reset. The core, the
RAM and `IOBus`'s LED register advance only on enabled cycles. `UartTx` and `SPIFlash` take no
`clk_enable` and run every cycle, so the baud rate and the SPI clock stay right, and `IOBus`
gates the UART's `valid` and the flash's `rstrb` with `clk_enable`, so a store or a read that the
slowed core holds for `2^SLOW` cycles still sends one byte or starts one transaction. The point is
to watch the core step: with `SLOW` at 20 it runs about 190 states a second. No build or bench in
the repository sets `SLOW` above 0, so the slowed design is untested.

## UartTx (`rtl/UartTx.v`)

The UART transmitter: 8N1, least significant bit first, at `BAUD` baud. Adapted from CoreScore's
`emitter_uart.v`; the file header lists the changes.

### Frame format and interface

**Question:** What does the transmitter put on the line for one byte, and when does it accept
the next?

*Where:* `rtl/UartTx.v`, `data`, `valid`, `ready`, `tx`, `frame`, `bit_index`

The line idles high. A byte goes out as ten bits, each `CLKS_PER_BIT` cycles long: a start bit
(0), `data[0]` to `data[7]`, LSB first, and a stop bit (1); `bit_index` counts them, 0 to 9.
`frame` is loaded with `{1, data, 0}` and shifts right once per bit, so at each bit boundary
`frame[1]` is the next bit to send.

`valid` is looked at only in `IDLE`, so a byte offered while `ready` is low is dropped
("UART send pulse and the status word (bit 9 convention)"). `tx` drives the `SOC` port
`uart_rx_out` ("UART port names and the pin-direction trap").

### Cycles per bit and the counter width

**Question:** How long is one bit, and how wide is the counter that times it?

*Where:* `rtl/UartTx.v`, `CLKS_PER_BIT`, `CLK_CNT_WIDTH`, `clk_cnt`

`CLKS_PER_BIT` is `CLK_HZ / BAUD` in integer division: 200,000,000 / 115,200 = 1736, truncated
from 1736.1. The line runs at 115,207 baud, 0.006 % fast, well within the few percent a UART
receiver tolerates. A byte takes 10 × 1736 = 17,360 cycles, 86.8 µs. `clk_cnt` counts from 0
to `CLKS_PER_BIT` - 1 within each bit, so it needs `$clog2(CLKS_PER_BIT)` bits, 11 here, and the
width follows any other `CLK_HZ` or `BAUD`. `SOC` passes `` `CLK_HZ`` from `rtl/defines.vh` and
its own parameter `UART_BAUD`, `` `UART_BAUD`` by default; `sim/bench.v` sets it from its `BAUD`.

### Reset state

**Question:** What does reset do to the transmitter, and how does it start when no reset comes?

*Where:* `rtl/UartTx.v`, `reset_n`, `state`, `ready`, `tx`, `frame`

Reset is synchronous: `reset_n` low at a clock edge puts the transmitter in `IDLE` with `ready`
high, `tx` high, the line's idle level, and `frame` all ones. A press in the middle of a byte cuts
the frame short, and the PC may receive a garbled byte. The registers declare no initial values.
On the board they start at 0 after configuration, which is `IDLE`, and the first clock edge in
`IDLE` drives `tx` and `ready` high, so no press is needed. In simulation they start as `x`;
`sim/bench.v` and `docs/design/scripts/waves/WaveBench.v` hold the reset low at the start, which
defines them.

## Memory (`rtl/Memory.v`)

The on-chip RAM: one block-RAM array that holds both the program and its data, filled from
`rtl/firmware.hex` when the design is synthesised or simulated.

### Read and write timing are not symmetric

**Question:** Why does the core wait a cycle after every read from the RAM but not after a store?

*Where:* `rtl/Memory.v`, `rtl/Control.v`, `mem_rstrb`, `mem_rdata`, `mem_wmask`

One RAM with one port serves instruction fetch, loads and stores; there is no separate
instruction memory. A read is registered: the word appears on `mem_rdata` the cycle after
`mem_rstrb`, so `FETCH_INSTR` is followed by `WAIT_INSTR` and `LOAD` by `WAIT_DATA`. A write
takes effect on the same edge that its address, data and mask are presented, so `STORE` goes
straight back to `FETCH_INSTR` ("STORE needs no wait state"). The registered read is also what
lets Vivado map the array onto block RAM, whose read port is synchronous.

### RAM size and the firmware load

**Question:** How big is the RAM, and how does the program get into it?

*Where:* `rtl/Memory.v`, `rtl/defines.vh`, `ram`, `WORDS`, `RAM_WORDS`, `$readmemh`

`ram` is `WORDS` words of 32 bits. `WORDS` defaults to `RAM_WORDS`, 1536, so 6 KB, which Vivado
maps onto two block-RAM tiles (`docs/baseline.md`). An `initial` block fills it with
`$readmemh("firmware.hex", ram)`: a simulator runs it at time 0, and Vivado evaluates it at
synthesis and stores the contents in the bitstream as the block RAM's initial values.

`firmware.hex` is written by `make -C fw` (`firmware_words`, below): text, four words a line
separated by spaces, 1536 words in all, the whole RAM, with zeros after the program.

A missing file stops nothing. xsim prints `WARNING: File firmware.hex ... cannot be opened for
reading` and iverilog an `ERROR` line, and both carry on with every word of `ram` at X, so the
program never runs. If a simulation shows no activity at all, look for that line first.

### Bare file name in $readmemh

**Question:** Where must `firmware.hex` be for a tool to find it?

*Where:* `rtl/Memory.v`, `vivado/create_project.tcl`, `vivado/baseline.tcl`,
`sim/run_regression.sh`, `docs/design/scripts/board_bitstream.tcl`

`$readmemh("firmware.hex", ...)` resolves the name against the working directory of the tool
that reads it, not against `rtl/`. Each flow therefore puts the image where its tool runs:

| Flow | How the image gets there |
|---|---|
| Vivado project: `make bitstream`, the GUI | `create_project.tcl` adds `rtl/firmware.hex` to the synthesis and simulation filesets as a Memory File; Vivado copies it into each run directory |
| Non-project baseline: `make baseline` | `baseline.tcl` copies it into its output directory and runs there |
| Regression: `make smoke`, `make check-sim` | `run_regression.sh` links it into `sim/build/` and runs xsim from there |
| The report's board and flow builds | the demo's image is built into the build directory (`HEX_OUT`), and `board_bitstream.tcl` runs Vivado there |

Running a tool from `rtl/` instead would find the file, but Vivado would then leave `.Xil/` and
`clockInfo.txt` beside the sources, which `make lint` (rule 1) rejects.

**Pitfall:** a missing file leaves the RAM undefined without an error. In simulation the
program does nothing: the LEDs stay at zero and the RAM reads `x`, with only a warning in
xsim's log. After a Vivado run from the wrong directory, `.Xil/` and `clockInfo.txt` appear
beside the sources. Handled: every script that simulates or synthesises runs in a directory of
its own with the image linked or copied in, as the table shows, and lint rule 1 fails on the
by-products.

### Simulation and hardware after a firmware change

**Question:** What must be redone after `rtl/firmware.hex` changes, in simulation and on the
board?

*Where:* `rtl/firmware.hex`, `sim/run_regression.sh`, `sim/bench.v`,
`vivado/create_project.tcl`, `docs/design/scripts/board_capture.sh`

- **Regression.** `run_regression.sh` links the current image afresh on every run, so nothing
  needs resetting. Another program gives another trace, so the gate fails unless the change is
  meant, and then needs `make golden`.
- **GUI simulation.** Vivado simulates its own copy of the image in the run directory: reset
  the behavioural simulation before running again, so the copy is refreshed. The project sets
  the run time to `-all`; the bench ends the run itself (`sim/README.md`, "Stop conditions").
- **Board.** The image is the block RAM's initial value inside the bitstream, so a new image
  needs a new BRAM-boot bitstream, synthesis onward; reloading the old bitstream runs the old
  program. `docs/design/scripts/board_capture.sh <demo> bram ...` builds and loads one
  (README, "Running the demos"). `make bitstream` builds the flash-boot default, whose program
  comes from the flash and not from this image.

### Per-byte write enables

**Question:** How does the RAM turn the core's byte address and mask into a word access, so
that `sb` and `sh` change only their own bytes?

*Where:* `rtl/Memory.v`, `rtl/Processor.v`, `mem_addr`, `mem_wmask`, `mem_wdata`

The word index is `mem_addr[31:2]`; bits 1 and 0 are ignored. A read always returns the whole
word, and a write picks its bytes by the mask: `mem_wmask[k]` writes byte lane `k`,
`ram[i][8k+7:8k]`, from the same lane of `mem_wdata`. A zero mask means no write. The core does
the byte steering: it copies a stored byte or halfword into every lane it may land in and sets
the mask from the address ("Store data is broadcast to every lane, the mask selects"), and it
picks a loaded byte or halfword out of the returned word.

## Firmware build (`fw/`)

How `make -C fw` turns C and assembly into the RAM image or a flash image, and why each piece
of that build is there.

### The toolchain: Ubuntu's riscv64-unknown-elf packages

**Question:** Which RISC-V toolchain builds the firmware, and why that one?

*Where:* `fw/Makefile`, `CROSS`, `ARCHFLAGS`, `XILINX_RV32_ROOT`

Ubuntu 24.04's `gcc-riscv64-unknown-elf` (GCC 13.2.0) and `binutils-riscv64-unknown-elf`
(2.42), installed with apt: no download script and no PATH edits. The `riscv64` in the name is
the compiler's default target, not a limit: `-march=rv32i -mabi=ilp32` select 32-bit RV32I
code, and the package carries the matching `rv32i/ilp32` build of `libgcc.a`, so no separate
riscv32 toolchain is needed.

The version matters. Another GCC may emit different code for the same source; the image then
differs from the committed `rtl/firmware.hex` (`make -C fw check` fails) and the golden
trace's cycle count changes. The package ships no C library (see "The missing stdio.h and the
stub header"); tinyraytracer's `<math.h>` and `libm` come from the RISC-V newlib bundled with
Vivado, at `XILINX_RV32_ROOT`.

### The compiler and linker flags, one by one

**Question:** What does each flag in `fw/Makefile` do, and what goes wrong without it?

*Where:* `fw/Makefile`, `ARCHFLAGS`, `ASFLAGS`, `CFLAGS`, `LDFLAGS`, `link`

| Flag | Given to | Why |
|---|---|---|
| `-march=rv32i` | gcc, as | Base integer instructions only, the set the core executes. Without it gcc targets its default, `rv64imafdc`: 64-bit code with multiply, float and compressed instructions, which the core cannot decode, with no error anywhere |
| `-mabi=ilp32` | gcc, as | `int`, `long` and pointers of 32 bits, no float registers: the calling convention that `start*.S` and the `.S` routines assume |
| `-mno-relax` | as | The `.S` objects carry no relaxation requests (below) |
| `--defsym RAM_SIZE=6144` | as, ld | The RAM size as a symbol: the stack top in `start*.S`, the RAM length in `memory.ld` |
| `-O2` | gcc | Optimised code, smaller and faster in a 6 KB RAM; the committed image and the golden trace's cycle count are those of `-O2` |
| `-fno-pic` | gcc | Code for the one address it is linked at, with no indirection through a global offset table |
| `-fno-stack-protector` | gcc | No stack canaries, whose check calls `__stack_chk_fail`, which nothing here provides |
| `-I.` | gcc | `<stdio.h>` resolves to the stub `fw/stdio.h` |
| `-m elf32lriscv` | ld | Output is 32-bit little-endian RISC-V ELF |
| `-nostdlib` | ld | No host start-up files or libraries: `start*.S` is the entry, and the libraries are named explicitly |
| `--no-relax` | ld | No linker relaxation (below). Two dashes: ld refuses `-norelax` ("unable to disambiguate") |
| `--no-warn-rwx-segments` | ld | Silences the warning that a segment is writable and executable: one RWX RAM is the intended layout of a bare-metal core with no OS to enforce W^X |
| `-T bram.ld` or `-T spiflash.ld` | ld | The layout of the boot mode |
| `--start-group libgcc.a [libm] --end-group` | ld | Last on the line: see "Why libgcc.a is required and why it goes last" |

Relaxation lets ld shorten code after layout: a call becomes a single `jal`, address loads
shrink, and when the symbol `__global_pointer$` is defined, accesses near it become
`gp`-relative. In this design `gp` holds `IO_BASE` for the whole run, so `gp`-relative data
accesses would be wrong. Neither linker script defines `__global_pointer$`, so today relaxation
would only shorten code (mandelbrot's BRAM image from 3408 to 3280 bytes). It stays off so that
the image is the committed one and `gp` serves the IO accesses alone. gcc's objects still carry
relaxation requests (`CFLAGS` has no `-mno-relax`), so ld's `--no-relax` is the switch that
matters; `start_spiflash.S` also wraps its `li gp,IO_BASE` in `.option norelax`.

### bram.ld line by line, the /DISCARD/ workaround

**Question:** How does `bram.ld` lay a program out in the RAM, and why does it discard two
sections?

*Where:* `fw/bram.ld`, `fw/memory.ld`, `fw/start.S`, `fw/Makefile` `link`

| Line | Effect |
|---|---|
| `INCLUDE memory.ld` | Region `RAM`: origin 0, length `RAM_SIZE`; ld stops with a region overflow if the program does not fit |
| `/DISCARD/ : { *(.riscv.attributes) *(.comment) }` | Drops two metadata sections before the catch-all below can take them |
| `everything : { ... } >RAM` | One output section for code, constants, data and `.bss` alike |
| `*/start.o (.text)` | `start.S` first, at address 0, the BRAM-boot reset vector |
| `*(.*)` | Every other section of every input, in link order |

Every object carries `.riscv.attributes`, a record of the ISA it was built for, and gcc's
objects `.comment`, the compiler's version string. Neither is meant to be loaded, but `*(.*)`
would lay them in RAM between the functions: in mandelbrot's image they would take 290 bytes
(3698 instead of 3408), as nonsense instructions in the disassembly. Nothing jumps into them,
but they take RAM from the stack.

`*/start.o` is a wildcard pattern, so it only orders the file and does not pull it into the
link: the Makefile's `link` macro names `start.o` on the command line. Because one section
holds everything, `.data` and `.bss` are in the image with their initial values, and `start.S`
copies and zeroes nothing. Those values hold only after configuration: the RAM has no reset, so
the reset button restarts `main` with whatever the last run left in its globals.

The same catch-all still loads debug data. Ubuntu's `libgcc.a`
(`/usr/lib/gcc/riscv64-unknown-elf/13.2.0/rv32i/ilp32/`) carries DWARF sections in its members,
and `*(.*)` places those of `muldi3.o` and `div.o` (`.debug_line`, `.debug_info`,
`.debug_abbrev`, `.debug_aranges`, `.debug_str`, `.debug_line_str`) right after their code: in
mandelbrot's image 576 bytes after `__mulsi3` and 508 after `__modsi3`, 1084 of its 3408 bytes.
They are never fetched, so the program runs the same, but they take room the stack grows into.
Adding `*(.debug*)` to `/DISCARD/` gives a 2324-byte image, with `__divsi3` at `0x860` instead
of `0xaa0`; the change is left out so that the image the report describes stays the committed
one. `spiflash.ld` names its input sections, so it loads none of these.

**Pitfall:** none at run time, but the image is larger than its code, 852 words, and
`objdump -D` shows runs of `.insn` nonsense after `__mulsi3` and `__modsi3`: 1084 bytes, 18 %
of the 6 KB, never fetched but taken from the room the stack grows into. Not handled: adding
`*(.debug*)` to `/DISCARD/` is the fix, left out as above.

### Support objects every C program needs

**Question:** What do the support objects linked into every program provide, and why is each
one there?

*Where:* `fw/Makefile` `LIBOBJS`, `fw/putchar.S`, `fw/print.c`, `fw/wait.S`, `fw/memcpy.c`,
`fw/errno.c`

| Object | Provides | Why |
|---|---|---|
| `putchar.S` | `putchar` | Stores the byte at `IO_UART_DAT(gp)`, then polls `IO_UART_CNTL(gp)` until bit 9, busy, clears: all output ends here. Its offsets and busy bit are held equal to `rtl/defines.vh` by lint rule 8 |
| `print.c` | `printf`, `puts`, `print_string`, `print_dec`, `print_hex` | A `printf` small enough for the RAM: `%s`, `%d`, `%c` and `%x` (eight upper-case digits), nothing else |
| `wait.S` | `wait` | A delay loop of 2^17 iterations, about 5.24 ms (blinker, sieve) |
| `memcpy.c` | `memcpy` | gcc emits `memcpy` calls on its own, for struct and array copies, even when the source never calls it. Its `no-tree-loop-distribute-patterns` pragma stops gcc from turning `memcpy`'s own loop into a call to `memcpy` |
| `errno.c` | `__errno` | newlib's `libm` reports errors through `__errno()`, which returns a pointer to `errno`; tinyraytracer's `powf` calls it, and nothing else here defines it |

Objects named on the ld command line are linked whole whether used or not, unlike archive
members, so every image carries all five.

### The missing stdio.h and the stub header

**Question:** How do the demos that `#include <stdio.h>` compile when the toolchain has no C
library, and which headers does a new program need a stub for?

*Where:* `fw/stdio.h`, `fw/Makefile` `CFLAGS`, `MATH_INC`

Ubuntu's `gcc-riscv64-unknown-elf` ships gcc's own headers but no C library, so
`#include <stdio.h>` fails with `fatal error: stdio.h: No such file or directory`. The compiler
needs only declarations; the code comes at link time from `print.c` and `putchar.S`.
`fw/stdio.h` is therefore a stub: `#pragma once` and the declarations of `printf` and
`putchar`. `-I.` in `CFLAGS` puts `fw/` on the include path ahead of the system's, so
`<stdio.h>` finds the stub; tinyraytracer's newlib include directory comes after `-I.`, so the
stub still wins over newlib's `stdio.h`.

The headers gcc provides (`<stdint.h>`, `<stddef.h>`, `<stdarg.h>`, `<limits.h>`,
`<stdbool.h>`) work as they are. C-library headers (`<stdio.h>`, `<string.h>`, `<stdlib.h>`,
`<unistd.h>`) are missing: for one of those, declare in a stub only what the program calls,
and link something that defines it. The demos include `<unistd.h>` and `<stdlib.h>` only under
`#ifdef __linux__`, for their native build on a PC.

### Why libgcc.a is required and why it goes last

**Question:** Why must every program link `libgcc.a`, and why does it come last on the ld
command line?

*Where:* `fw/Makefile` `LIBGCC`, `link`, `fw/spiflash.ld`

The core has no multiply or divide instruction. For `*`, `/` and `%` gcc emits calls to
`__mulsi3`, `__divsi3`, `__udivsi3`, `__modsi3` and `__umodsi3`, and for tinyraytracer's
floating point to the soft-float routines; all of them are in `libgcc.a`, which ships with
gcc. Without it the link fails with ``undefined reference to `__mulsi3'``. The Makefile asks
gcc for the copy that matches the flags, `$(CC) $(ARCHFLAGS) -print-libgcc-file-name`
(`/usr/lib/gcc/riscv64-unknown-elf/13.2.0/rv32i/ilp32/libgcc.a` here), instead of a fixed path
that the next toolchain update would break.

ld takes from an archive only the members that define symbols still undefined at that point of
the command line, so libraries come after every object that uses them. `--start-group ...
--end-group` around `libgcc.a` and tinyraytracer's `libm` lets ld rescan both, since `libm`,
listed second, calls `libgcc`'s soft-float routines. In flash boot, `spiflash.ld` copies
`muldi3.o` and `div.o` into the RAM with the other hot code.

### The -DSTANDALONE_FEMTOELF build of firmware_words

**Question:** How is the ELF-to-hex converter built, and what is `-DSTANDALONE_FEMTOELF` for?

*Where:* `fw/Makefile` `FW_WORDS`, `fw/tools/firmware_words_src/`

`firmware_words` is a host program: the Makefile compiles `firmware_words.cpp` and
`femto_elf.c` with `$(HOSTCXX)` (default `g++`) into `$(BUILD)/firmware_words`. `femto_elf.c`,
the ELF reader, was written to run on a RISC-V core too. `-DSTANDALONE_FEMTOELF` selects its
host build: file reading through stdio, and its `LEDS()` progress calls compiled out. Without
the define `femto_elf.h` includes `femtorv32.h`, the header of the firmware library it came
from, which this repository does not have, and the build fails.
`-Itools/firmware_words_src` is there because the sources include `<femto_elf.h>` with angle
brackets.

### Why the ELF-to-hex conversion exists, endianness

**Question:** Why is the linked ELF converted to a hex file, and in what byte order are the
words written?

*Where:* `fw/tools/firmware_words_src/firmware_words.cpp` `save_RAM_hex`, `rtl/Memory.v`
`$readmemh`

ld writes ELF, a container of headers, section tables and symbols; `$readmemh` wants plain hex
numbers as text. `firmware_words` loads the ELF's contents into a byte array the size of the
RAM and writes it out a word at a time. RISC-V is little-endian: the byte at the lowest address
is the least significant byte of its word. `$readmemh` reads each token as a number, most
significant digit first, so the tool prints each word's bytes from the highest address down.
mandelbrot's first instruction, `lui gp,0x400`, is the bytes `b7 01 40 00` in memory and the
token `004001b7` in the file. Printed in memory order instead, every word the core fetched would
be byte-swapped.

The flash build needs no such step: `objcopy -O binary` writes the bytes in memory order, as
they sit in the flash, and `fw/tools/write_mcs.tcl` wraps them in an MCS file for Vivado.

### firmware_words arguments, -max_addr as a stack guard

**Question:** What do `firmware_words`' arguments do, and does anything keep the stack from
overwriting the program?

*Where:* `fw/Makefile`, `fw/tools/firmware_words_src/firmware_words.cpp`, `fw/start.S`

The Makefile runs `firmware_words <prog>.bram.elf -ram 6144 -max_addr 6144 -out <HEX_OUT>`,
both sizes being `RAM_SIZE`:

| Argument | Effect |
|---|---|
| `-ram N` | The RAM in bytes, the size of the image; an ELF that reaches address N fails with `Memory exceeded !` |
| `-max_addr N` | Fails with `MAX_ADDR exceeded` if the program's highest address is above N |
| `-out f` | A name ending in `hex` writes `$readmemh` text. Raw binary needs a name ending in `elf`, an upstream quirk, and `.bin` is refused; the flash build uses `objcopy` instead |

It reports the program's size, for mandelbrot `Code size: 852 words ( total RAM size: 1536
words )` and `Occupancy: 55%`, with a warning above 95 %. The stack starts at `RAM_SIZE`
(`start*.S`) and grows down into the same RAM, and nothing checks at run time that it stays
clear of the program: a deep call chain overwrites code or data without a sign, and the core
then runs garbage. A `-max_addr` below `-ram` would reserve headroom for the stack. The Makefile
passes the full size and reserves none, so the margin is what the occupancy leaves: 2736 bytes
for mandelbrot. In flash boot the stack shares the RAM with the data and the code copied from
the flash ("Execute-in-place" in the report), and nothing checks that either.

**Pitfall:** the stack runs into the program. A program that has grown wanders off into
garbage after a while, or prints nonsense, with no warning from the build. Handled in part:
`firmware_words` refuses an image past `-max_addr`, which, set below the RAM size, reserves
room for the stack; the stack itself is not checked.

### Why blinker's LEDs look steadily lit

**Question:** Why do LD0 to LD3 look steadily lit under `blinker.S` instead of blinking?

*Where:* `fw/blinker.S`, `fw/wait.S`

`blinker.S` alternates the LED register between `0x05` and `0x0A`, with a call to `wait` after
each. `wait.S` counts down 2^17 iterations of `addi` and `bnez`, two instructions of four cycles
each: 1 048 576 cycles, 5.24 ms at 200 MHz. The pattern repeats every 10.5 ms, 95 times a
second, faster than the eye follows, so each of LD0 to LD3, lit half the time, looks steadily on
at reduced brightness. Nothing is broken. Raising the shift in `wait.S` from 17 to 23 makes the
delay 64 times longer, about 335 ms, and the blink visible; sieve, which also calls `wait`,
would slow down with it.

### Where the UART output appears on the PC

**Question:** Which of the board's USB ports carries the UART output?

*Where:* `rtl/SOC.v` `uart_rx_out`, README "Running the demos"

The micro-USB port J15, behind the FT232R USB-UART bridge, not the JTAG port J17. On Linux it
appears as a serial device such as `/dev/ttyUSB0`; the README, "Running the demos", gives the
terminal settings. `docs/design/scripts/uart_capture.py` records the port with timestamps, as
the report's captures were made.

## Board flash writes (`docs/design/scripts/board_flash.tcl`)

How a program or the scene data reaches the board's flash: Vivado's *Program Configuration
Memory Device* over JTAG, with the address range *Configuration File Only*, so that only the
bytes the image covers change (README, "Running the demos").

### Writing the flash clears the Quad Enable bit

**Question:** Why can a flash write stop the board from booting at power-on, and how is that
prevented?

*Where:* `docs/design/scripts/board_flash.tcl` (`PROGRAM.SKIP_QE_BIT_ERASE`),
`docs/design/scripts/flashregs/FlashRegs.v`, `docs/design/figures/README.md`, "The Quad
Enable bit"

Vivado's `program_hw_cfgmem`, with the `hw_cfgmem` property `PROGRAM.SKIP_QE_BIT_ERASE` at its
default, 0, clears the S25FL256S's non-volatile Quad Enable bit (configuration register 1,
bit 1). The factory bitstream at offset 0 reads the flash four bits wide and needs the bit. A
write with an SPIx4 `.prm` does not set it back, and Vivado's Tcl has no command that reads the
flash's registers.

**Pitfall:** after a flash write, the board no longer boots at power-on: DONE off, no error
flag, the mode pins right, and every byte of the flash intact. Handled: `board_flash.tcl write`
sets `SKIP_QE_BIT_ERASE` to 1, and a write with it kept the bit. `FlashRegs.v`, loaded over
JTAG, prints the flash's registers on the UART and, built with `WRITE_REGS=1`, writes the bit
back, which repaired my board.

## program_asm (`sim/asm/program_asm.v`)

The Verilog assembler's sample program, an ASCII Mandelbrot. `MEM` and `memPC` keep their
upper-case names because `riscv_assembly.v` (third-party, unchanged) writes to them.

### What the program does and how it multiplies

**Question:** What does `program_asm.v` compute, and how does it multiply on a core without
MUL?

*Where:* `sim/asm/program_asm.v`, `sim/asm/Makefile`, `mulsi3_`, `wait_`, `colormap_`

It draws an 80 by 80 character Mandelbrot set over the UART, for the viewport [-2, 2] x
[-2, 2], forever. Each pixel iterates Z <- Z^2 + C from Z = C, at most 9 times, stops when
Zr^2 + Zi^2 exceeds 4 (`NORM_MAX`), and prints the character of `colormap_` (` .,:;ox%#@`)
indexed by the iterations it had left. Numbers are Q22.10 fixed point: x is stored as the
integer x * 2^10, so sums need no correction, and a product, scaled by 2^20, is shifted right
by 10. Products come from `mulsi3_`, a shift-and-add multiply, a0 <- a0 * a1, because RV32I has
no MUL; in C, gcc calls `libgcc`'s `__mulsi3` for the same job.

Before each frame the LEDs blink five times, a visible mark that a frame starts. `wait_` counts
down from `1 << SLOW_BIT`: 20 on the board, about 42 ms per pattern, and 0 under
`make -C sim/asm DEFS=-DBENCH`, so a simulation does not spend its time in the blink. Each row
ends in a space, CR and LF, so the picture comes out right without a terminal option such as
picocom's `--imap lfcrlf`, which the C demos need.

`make -C sim/asm` assembles it under iverilog into `sim/asm/program.hex`, a `$readmemh` image
of 92 words, one per line. The stack top, the IO base and the register offsets come from
`rtl/defines.vh`. No build uses the output and neither output is tracked: the program is the
assembler's worked example.

### Label workflow

**Question:** How are branch and call targets resolved, and what must be redone after editing
the program?

*Where:* the `integer ..._` labels, `Label()`, `LabelRef()`, `endASM()` in
`sim/asm/riscv_assembly.v`

The assembler runs in one pass, so each label is an integer variable whose address is typed in
beforehand (`integer loop_y_ = 76;`). After an edit that moves code, run
`make -C sim/asm DEFS=-DBENCH`. Under `BENCH`, each `Label()` prints `Label:` and its real
address, in program order, and reports `Missing label initialization` or `Incorrect label
initialization` (expected and got) where the typed value is wrong; `endASM()` then stops before
`program.hex` is written. Copy the printed addresses into the declarations and run again until
it passes. Without `BENCH` nothing is checked, and a stale label assembles a jump to the wrong
place without a word.

### Leaf subroutines, and why every CALL() targets forward

**Question:** Why does no subroutine save `ra`, and why does every `CALL()` jump forward?

*Where:* `wait_`, `putc_`, `mulsi3_`, `CALL`, `AUIPC`, `LI` in `sim/asm/riscv_assembly.v`

`wait_`, `putc_` and `mulsi3_` call nothing, so `ra` survives in its register and none needs a
stack frame. `CALL(offset)` expands to `AUIPC(x6, offset)` and `JALR(x1, x6, offset[11:0])`.
`JALR` sign-extends its 12-bit immediate, so when `offset[11]` is 1 the upper part given to
`AUIPC` must be raised by `1 << 12` to compensate. `LI()` makes that correction and `AUIPC()`
does not. Bit 11 is set in every negative offset from -1 to -2048, so any short backward call
lands 4 KB too low. Every `CALL()` therefore targets code after it: the render loop calls
forward into `putc_` and `mulsi3_`, the blink into `wait_`. A forward offset keeps bit 11 clear
while the program stays under 2 KB; it is 368 bytes. `J()` and the branches (`BEQ`, `BNE`,
`BGT`, `BEQZ`, `BNEZ`) encode their target in one signed field and work in both directions.
