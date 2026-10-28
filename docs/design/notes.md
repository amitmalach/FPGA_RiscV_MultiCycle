# Design notes

The rationale behind the RTL and the firmware, in the words of the long comments that once
sat in the sources, kept close to verbatim (lines over 100 characters are re-wrapped and old
file names are rewritten) so the final report can draw on it. Each entry names the
module and the signal or construct the comment sat next to. Comments explaining Verilog
syntax were dropped without record. Signal names in the quoted text are those of the time.

This file is the declared input of the final report.

## SOC (`rtl/SOC.v`)

The address decode, LED register and UART/flash handshakes now live in `rtl/IOBus.v` and
the constants in `rtl/defines.vh`.

### UART port names and the pin-direction trap

*Signals:* `uart_tx_in`, `uart_rx_out`, `UART.o_uart_tx`

Port comments on `uart_tx_in` / `uart_rx_out`:

```text
    input  wire       uart_tx_in,              // "TX" = PC's TX; "_in" = input to FPGA. So: PC ->
    FPGA (unused, see below)
    output wire       uart_rx_out,             // "RX" = PC's RX; "_out" = output of FPGA. So: FPGA
    -> PC (what we transmit on)
```

```text
---- READ THIS BEFORE TOUCHING THE TWO UART PORTS ABOVE -------------

These two names (fixed by the board schematic / XDC: Sch=uart_tx_in,
Sch=uart_rx_out) are confusing because each one mixes TWO DIFFERENT
POINTS OF VIEW in a single identifier:

    TX / RX     <- named from the *PC's* point of view
    _in / _out  <- named from the *FPGA's* point of view

The Genesys 2 reference manual states the first half: "Signal names
that imply direction are from the point-of-view of the DTE (Data
Terminal Equipment), in this case the PC." So "TX" means the PC
transmits, and "RX" means the PC receives. The trailing "_in"/"_out"
then describes the same wire as seen from this module -- which is why
they line up directly with the port directions declared above.

Read each name one half at a time and both come out consistent:

  uart_tx_in   "the PC's TX line, which is an INPUT to the FPGA"
                 -> data flows PC -> FPGA
  uart_rx_out  "the PC's RX line, which is an OUTPUT of the FPGA"
                 -> data flows FPGA -> PC

The trap is applying the PC's point of view to BOTH halves (reading
"_in" as "into the PC"), which flips both wires and is a completely
natural misreading of the names.

What settles it, with no naming convention needed at all: on every
UART device, TXD is an output and RXD is an input. Following the
schematic nets:

  FT232RQ pin 30, labeled TXD (that chip DRIVES it)
       -> net UART_TX_IN  -> FPGA pin Y20  => must be an FPGA INPUT
  FT232RQ pin  2, labeled RXD (that chip LISTENS on it)
       -> net UART_RX_OUT -> FPGA pin Y23  => must be an FPGA OUTPUT

Getting this backwards is silent and very hard to diagnose: the
transmitter ends up driving Y20, a pin the FT232RQ is itself driving,
so the two chips fight over the net, the FT232RQ's activity LED (LD12)
never blinks, and not one byte reaches the PC -- while everything
inside the FPGA looks perfectly healthy. Simulation does not catch it
either; see the serial decoder note in the old iverilog testbench.

The FT232RQ is a USB-to-UART bridge; it converts uart_rx_out's serial
stream into USB, which appears on the host as a virtual COM port
(/dev/ttyUSBx on Linux) -- what GTKTerm/picocom actually reads.

uart_tx_in carries whatever the PC sends back, but nothing here reads
it: this design has only the transmitter in emitter_uart.v, no
receiver. Adding RX support would mean writing a receiver module (the
mirror image of emitter_uart.v) plus a memory-mapped "byte received"
register for Processor to poll.
```

On the `.o_uart_tx(uart_rx_out)` connection:

```text
o_uart_tx is named from THIS FPGA's point of view (the FPGA
transmits on it), so it connects to uart_rx_out -- whose "RX" is
named from the PC's point of view (the PC receives on it). Same
wire, two different vantage points; see the extended note in the
port list at the top of this file. It must NOT go to uart_tx_in,
which is an input here (the PC's TX line, driven by the FT232RQ).
```

### Processor bus has no notion of RAM versus device

*Signals:* `mem_addr`, `mem_rdata`, `mem_rstrb`, `mem_wdata`, `mem_wmask`, `mem_rbusy`

```text
-------------------------------------------------------------------------
Processor <-> memory bus. Processor.v only ever drives/reads these five
signals -- it has no notion of "RAM" vs "device register"; that split
is entirely decided below by how this file routes them.
```

```text
    wire [31:0] mem_addr;   // address the Processor wants to read or write
    wire [31:0] mem_rdata;  // data returned to the Processor (from RAM, IO, or flash -- see mux
                            // below)
    wire        mem_rstrb;  // Processor's read strobe
    wire [31:0] mem_wdata;  // Processor's write data
    wire [3:0]  mem_wmask;  // Processor's per-byte write mask
    wire        mem_rbusy;  // tells the Processor to keep waiting -- see SPIFlash instantiation
                            // below
```

### Address decode: one bit per region, one-hot IO registers, why bit 24

*Signals:* `isSPIFlash`, `isIO`, `isRAM`, `mem_wordaddr`

```text
-------------------------------------------------------------------------
Memory-mapped IO -- address decoding
-------------------------------------------------------------------------
Bit 22 and bit 24 of the address now split the map three ways:
  bit 24 set              -> SPI flash space
  bit 24 clear, bit 22 set -> IO space (unchanged from before)
  both clear               -> RAM
Within IO space, each device still claims one bit of the word address
(1-hot), rather than a device number decoded by a multi-bit
comparator -- e.g. LEDS is selected purely by mem_wordaddr[0]==1,
regardless of every other bit. In byte-address terms (what software
uses), IO_xxx_bit N therefore sits at byte offset (1 << (N+2)) from
the IO base 32'h400000. SPI flash space starts at byte address
32'h1000000 (bit 24 set, everything else clear).

Why bit 24, not bit 23: the flash selector bit is what determines how
MANY low-order address bits are left over to actually address WITHIN
flash space (everything below the selector bit, since the selector
itself and everything above it can't be part of the in-flash offset
without colliding with something else). Bit 23 only leaves 23 bits
(8MB) of addressable flash offset -- and this board's own bitstream,
sitting at the start of the same 32MB chip, runs past 11MB. An 8MB
window can never reach past an 11MB bitstream, so nothing placed in
flash could ever have been reachable without overlapping it. Bit 24
leaves 24 bits (16MB) of offset, matching the SPI flash's own 03h
Read command's natural 3-byte/24-bit address field (see SPIFlash.v)
with no room to spare -- exactly enough to place data safely past
this design's bitstream while staying within what a single 03h
command can address at all.
```

### Flash memory map and boot address

*Signals:* `SPIFLASH_BASE`, `SPIFLASH_CODE_OFFSET`, `BOOT_ADDR`, `CPU.RESET_PC`

On the `BOOT_ADDR` parameter:

```text
Reset vector handed to the core. Default = SPIFLASH_BASE + SPIFLASH_CODE_OFFSET
(flash boot, see the localparams below). The testbench overrides it to 0
(BRAM boot) because no SPI-flash model exists in simulation.
```

```text
-------------------------------------------------------------------------
Flash memory map and boot address
-------------------------------------------------------------------------
SPIFLASH_BASE is where flash space begins in the CPU's address map --
it is just "bit 24 set", i.e. the isSPIFlash decode above expressed as
an address. Adding an offset to it gives the CPU address of a given
byte inside the physical flash chip.

The physical 32MB flash chip is shared, and the layout below is not
free to choose -- every region was derived from what is already
committed to the chip:

  0x000000 .. 0xAE9E10   this design's own FPGA bitstream (~10.91MB).
                         Fixed size for the xc7k325t: uncompressed
                         7-series bitstreams contain every config
                         frame regardless of design size, so this does
                         not grow as the project grows.
  0xC00000 .. 0xC9C3E7   scene1.dat, the ST_NICCC polygon stream
                         (640KB), written by the ST_NICCC demo flow.
  0xD00000 .. 0xFFFFFF   PROGRAM CODE (3MB) -- this is what flash
                         boot adds, and what BOOT_ADDR points at.
  0xFFFFFF               hard ceiling: the 22-bit word_address into
                         SPIFlash.v can only reach 16MB (see the
                         bit-packing note there).

0xD00000 is 64KB-aligned (required: the flash erases in 64KB sectors,
so anything written must start on a sector boundary), sits 2136KB
clear of the bitstream and 399KB clear of scene1.dat, and leaves 3MB
for code -- against a 6KB BRAM, that is the whole point of flash boot.

NOTE: flash base 1<<23 with a 128KB code offset, a layout sized for a
small board, does not work here. 1<<23 would leave only an 8MB flash window,
smaller than this board's own ~11MB bitstream; and a 128KB offset is
sized for an IceStick bitstream of a few tens of KB, so it would land
squarely inside ours.
localparam [31:0] SPIFLASH_BASE        = 32'h01000000; // bit 24 -- matches isSPIFlash above
localparam [31:0] SPIFLASH_CODE_OFFSET = 32'h00D00000; // 13MB into the chip
BOOT_ADDR (module parameter above) defaults to SPIFLASH_BASE + SPIFLASH_CODE_OFFSET = 0x01D00000.

TO SWITCH BACK TO BOOTING FROM BRAM (the original mode: program
held in Memory.v via $readmemh, 6KB limit), change the Processor
instantiation further down from .RESET_PC(BOOT_ADDR) to
.RESET_PC(32'h00000000). Nothing else needs to change.

localparam IO_LEDS_bit      = 0;  // SW here -> latches LEDS (byte offset 4)
localparam IO_UART_DAT_bit  = 1;  // SW here -> sends one byte over UART (byte offset 8)
localparam IO_UART_CNTL_bit = 2;  // LW here -> reads UART status (byte offset 16)
```

On the `Processor` instantiation:

```text
The RV32I core (see Processor.v). It only ever talks to the shared
mem_addr/mem_rdata/mem_rstrb/mem_wdata/mem_wmask bus above -- every
bit of RAM-vs-IO routing happens around it, in this file, not inside it.
.RESET_PC selects the boot mode -- see the "Flash memory map and boot
address" note above. BOOT_ADDR = boot from SPI flash;
32'h00000000 = boot from BRAM.
```

### UART send pulse and the status word (bit 9 convention)

*Signals:* `uart_valid`, `uart_ready`, `IO_rdata`

```text
High for exactly one cycle when the Processor stores to the UART data
address -- this is the "send this byte now" pulse the UART transmitter
below is waiting for.
wire uart_valid = clk_enable && isIO & mem_wstrb & mem_wordaddr[IO_UART_DAT_bit];
wire uart_ready; // driven by the UART transmitter: high when idle, low while sending a byte

IO_rdata is the read side of memory-mapped IO. It is not a stored
value -- there is no RAM cell behind it -- it is ordinary
combinational logic, recomputed live from mem_wordaddr and
uart_ready, exactly like aluOut or takeBranch in Processor.v. Its
purpose is to let a plain LW answer a question that has nothing to do
with memory: RISC-V has no "ask a peripheral its status" instruction,
only loads and stores, so this is what makes uart_ready -- otherwise
just a wire buried inside this module, invisible to software --
reachable by the processor at all. Reading a specific address is
repurposed into asking a question.

Only the UART status address is wired up to answer anything real.
When mem_wordaddr[IO_UART_CNTL_bit] is set, the concatenation
{22'b0, !uart_ready, 9'b0} places one live bit -- !uart_ready, i.e.
"transmitter busy" -- at bit 9 of the returned word (9 zero bits
below it, 22 above it, 9+1+22 = 32). Software (see putc_ in
program_asm.v) masks with the matching 1<<9 and loops while that bit
is set. Agreeing on "bit 9" is a convention between this line and
that software, not something the hardware enforces on its own.

Every other IO address -- including LEDS and the UART data register,
neither of which has read-back logic here -- falls through to the
':' branch and simply reads as 0.
wire [31:0] IO_rdata =
    mem_wordaddr[IO_UART_CNTL_bit] ? {22'b0, !uart_ready, 9'b0} :
                                     32'b0;
```

### Flash read strobe gated by end-of-startup; 22-bit word address

*Signals:* `spiflash_rstrb`, `eos`, `spiflash.word_address`

```text
High for exactly one cycle when the Processor requests a read from
flash space -- this is the "start a transaction now" pulse
SPIFlash.v's rstrb input is waiting for, exactly parallel to
uart_valid above. Gated by eos (see the STARTUPE2 instantiation
further down) as a belt-and-suspenders check: in practice eos is
already long high by the time software could ever reach a flash
address (it goes high once at boot, well before resetn even
releases), but there's no reason not to make that explicit in the
hardware rather than merely assumed.
wire eos;                   // end-of-startup from STARTUPE2 (declared here: used before the
                            // instantiation below)
wire spiflash_rstrb = clk_enable && isSPIFlash && mem_rstrb && eos;
wire [31:0] SPIFlash_rdata; // this module's answer to a read, muxed into mem_rdata below
wire        spiflash_rbusy; // high for the whole SPI transaction; drives mem_rbusy below
wire        spiflash_clk;   // this module's own SPI CLK output; only reaches the real pin
                            // via STARTUPE2's USRCCLKO (see "SPI flash CCLK access" below)
```

```text
SPI flash read controller (see SPIFlash.v). word_address takes the
low 22 bits of mem_wordaddr -- 22 bits of word address = 16MB of
byte-addressable flash space, matching both this controller's
cmd_addr packing (8-bit opcode + 22-bit word address + 2 conversion
bits = 32 bits per transaction, see SPIFlash.v) and bit 24 being the
flash-space selector above (see the "Why bit 24, not bit 23" note).
```

### Only flash reads stall the core; read mux

*Signals:* `mem_rbusy`, `mem_rdata`

```text
The Processor only ever stalls for flash reads -- RAM and IO both
already answer within their own fixed one-cycle timing, so this is
simply spiflash_rbusy renamed for what it means at the Processor's
own port.
assign mem_rbusy = spiflash_rbusy;

The single value the Processor actually sees on mem_rdata: RAM's
answer in RAM space, the (currently placeholder) flash answer in
flash space, the IO status word otherwise.
assign mem_rdata = isRAM      ? RAM_rdata :
                    isSPIFlash ? SPIFlash_rdata :
                                 IO_rdata;
```

### LED register: reset not gated by the clock enable

*Signals:* `LEDS`

```text
-------------------------------------------------------------------------
LEDS register
-------------------------------------------------------------------------
LEDS is real state (a reg), latched on demand -- not just wires tied
to some Processor-internal signal. Reset (not gated by clk_enable, so
it always takes effect on the very next edge) clears it; otherwise it
only changes when the Processor stores to the LEDS address.
```

### RAM strobes masked outside RAM space

*Signals:* `RAM.mem_rstrb`, `RAM.mem_wmask`

```text
Program + data RAM (see Memory.v). mem_rstrb and mem_wmask are both
gated by isRAM, so this module only ever reacts to RAM-space accesses
-- an IO-space read or write must never also disturb RAM. The
replication {4{isRAM}} turns the single isRAM bit into a 4-bit mask,
forcing every byte off when the access isn't RAM's.
```

### UART reset polarity

*Signals:* `UART.i_rst`

```text
UART transmitter (see emitter_uart.v). clk_freq_hz must match CLK's
actual frequency so it can derive the right bit period for its baud
rate. i_rst wants active-HIGH, hence the '!' on resetn -- every other
reset signal in this design is active-low, this is the one exception.
```

### Simulation-only IO trace (removed, nothing defined BENCH)

*Signals:* `` `ifdef BENCH `` block, `SLOW_BITS`

```text
Simulation-only trace (this whole block is compiled out for real
synthesis): prints every IO-space write, and separately decodes UART
bytes as characters, so you can watch what the program is doing in
iverilog without a real serial terminal attached.
```

The block printed every IO-space write and each UART byte with `$display`. The regression
testbench observes the pins instead, and no build defined `BENCH`, so the block and the
matching `SLOW_BITS` selection below were dropped:

```text
    // change either value to feed a different divider
    // into Clockworks' clock-enable generator (see clockworks.v) for BENCH
    // vs. real hardware.
    `ifdef BENCH
    localparam integer SLOW_BITS = 0;
    `else
    localparam integer SLOW_BITS = 0;
    `endif
```

### Genesys 2 differential clock input

*Signals:* `CLK_ibuf`, `CLK`, `sysclk_buffer`, `sysclk_bufg`, `clockworks`

```text
-------------------------------------------------------------------------
Genesys2 clock handling
-------------------------------------------------------------------------
Genesys2's system clock only exists as a differential pair, never as
a single wire, so it has to go through Xilinx's differential input
buffer before anything else can use it.
IBUFDS sysclk_buffer (
    .I(sysclk_p),
    .IB(sysclk_n),
    .O(CLK_ibuf)
);
BUFG (global clock buffer) routes a clock onto one of the FPGA's
dedicated low-skew clock networks, so every flip-flop in the design
sees the same edge at (nearly) the same time. Any clock feeding a
design this size should go through one of these.
```

```text
Clockworks (see clockworks.v) generates:
  clk_enable = a pulse, high once every 2^SLOW_BITS cycles of CLK
  resetn     = active-low reset for the whole design, derived from RESET
```

### SPI flash CCLK access through STARTUPE2

*Signals:* `spiflash_cclk_access`, `spiflash_clk`, `eos`

```text
-------------------------------------------------------------------------
SPI flash CCLK access (7-series-specific)
-------------------------------------------------------------------------
Genesys2's onboard configuration flash is what boots this very bitstream
at power-on. Reading it again LATER, from user logic, needs a way to
drive its CLK line -- but on 7-series Xilinx parts that physical pin
(CCLK) is not a normal I/O pin like LEDS or UART. Xilinx's own
documentation (UG470, the 7 Series Configuration User Guide) classifies
CCLK as "Dedicated" -- reserved for the configuration process itself --
in explicit contrast to the flash's other pins (CS_N, D0-D3), which are
"Multi-function": reserved only DURING configuration, then "released
for general use" once it completes. That's why spiflash_csn/mosi/miso
(declared in the port list above, wired to ordinary XDC pin constraints)
work like any other port on this design, while CLK needs a completely
different mechanism: a Xilinx-provided primitive called STARTUPE2,
instantiated below, that hands user logic a way to drive CCLK
post-configuration.

STARTUPE2 is a real, built-in Xilinx primitive -- part of the 7-series
hardware itself, the same category of thing as IBUFDS/BUFG just above.
"spiflash_cclk_access" (the name right before the port list below) is
NOT that built-in thing -- it is only this particular INSTANCE's name,
chosen the exact same way "sysclk_buffer" above is only the name of
this design's one IBUFDS instance, not a name Xilinx defines. Every
port name used below (USRCCLKO, EOS, ...) is fixed by Xilinx; only the
instance name and the wires connected to it are this project's own.

Port-by-port:
  USRCCLKO   the actual clock waveform to drive onto the real CCLK pin.
             Driven by spiflash_clk -- SPIFlash.v's own CLK output
             (see the "spiflash" instantiation up in the
             "Memory-mapped IO" section above). That module already
             holds this idle-low whenever it isn't mid-transaction
             (CS_N high), so there's nothing extra to gate here.
  USRCCLKTS  active-high tri-state control for CCLK. Held at 0 (never
             tri-stated) so USRCCLKO's value is always actually driven
             onto the pin -- CCLK defaults to high-Z after
             configuration finishes, so this has to be told explicitly
             to stay driven.
  EOS        "End of Startup" -- goes high once the FPGA has fully
             finished configuring itself from flash and is ready for
             normal operation. Captured here as the wire "eos" for a
             later phase to use: the SPI flash controller must not
             start clocking the flash before this goes high. (It
             wouldn't have any effect even if it tried -- before EOS,
             the configuration engine itself still owns CCLK and
             ignores USRCCLKO entirely, so there is no way to glitch
             the boot sequence by getting this timing wrong.)
  CLK/GSR/GTS/KEYCLEARB/PACK/USRDONEO/USRDONETS/CFGCLK/CFGMCLK/PREQ
             not relevant to this design; left at their standard safe
             defaults (mostly tied off or left unconnected).
```

Inline on the ports:

```text
        .USRCCLKO(spiflash_clk), // SPIFlash.v's own CLK output -- see "spiflash" instantiation
                                 // above
        .USRCCLKTS(1'b0),        // keep CCLK actively driven, never tri-stated
```

## Processor (`rtl/Processor.v`)

The core is split into `rtl/Decoder.v`, `rtl/ALU.v`, `rtl/RegisterFile.v` and
`rtl/Control.v`. Signal names are those of the time: `PC` is now `pc`, `RegisterBank` is
`regs` in the register file, `writeBackEn` is `write_rd` and `isXxx` flags are `is_xxx`.

### Why the reset vector is a parameter, and why a jump at address 0 is not enough

*Signals:* `RESET_PC`

```text
RESET_PC -- where the CPU starts executing after reset
-------------------------------------------------------------------------
Default 0 = boot from BRAM (the original behaviour: the
program lives in Memory.v, loaded there by $readmemh at configuration
time). SOC.v overrides this with an address in SPI-flash space to
boot from flash instead, which is what allows programs
much larger than the 6KB of BRAM.

WHY THIS IS A PARAMETER RATHER THAN A HARDCODED CONSTANT: it is the
single switch between the two boot modes. Flip it in SOC.v (see
BOOT_ADDR there) and nothing else in this file has to change.

WHY IT IS NOT ENOUGH TO JUST PUT A JUMP AT RAM ADDRESS 0 (the obvious
first idea): that jump only
exists because it was part of BRAM's *initial* contents. BRAM is also
where the stack lives, growing down from 0x1800 towards 0. Once a
program has been running a while, whatever is at address 0 is very
likely to be stack leftovers, not the jump any more -- so pressing the
physical reset button would set PC=0 and execute garbage. Making the
reset vector a property of this hardware instead makes reset always
land somewhere real, no matter what RAM currently holds.
```

### Only SPI flash raises mem_rbusy

*Signals:* `mem_rbusy`

```text
    input  wire        mem_rbusy   // High while a read is still in flight and mem_rdata
is not valid yet. RAM and memory-mapped IO both
answer in exactly one cycle, so this is always low
for them; only SPI flash reads (see SPIFlash.v /
SOC.v) hold it high, for as many cycles as their
multi-bit SPI shift takes. See WAIT_INSTR/WAIT_DATA
below for where this actually stalls the FSM.
```

### ADD versus SUB: funct7[5] alone is not enough

*Signals:* `aluOut`, `funct7`, `instr[5]`

```text
ADD and SUB share funct3=000; funct7[5] tells them apart, but
only for ALUreg -- there is no SUBI, so instr[5] (1 for ALUreg,
0 for ALUimm) has to be ANDed in as well, otherwise an ADDI
whose funct7-shaped bits happen to be set would be misread as SUB.
```

### SRL versus SRA, as the comment described it

*Signals:* `aluOut`, `shamt`, `result`, `sra`

The comment below describes the intent. The expression it sat next to,
`funct7[5] ? ($signed(aluIn1) >>> shamt) : (aluIn1 >> shamt)`, shifted logically in both
arms: the unsigned else-arm makes the whole conditional unsigned, and that context reaches
the `$signed` operand of `>>>` (issue #10, see `docs/baseline.md`).

```text
SRL and SRA also share one funct3 (101), split by funct7[5].
$signed(aluIn1) makes Verilog's >>> perform an arithmetic
(sign-extending) shift instead of a plain logical one -- that
sign-extension is exactly what SRA needs and SRL must not have.
```

`rtl/ALU.v` first kept the expression unchanged, so that the golden trace captured from it
still matched, with this comment:

```text
Kept as written: the unsigned else-arm makes the whole expression
unsigned, so >>> shifts logically. The golden trace depends on it.
```

Both arms now shift `$signed(in1)`; the logical arm is unaffected, because `>>` fills with
zeros whatever the signedness. `sim/ALUBench.v` checks SRA, SRAI, SRL and SRLI on
negative operands, and the golden trace was re-captured with the fix.

### Why jalr_target is a named wire

*Signals:* `jalr_target`, `nextPC`

```text
jalr_target is given its own name, rather than inlining rs1+Iimm
below, because Verilog does not allow bit-selecting a parenthesized
expression directly -- {(rs1+Iimm)[31:1], 1'b0} is not legal syntax,
but slicing a named wire like this is.
```

### Branch comparator default arm

*Signals:* `takeBranch`

```text
funct3 has 8 possible values but only 6 are valid branches; the
other 2 never occur for isBranch, but a combinational always
block still needs every case covered, or the synthesizer has to
infer a latch (extra state to "remember" the last value) instead
of plain logic for the missing cases. default keeps this
purely combinational.
```

### Why one instruction takes several cycles

*Signals:* `state`, `FETCH_INSTR` .. `STORE`

```text
One instruction takes several clock cycles because Memory answers a
read one cycle after it is requested, and because latching two
registers out of the (synchronous) register file needs its own cycle
too:
  FETCH_INSTR : drive mem_addr = PC, request a read
  WAIT_INSTR  : latch the instruction word Memory now returns
  FETCH_REGS  : latch rs1/rs2 from the register file
  EXECUTE     : run the ALU/branch/jump logic and update PC; for
                every instruction except Load/Store, this is also the
                last cycle (writeBackEn fires here)
  LOAD        : drive mem_addr = loadstore_addr, request a read
  WAIT_DATA   : latch the loaded, aligned/sign-extended value into rd
  STORE       : drive mem_addr/mem_wdata/mem_wmask; Memory performs
                the write on this same clock edge
```

### Power-on state matches the reset state

*Signals:* `state`

```text
Power-on value matches the reset value below (WAIT_DATA, not
FETCH_INSTR) so that mem_rstrb is low from the very first clock edge --
see the reset block for the full reasoning.
```

### Store data is broadcast to every lane; the mask selects

*Signals:* `mem_wdata`, `STORE_wmask`

```text
rs2's value, replicated into every byte lane it could possibly need
to land in. STORE_wmask (below) is what actually decides which
lane(s) Memory writes, so it is fine to broadcast rs2 everywhere here
and let the mask sort it out -- simpler than muxing mem_wdata itself
by access width.
```

### Write-back enable gated by mem_rbusy in WAIT_DATA

*Signals:* `writeBackEn`

```text
rd is written during EXECUTE for every instruction that produces a
result immediately (everything except Branch/Store, which write
nothing, and Load, whose data is not ready until WAIT_DATA).
WAIT_DATA's own clause is additionally gated by !mem_rbusy: without
it, a multi-cycle SPI flash load would fire writeBackEn -- and latch
whatever garbage mem_rdata currently holds -- on every single stalled
cycle in WAIT_DATA, not just the final one. Harmless in the end
result (the last, valid write always overwrites the earlier bogus
ones before anything reads rd), but sloppy and misleading in the
BENCH trace below. RAM/IO loads are unaffected: mem_rbusy is already
low the very first cycle they reach WAIT_DATA.
```

### Synchronous reset and the clock enable

*Signals:* `resetn`, `clk_enable`, `writeBackEn`

```text
Reset is synchronous: on the clock edge where resetn is low, PC/state/
instr go back to their power-on values (nothing else needs clearing --
FETCH_INSTR with PC=0 guarantees the first real instruction is fetched
before anything ever reads a register). While running, clk_enable
gates this whole block: with clk_enable low, the processor simply
holds whatever state it was already in for another cycle.

Register write-back is checked here on every cycle regardless of
state, but writeBackEn only actually goes high during the one state
-- EXECUTE or WAIT_DATA -- where a given instruction is ready to
produce its result, so in practice a register is written at most
once per instruction.
```

### Reset lands in WAIT_DATA, not FETCH_INSTR

*Signals:* `state`, `mem_rstrb`, `spiflash_rstrb`

```text
PC goes to RESET_PC (see the parameter at the top of this file):
0 for BRAM boot, an SPI-flash address for flash boot.

state goes to WAIT_DATA rather than FETCH_INSTR, and that choice
is load-bearing, not cosmetic. mem_rstrb (bottom of this file) is
high for the WHOLE time state == FETCH_INSTR. Since reset is held
for many cycles, resetting into FETCH_INSTR would hold mem_rstrb
high for all of them -- and with PC in flash space, SOC.v turns
that into a spiflash_rstrb pulse EVERY cycle. SPIFlash.v restarts
its transaction on each pulse (reloading cmd_addr, re-arming the
bit counter) while never releasing CS_N, so the flash chip would
see chip-select held low with a clock running and MOSI stuck --
i.e. a garbage command it never gets to finish, with no
deselect in between to resynchronise its command parser.

WAIT_DATA asserts no strobe at all, so the flash stays idle and
deselected throughout reset. The instant reset releases,
WAIT_DATA sees mem_rbusy low and falls through to FETCH_INSTR,
which issues exactly one clean rstrb pulse. Costs one extra
cycle at boot; buys a correctly-framed first flash transaction.

Note WAIT_DATA also asserts writeBackEn. That is harmless here:
instr is reset to NOP_CODEOP, whose rd field is x0, and the
write-back below is guarded by `rdId != 5'd0`.

This is equally correct for BRAM boot (RAM never asserts
mem_rbusy, so WAIT_DATA falls straight through) -- which is why
it is unconditional rather than tied to the boot mode.
```

### Instruction fetch stalls on mem_rbusy

*Signals:* `WAIT_INSTR`, `instr`

```text
Memory/IO have had time to place the requested word on
mem_rdata by now -- but SPI flash hasn't necessarily
finished yet (see mem_rbusy above). Hold this state,
leaving instr untouched, for as long as mem_rbusy stays
high; only latch mem_rdata and advance once it drops.
For RAM/IO, mem_rbusy is already low the very first
time we get here, so this behaves exactly as before.
```

### x0 reads as zero explicitly

*Signals:* `RegisterBank`, `rs1`, `rs2`

```text
32 general-purpose registers. x0 is architecturally hard-wired to zero:
nothing here ever writes RegisterBank[0] (guarded below), and reads of
x0 are separately forced to 0 in FETCH_REGS rather than relying on that.

x0 always reads as 0 here, rather than relying on it
simply never having been written -- makes the
guarantee explicit instead of assumed.
```

### STORE needs no wait state

*Signals:* `STORE`, `mem_wmask`

```text
In this state:
  mem_addr  = loadstore_addr
  mem_wdata = aligned rs2 data
  mem_wmask = STORE_wmask

Memory writes the selected bytes on this clock edge.
Unlike LOAD, there's no round trip to wait for here:
a write has no answer for the processor to consume, so
as soon as this edge passes the write has already
happened -- state can go straight to FETCH_INSTR
instead of through a WAIT_DATA-style extra state.
```

### Load stalls on mem_rbusy

*Signals:* `WAIT_DATA`, `LOAD_data`

```text
Same mem_rbusy stall as WAIT_INSTR above -- a LW from
SPI flash space needs many cycles here; RAM/IO loads
still resolve in exactly one, same as before this was
added. Once mem_rbusy drops, mem_rdata holds the
loaded word, and writeBackEn (below) fires on this
same cycle to write LOAD_data to rd.
```

### EBREAK halts the PC

*Signals:* `EXECUTE`, `isSYSTEM`, `PC`

```text
Branch/jump targets are already resolved in nextPC
above; SYSTEM (EBREAK) leaves PC untouched, since this
simple core has nowhere meaningful to continue to.

EBREAK just stops the simulator; real hardware has
no equivalent here and would sit at this PC forever.
```

### Simulation-only register trace (removed, nothing defined BENCH)

*Signals:* `` `ifdef BENCH `` blocks, `RegisterBank`, `writeBackData`

Three blocks compiled only under `BENCH`: an `initial` loop clearing `RegisterBank` so the
trace never printed `x`, a `$display` of every register write, and a per-instruction
decode line printed in `FETCH_REGS`. The regression testbench observes the pins, and no
build defined `BENCH`, so the blocks were dropped. The `$finish` on EBREAK went with them;
in hardware the core sits at that PC forever.

```text
clear the register file at time 0 so the decode
trace below never prints an uninitialized ('x) value
```

## SPIFlash (`rtl/SPIFlash.v`)

The two "original wording" entries below are earlier versions of the notes that follow
them and overlap with them.

### Origin of the module

*Signals:* module header

```text
Adapted from Bruno Levy's spi_flash.v (SPI_FLASH_READ variant, the
simplest of the four variants that file offers), but with a genuinely
different clock-generation scheme -- see the "Divide 200MHz..." comment
below for exactly why that couldn't just be reused as-is.
```

### Why the SPI clock is divided (original wording)

*Signals:* `div`, `sclk`

```text
Why this exists at all: Divide 200MHz down to ~33.3MHz (one SPI clock
period = 6 system clock cycles) for the flash's SPI bus. Verified
directly against Infineon's S25FL256S datasheet (the actual chip on
this board -- downloaded and read the real PDF rather than trusting
secondhand claims): Table 6.5 states "FSCK,R -- SCK Clock Frequency
for READ, 4READ instructions -- 50 MHz" as the maximum for this exact
command (0x03, the plain, no-dummy-cycles read this module uses).
This design's system clock is 200MHz, un-divided -- 4x over that
limit -- so simply feeding clk straight through as the SPI clock (as
the IceStick-era version of this module does, since
IceStick-class boards run far slower) would drive the flash chip out
of its documented spec. Dividing by 6 lands at ~33.3MHz, about 33%
of margin below the documented 50MHz ceiling.
```

### Why word_address is 22 bits (original wording)

*Signals:* `cmd_addr`, `word_address`

```text
That is exactly 8+22+2 = 32 bits -- one full cmd_addr's worth, and
uses the FULL 24-bit address field the flash chip's 03h command
supports (2^24 = 16MB reachable) rather than artificially padding the
top 2 bits to 0. That padding existed in an earlier version of this
file (word_address was only 20 bits then, reaching just 4MB) --
ported directly from Bruno Levy's own IceStick-era module, whose
target flash chip never needed more than that. It had to be widened
here: our own 32MB S25FL256S holds this design's own bitstream at
the start of the chip, and that bitstream is 11,443,728 bytes
(~10.9MB) -- a fixed size for the xc7k325t part, since uncompressed
7-series bitstreams contain every configuration frame regardless of
how much logic the design actually uses, so it does NOT grow as this
project adds modules. 4MB of reach isn't enough room to place
anything past an ~11MB bitstream. Verified this was a real, live
bug (not a theoretical one) by
computing the actual byte address a real intended offset resolved to
under the old 20-bit version: it silently wrapped around to address
0 -- the very start of the chip, i.e. it would have read this
project's OWN bitstream bytes back as if they were user data.
```

### Purpose and the SPI Mode 0 protocol

*Signals:* module header

```text
Lets the CPU read words out of the Genesys2 board's onboard QSPI
configuration flash (a Cypress/Infineon S25FL256S, 32MB) as if it were
ordinary memory -- see IOBus.v's is_spiflash address decode, which is
what actually routes a Load instruction to this module instead of to RAM.

-----------------------------------------------------------------------------
SPI protocol crash course, as used here (this is "SPI Mode 0")
-----------------------------------------------------------------------------
SPI is a 4-wire bus: CLK (clock, driven by us, the "master"), CS_N (chip
select, active-low, driven by us), MOSI ("Master Out Slave In" -- we drive
it, the flash reads it), and MISO ("Master In Slave Out" -- the flash
drives it, we read it). Nothing happens on the bus unless CS_N is low;
that is what tells the flash chip "pay attention, the next bits are for
you." Mode 0 specifically means: CLK idles low, the flash samples MOSI on
CLK's RISING edge, and drives MISO to its next value shortly after CLK's
FALLING edge (so it is stable well before the next rising edge). We do
the mirror image: we present a new MOSI bit near a falling edge, and we
sample MISO near a rising edge.

A "Read" transaction on this flash chip is: hold CS_N low, clock out one
command byte (0x03 = "Read Data") immediately followed by a 3-byte (24
bit) address -- 32 bits sent altogether -- then, without releasing CS_N,
keep clocking and the flash starts shifting the requested data out on
MISO, byte after byte, for as long as CS_N stays low. This module always
asks for exactly one 32-bit word (4 bytes) then releases CS_N.
```

### Port notes

*Signals:* `rstrb`, `word_address`, `rdata`, `rbusy`, `CLK`, `CS_N`

```text
module SPIFlash(
    input  wire        clk,          // system clock (200MHz on this board -- see
                                      // the clock divider below for why that matters)
    input  wire        rstrb,        // pulse high for exactly 1 cycle to start a
                                      // read (this is IOBus.v's spiflash_rstrb,
                                      // itself derived from the Processor's own
                                      // mem_rstrb -- see IOBus.v for that wiring)
    input  wire [21:0] word_address, // which 32-bit word to read, as a WORD index
                                      // (not a byte address) -- IOBus.v passes
                                      // mem_addr[23:2], i.e. mem_addr>>2.
                                      // 22 bits here = a 24-bit (16MB) byte
                                      // range once *4 -- see the bit-packing
                                      // note below for why it's exactly 22,
                                      // not some other width.
    output wire [31:0] rdata,        // the word read back. Only meaningful once
                                      // rbusy has dropped back to 0 -- while a
                                      // transaction is in flight this is mid-shift
                                      // garbage, same as mem_rdata generally is
                                      // before a load completes elsewhere in this
                                      // design
    output wire        rbusy,        // high for the ENTIRE transaction -- from the
                                      // cycle rstrb is seen until the 4th received
                                      // byte lands. This is what IOBus.v wires to
                                      // the Processor's mem_rbusy input, which is
                                      // what actually makes the CPU sit still in
                                      // WAIT_INSTR/WAIT_DATA for as long as this
                                      // stays high, instead of reading rdata before
                                      // it is ready (see Processor.v)

    // ---- the four physical SPI wires (see the protocol crash course above) ----
    output wire        CLK,          // clock we generate for the flash. This does
                                      // NOT go straight to a chip pin -- on this
                                      // 7-series FPGA, the physical CCLK pin can
                                      // only be driven post-configuration through
                                      // Xilinx's STARTUPE2 primitive; see the
                                      // STARTUPE2 instantiation in SOC.v for
                                      // where this signal actually goes.
    output reg         CS_N,         // chip-select, active-low: 0 = flash is
                                      // listening, 1 = flash ignores everything
                                      // (idle). A plain reg (not assign'd from
                                      // combinational logic) because it needs to
                                      // hold its value across many cycles of one
                                      // transaction -- see the two always blocks
                                      // below, both of which drive it.
    output wire        MOSI,         // our command+address bits, one at a time
    input  wire        MISO          // the flash's data bits, one at a time
);
```

### How the divide-by-6 works

*Signals:* `div`, `sclk`

```text
How the division actually works: div is a free counter that repeats
0,1,2,0,1,2,... (three system-clock cycles per count); every time it
wraps back to 0 (i.e. every 3rd cycle), sclk flips. Flipping every 3
cycles means sclk's own full period (one low phase + one high phase)
is 6 system-clock cycles long -- 6 x 5ns = 30ns = 33.3MHz. sclk itself
is NOT the final SPI clock output (see the "assign CLK" line below) --
it is just the raw, always-ticking waveform this module's timing is
built around.
```

### Explicit initial values on div and sclk (simulation hang)

*Signals:* `div`, `sclk`

```text
reg [1:0] div = 2'd0;   // note the explicit "= 2'd0" initial value: without
reg       sclk = 1'b0;  // it, both regs start as Verilog's default 'X' in
                         // simulation, and X+1 is still X forever, so the
                         // divider would never start counting at all. This
                         // is invisible on real silicon (which always powers
                         // up to some concrete 0/1, never a true "unknown"),
                         // but caught this exact bug via simulation -- the
                         // whole testbench simply hung -- before shipping it,
                         // and it is bad practice to rely on unstated
                         // power-on behavior regardless.
```

### Edge pulses instead of levels

*Signals:* `sclk_rise`, `sclk_fall`

```text
sclk_rise/sclk_fall each pulse for exactly the one system-clock cycle
where sclk is ABOUT to flip -- i.e. "this cycle is the moment of a
rising/falling edge", not "sclk is currently high/low". These are what
the shift-register logic further down actually synchronizes to,
instead of watching sclk's level directly.
```

### Divider held in reset while idle (short first pulse)

*Signals:* `div`, `sclk`, `CS_N`

```text
Idle: hold the divider at reset so the very first pulse of
the next transaction is always a full, clean period.

Why this matters: without it, the divider would be free-
running all the time, including while idle -- so at the
exact moment CS_N drops (a transaction starting), div/sclk
could be caught mid-count, at some arbitrary phase. That
would hand the flash chip a FIRST clock pulse shorter than
the other 63 -- possibly violating the flash's own minimum
pulse-width timing. Caught this exact bug during simulation
(a stray ~20ns pulse instead of the expected steady 30ns)
before fixing it with this idle-reset. Resetting here, keyed
off CS_N rather than off rstrb specifically, is what
guarantees this: the moment CS_N is next asserted (in the
second always block below), this block sees CS_N already
high on THIS cycle (both blocks read the pre-update value of
CS_N on the cycle it changes), so div/sclk are still held at
0 through that transition, and only start counting cleanly
from the following cycle onward.
```

### CLK forced low while idle

*Signals:* `CLK`

```text
The actual signal that (eventually, via STARTUPE2) reaches the real
CCLK pin: sclk while a transaction is active, forced low while idle.
Forcing it low here (rather than relying on sclk already being 0 at
that point) is what makes "idle-low" true even for the handful of
cycles between CS_N first dropping and the divider producing its
first real edge -- SPI Mode 0 requires the clock to be low before the
first rising edge, not merely eventually.
```

### Command packing

*Signals:* `cmd_addr`

```text
cmd_addr packs the outgoing command exactly the way the flash chip's
Read instruction expects it, MSB (bit 31) first:

    bits [31:24]  8'h03           the "Read Data" opcode
    bits [23: 2]  word_address    the word we want, all 22 bits of it
    bits [ 1: 0]  2'b00           these 2 bits convert a WORD address
                                  into a BYTE address -- the flash
                                  addresses individual bytes, and a
                                  word is 4 bytes, so its byte address
                                  is always word_address*4, i.e.
                                  word_address followed by two zero
                                  bits (see the "cmd_addr <=" line in
                                  the always block below)
```

### Bookkeeping wires, rbusy and MOSI

*Signals:* `sending`, `receiving`, `busy`, `rbusy`, `MOSI`

```text
// sending/receiving/busy are pure bookkeeping derived from the two
// countdown counters above -- neither is ever written directly, they
// just reflect "is there still work left in this phase".
wire       sending   = (snd_bitcount != 0);
wire       receiving = (rcv_bitcount != 0);
wire       busy      = sending | receiving;

// rbusy is just !CS_N -- CS_N is only ever low while a transaction (of
// either phase) is actually in progress, so this is a cheap, always-
// correct proxy without needing its own separate bookkeeping.
assign     rbusy     = !CS_N;

// MOSI is always simply "whatever the top bit of cmd_addr currently
// is" -- there is no separate "current output bit" register, because
// cmd_addr IS being shifted (see "cmd_addr <= {cmd_addr[30:0], 1'b1}"
// below) one bit closer to fully-sent every time a bit goes out, so its
// own top bit is always exactly the next bit that needs to appear on
// the wire.
assign     MOSI      = cmd_addr[31];
```

### Byte order of the received word

*Signals:* `rcv_data`, `rdata`

```text
The flash sends the 4 response bytes MSB-first, in increasing-address
order: the very first bit received is bit 7 of the byte at the
requested address, and the very last bit received is bit 0 of the
byte at (requested address + 3). After all 32 bits land in rcv_data
via left-shifting (see "rcv_data <= {rcv_data[30:0], MISO}" below),
rcv_data therefore holds, from its own MSB to LSB: byte0, byte1,
byte2, byte3 (the bytes at increasing flash addresses, in that
order) -- i.e. rcv_data[31:24]=byte0, rcv_data[7:0]=byte3.

RISC-V is little-endian: for a 32-bit value spread across 4
consecutive addresses, software expects the LOWEST address's byte to
be the LEAST significant byte of the resulting word (word[7:0] =
byte at address+0). rcv_data has it backwards from that (its MOST
significant byte is byte0), so this reverses the byte order --
NOTHING inside each byte is reversed, only which byte lands in which
byte-lane of the final word:
    rdata[ 7: 0] = rcv_data[31:24]  (byte0, the lowest address -> LSB)
    rdata[15: 8] = rcv_data[23:16]  (byte1)
    rdata[23:16] = rcv_data[15: 8]  (byte2)
    rdata[31:24] = rcv_data[ 7: 0]  (byte3, the highest address -> MSB)
Concrete example: bytes 0xAA,0xBB,0xCC,0xDD sitting at consecutive
flash addresses +0,+1,+2,+3 arrive in rcv_data as 32'hAABBCCDD, and
this line turns that into rdata = 32'hDDCCBBAA -- confirmed against
exactly this scenario in simulation before trusting it.
```

### The transaction state machine

*Signals:* `sending`, `receiving`, `sclk_fall`, `sclk_rise`

```text
Unlike Processor.v's FSM, this isn't a named-state case statement --
it is driven entirely by the sending/receiving/busy wires above, plus
whether this is the cycle a real SPI edge is happening (sclk_fall for
things we should do BEFORE the flash next samples MOSI on a rising
edge; sclk_rise for things we should do to capture what the flash put
on MISO around its own falling edge) -- i.e. it directly follows the
SPI Mode 0 timing described at the top of this file, just spread
across a divided clock instead of the system clock directly.
```

### Starting a transaction is not gated by the SPI edge

*Signals:* `rstrb`, `CS_N`

```text
Kick off a brand new transaction. This branch is NOT gated by
sclk_fall/sclk_rise -- it can happen on any system-clock
cycle, so that it never misses a 1-cycle rstrb pulse from the
Processor regardless of which phase the free-running divider
happens to be in. (Nothing else can be mid-transaction at
this point anyway: the Processor only ever issues rstrb after
the PREVIOUS transaction's rbusy has already dropped, so
there's no risk of interrupting one read with another.)
```

### Arming the receive counter on the last command bit; the trailing 1

*Signals:* `snd_bitcount`, `rcv_bitcount`, `cmd_addr`

```text
// Right before the flash's next sampling edge (its next
// rising edge, which follows this falling edge): if this is
// the LAST bit of the command about to go out, arm the
// receive counter now, so that the very next SPI period
// seamlessly becomes the first bit of the response -- no
// gap cycle needed between "done sending" and "start
// receiving".
if (snd_bitcount == 1) rcv_bitcount <= 6'd32;
snd_bitcount <= snd_bitcount - 6'd1;
// Shift cmd_addr one bit to the left, discarding the bit
// that was just placed on MOSI (cmd_addr[31]) and dropping
// in a 1 at the bottom -- that trailing 1 never actually
// gets sent (snd_bitcount reaches 0 before it would be
// MOSI's turn), its value genuinely does not matter.
```

### Sampling MISO

*Signals:* `rcv_data`

```text
Right at the flash's own sampling-equivalent moment (this
module's rising edge, matching when the flash's MISO bit
-- driven around ITS preceding falling edge -- is stable
and ready to read): shift MISO into the bottom of
rcv_data, sliding everything already captured one bit to
the left.
```

### End of transaction

*Signals:* `busy`, `CS_N`

```text
The moment neither phase has any bits left (busy drops to 0),
release CS_N. This check runs every cycle regardless of
sclk_fall/sclk_rise -- there's no reason to wait for a
particular SPI edge just to deselect the chip, so it reacts
as soon as possible instead of adding an extra period of
latency.
```

## Clockworks (`rtl/Clockworks.v`, formerly `rtl/clockworks.v`)

The header now carries the upstream attribution lines plus a two-line summary; ports
`CLK`/`RESET`/`resetn` became `clk`/`reset_button_n`/`reset_n`. The explanation of
`generate` was syntax and was dropped without record.


### Original project header

*Signals:* `clk_enable`, `resetn`, `SLOW`

```text
Clockworks turns the board's raw clock/reset into what the rest of the
design actually uses:
  - clk_enable: a "gearbox" pulse, high once every 2^SLOW cycles of CLK.
    Every clocked block elsewhere in this project is gated by this
    signal, so setting SLOW>0 lets you slow the whole design down enough
    to watch it operate one logical step at a time (e.g. on LEDs).
  - resetn: this design's active-low reset, forwarded from RESET.

Genesys 2 notes
  - This module assumes CLK is already a normal single-ended clock.
    On Genesys 2, the system clock is differential, so use IBUFDS
    in the top module before connecting to Clockworks.
  - The red CPU RESET button on Genesys 2 is already active-low:
      not pressed -> RESET = 1
      pressed     -> RESET = 0
    so, unlike boards where RESET needs inverting or synchronizing on
    startup, resetn here is just RESET forwarded straight through.

Parameters
    SLOW: number of bits of the gearbox counter. clk_enable pulses
      approximately every (1 << SLOW) cycles of CLK; SLOW=0 disables the
      divider entirely (clk_enable stays high every cycle).
```

### Gearbox counter

*Signals:* `div`, `tick`

```text
div is a free-running SLOW-bit counter; tick is registered high
for exactly one cycle out of every 2^SLOW, whenever div was at
its maximum value on the previous edge -- that pulse becomes
clk_enable below.
```

## UartTx (`rtl/UartTx.v`, formerly `rtl/emitter_uart.v`)

Comments trimmed with the naming sweep; the module was renamed from
`corescore_emitter_uart` and its ports from `i_clk`/`i_rst`/`i_data`/`i_valid`/`o_ready`/
`o_uart_tx` to `clk`/`reset_n`/`data`/`valid`/`ready`/`tx`, and the reset became
active-low like every other reset in the design.

### Frame format and interface

*Signals:* module header

```text
Simple UART transmitter
-----------------------------------------------------------------------------
This module sends one byte over a UART TX line.

UART frame format:

    idle  start  data bits                 stop
      1     0    bit0 bit1 ... bit7          1

So every byte is transmitted as 10 serial bits:

    1 start bit
    8 data bits, least-significant bit first
    1 stop bit

Interface:

    i_data      byte to transmit
    i_valid     pulse high when i_data should be sent
    o_ready     high when UART can accept a new byte
    o_uart_tx   serial UART output line
```

### Which pin the transmitter drives

*Signals:* `o_uart_tx`

```text
output reg        o_uart_tx    // UART TX output line -- leaves the FPGA here. On the
                                // Genesys2, this pin goes to an onboard FTDI FT232RQ
                                // (a USB-to-UART bridge chip), which is what actually
                                // shows up as a virtual COM port on the host PC.
                                //
                                // "TX" here is from the FPGA's own point of view: this
                                // module transmits on it. Careful when wiring it up in
                                // SOC.v -- the board's two UART signal names are built
                                // from two different vantage points ("TX"/"RX" from the
                                // PC's side, "_in"/"_out" from the FPGA's side), so this
                                // output belongs on uart_rx_out (the PC's RX line, an
                                // FPGA output), NOT on the similarly-spelled uart_tx_in,
                                // which is an FPGA input driven by the FT232RQ. See the
                                // extended note in SOC.v's port list.
```

### Cycles per bit and the counter width

*Signals:* `CLKS_PER_BIT`, `CLK_CNT_WIDTH`

```text
// Number of FPGA clock cycles per UART bit.
//
// For 200 MHz and 115200 baud:
//
//     CLKS_PER_BIT = 200,000,000 / 115,200 ~= 1736
//
// So each UART bit stays stable for about 1736 clock cycles.
localparam integer CLKS_PER_BIT = clk_freq_hz / baud_rate;

// Width of the counter that counts clock cycles inside one UART bit.
// $clog2(x) is a Verilog system function returning the number of bits
// needed to count up to x-1 (ceiling of log2(x)) -- e.g. $clog2(1736)
// is 11, since 11 bits can count as high as 2047. Computing the width
// this way, instead of hardcoding it, keeps clk_cnt correctly sized
// even if clk_freq_hz/baud_rate change.
localparam integer CLK_CNT_WIDTH = $clog2(CLKS_PER_BIT);
```

### Reset state

*Signals:* `o_ready`, `o_uart_tx`

```text
Reset UART to idle state.
UART line is idle-high.
```

## Memory (`rtl/Memory.v`)

The file once carried a 570-line "HOW TO BUILD firmware.hex" walkthrough written before
`fw/Makefile` existed; the shell transcripts, the Vivado GUI steps and the cheat sheet are
dropped without record (the Makefile and `vivado/create_project.tcl` are the flow now),
the rationale is kept.

### Read and write timing are not symmetric

*Signals:* `mem_rdata`, `mem_wmask`

```text
Single-port synchronous RAM, shared by instruction fetch and Load/Store --
there is no separate instruction memory; Processor.v just happens to
request program words from here during FETCH_INSTR/WAIT_INSTR, and data
words during LOAD/STORE, over the exact same bus.

Reads and writes are NOT symmetric in timing:
  - a read is registered: the word requested this cycle only appears on
    mem_rdata the *next* cycle -- exactly why Processor.v has a dedicated
    WAIT_INSTR/WAIT_DATA state after every read request.
  - a write takes effect on the very same clock edge its address/data/mask
    are presented. There is no answer to wait for, so Processor.v needs no
    extra state after a STORE (see the note by STORE in Processor.v).
```

### Why firmware.hex replaced the Verilog assembler

*Signals:* `$readmemh`

```text
The $readmemh("firmware.hex") call further down is the ONLY link between this
hardware and the software it runs. Everything below explains how that file is
produced, from nothing, using the real GNU RISC-V toolchain. Read this before
touching the software side of the project.

Historical note: earlier versions of this project generated program.hex with
a VERILOG-based assembler (riscv_assembly.v + program_asm.v, run through
iverilog). That still works and those files are still in the project, but the
flow described here replaces it -- the machine code is identical, it just
comes from standard tools instead, which is what makes it possible to compile
C rather than hand-assemble everything.
```

### Why the ELF-to-hex conversion exists; endianness

*Signals:* `$readmemh`, `firmware_words`

```text
A note on why the last conversion step exists at all: ld emits ELF, which is
a structured binary container (headers, section tables, symbols). $readmemh()
wants none of that -- just bare hex numbers as text. firmware_words bridges
the two. It also handles endianness: RISC-V is little-endian, so a word's
low-order byte sits at the low address, but $readmemh reads each token
most-significant-digit-first like a human reads hex. firmware_words emits the
four bytes of each word in reverse order so the value reassembles correctly.
Get this wrong and every instruction fetched is byte-swapped garbage.
```

### Why the apt toolchain, not a prebuilt download

*Signals:* toolchain

```text
    Do NOT use a prebuilt toolchain tarball downloaded by a build script. The
    apt packages above are newer, get security updates, need no PATH edits,
    and produce identical RV32I machine code -- the base integer instruction
    encodings have not changed since the ISA was ratified.
```

### The -DSTANDALONE_FEMTOELF build of firmware_words

*Signals:* `firmware_words`

```text
      -I<dir>                 where to find femto_elf.h, which the .cpp includes
      -DSTANDALONE_FEMTOELF   femto_elf.c is dual-purpose: normally it is
                              compiled INTO RISC-V firmware (where it blinks
                              LEDs for progress and has no host OS). This
                              define switches it to plain desktop mode --
                              ordinary stdio file reading, LEDS() becomes a
                              no-op. Without it, it will not build here.
```

### The compiler and linker flags, one by one

*Signals:* `fw/Makefile` flags

```text
  -march=rv32i     Generate ONLY base 32-bit integer instructions. This is
                   the exact instruction set Processor.v implements. Leave it
                   off and the compiler will happily emit MUL/DIV (rv32im) or
                   compressed 16-bit instructions (rv32ic) that this CPU
                   cannot decode -- it would fetch them and behave randomly,
                   with no error message anywhere.

  -mabi=ilp32      Calling convention: which registers carry arguments and
                   return values, how the stack is managed. Must match what
                   start.S and the hand-written .S routines assume. ("ilp32"
                   = int/long/pointer are all 32 bits, no hardware floats.)

  -mno-relax       (assembler/compiler) and
  --no-relax       (linker -- note the DOUBLE dash, see the gotcha in sec. 6)
                   Disable "linker relaxation". Relaxation is an optimization
                   where the linker rewrites far calls into shorter gp-relative
                   ones. That would clobber gp -- and in this design gp is
                   permanently reserved as the memory-mapped IO base pointer
                   (0x400000, loaded once by start.S). Relaxation must stay off.

  -nostdlib        (linker) Do not pull in the host C runtime or standard
                   library. There is no operating system here; start.S is the
                   entry point and 6KB of RAM cannot hold a real libc anyway.

  -m elf32lriscv   (linker) Output format: 32-bit little-endian RISC-V.

  -T bram.ld       (linker) Use our memory layout script -- see section 3.

  For C compilation only:
  -O2              Optimize. Worth having: unoptimized RV32I code is bulky,
                   and 6KB fills up fast.
  -fno-pic         No position-independent code. The program is linked to run
                   at a fixed address (0), so PIC's indirection is pure waste.
  -fno-stack-protector  No stack-guard instrumentation -- it would call into
                   libc support functions that do not exist here.
  -w               Silence warnings (the example C files are old
                   and noisy under modern gcc; the code itself is fine).
```

### bram.ld line by line; the /DISCARD/ workaround

*Signals:* `fw/bram.ld`

```text
Line by line:
  ORIGIN = 0x0000     Processor.v resets PC to 0, so code must start at 0.
  LENGTH = 0x1800     6144 bytes = exactly MEM[0:1535] below. If these two
                      ever disagree, the linker will happily produce a program
                      that overruns this RAM, and firmware_words will refuse
                      it (see its "Memory exceeded!" check).
  start.o (.text)     Force start.o's code to be placed FIRST, so that
                      address 0 -- where the CPU begins executing -- is
                      start.S's entry point and not some random function.
                      Note this also pulls start.o into the link automatically:
                      it does NOT need to be listed on the ld command line.
  *(.*)               Then everything else from every other object file.

  /DISCARD/ ...       IMPORTANT, and NOT in the original version.
                      Modern binutils (2.42, what is installed here) auto-adds
                      a .riscv.attributes metadata section to every object
                      file; the original was written against a ~2019 toolchain
                      that did not. Because *(.*) means "take EVERY section",
                      that metadata gets laid down in RAM *interleaved between
                      your functions*, where the CPU may run straight into it
                      and execute ASCII text as instructions. /DISCARD/ throws
                      it away before *(.*) can see it. (.comment is another
                      such auto-added section, discarded defensively.)
                      Symptom if omitted: firmware_words reports roughly
                      double the expected code size, and objdump -D shows
                      stretches of nonsense like ".insn 2, 0x1941" between
                      real functions.
```

The same catch-all also loads debug data, not discarded today. Ubuntu's `libgcc.a`
(`/usr/lib/gcc/riscv64-unknown-elf/13.2.0/rv32i/ilp32/`) carries DWARF sections in its members,
and `*(.*)` places those of `muldi3.o` and `div.o` (`.debug_line`, `.debug_info`,
`.debug_abbrev`, `.debug_aranges`, `.debug_str`, `.debug_line_str`) in RAM right after their
code. In mandelbrot's BRAM image that is 576 bytes after `__mulsi3` and 508 after `__modsi3`:
1084 of the image's 3408 bytes, never fetched, so the program runs the same, but taken from the
room the stack grows into. Adding `*(.debug*)` to `/DISCARD/` gives a 2324-byte image, with
`__divsi3` at `0x860` instead of `0xaa0`; the change is left out so that the image the report
describes stays the one committed. `spiflash.ld` names its input sections and does not load
them.

### Support objects every C program needs

*Signals:* `putchar.S`, `memcpy.c`, `errno.c`

```text
  putchar.S   the bottom of the output stack: writes one byte to the UART
              data register, then polls the UART status register until the
              transmitter reports "not busy". Its .equ constants
              (IO_BASE 0x400000, IO_UART_DAT 8, IO_UART_CNTL 16) must agree
              with the memory map in SOC.v -- they do.
  memcpy.c    gcc emits calls to memcpy() on its own for struct/array copies,
              even if the source never calls it. Link it in or risk an
              "undefined reference".
  errno.c     dummy __errno, for the same reason.
```

### The missing stdio.h and the stub header

*Signals:* `fw/stdio.h`

```text
    THE PROBLEM. sieve.c starts with #include <stdio.h>, but the Debian
    gcc-riscv64-unknown-elf package ships NO C library headers at all -- its
    include path holds only gcc's own headers. Compiling as-is fails with:
        sieve.c:12:10: fatal error: stdio.h: No such file or directory

    WHY NOT JUST INSTALL A C LIBRARY. The obvious move is
    "sudo apt-get install picolibc-riscv64-unknown-elf". Do not bother:
    it is a ~158MB download, its headers install to
    /usr/lib/picolibc/riscv64-unknown-elf/include/ which is NOT on gcc's
    default search path (so the error would persist unchanged), and its
    printf is precisely the bloated thing that will not fit in 6KB of RAM.
    Avoiding it is the entire reason print.c exists.

    THE FIX. All the compiler actually needs is a DECLARATION -- the shape of
    printf(), so it can typecheck the calls. The real code is supplied later,
    at link time, by print.c. So write a two-line stub header of our own.
```

### Which headers need a stub

*Signals:* `fw/stdio.h`

```text
    If a future C program includes other headers (<stdint.h>, <stddef.h>,
    <stdarg.h>), note those three DO ship with gcc itself and need no stub --
    only C-library headers like <stdio.h> or <string.h> are missing. For those,
    extend this same stdio.h approach: declare only what the program calls, and
    make sure something in the link actually implements it.
```

### Why libgcc.a is required and why it goes last

*Signals:* `LIBGCC`

```text
5c. WHY libgcc.a IS REQUIRED. Processor.v implements RV32I only -- there is
    no multiply, divide or modulo instruction in the hardware. When C code
    writes "a * b" or "j % 2", gcc cannot emit a MUL, so it emits a CALL to a
    software routine (__mulsi3, __divsi3, __umodsi3 ...). Those routines live
    in libgcc.a, which ships with the compiler. Omit it and the link fails
    with "undefined reference to `__mulsi3'".

    Ask gcc where the right copy is rather than hardcoding a path:
    -print-libgcc-file-name returns the variant matching -march/-mabi, e.g.
    /usr/lib/gcc/riscv64-unknown-elf/13.2.0/rv32i/ilp32/libgcc.a . A hardcoded
    path breaks on the next toolchain update; this does not. Note it must come
    LAST on the ld command line -- ld resolves symbols left to right, so a
    library must appear after everything that references it.

    (This is the same job mulsi3_ did by hand in the old program_asm.v
    Mandelbrot program -- now the compiler arranges it automatically.)
```

### Do not link perf.S

*Signals:* `perf.S`

```text
5d. DO NOT LINK perf.S. Upstream lists it among its library objects, but
    it provides rdcycle()/rdinstret(), which read RISC-V CSR performance
    counters. This core has no CSRs -- Processor.v's SYSTEM handling covers
    EBREAK and nothing else. Any program that actually calls them will
    misbehave. sieve.c does not, so simply leave perf.S out of the link.
```

### Bare file name in $readmemh

*Signals:* `$readmemh`

```text
$readmemh() below resolves "firmware.hex" as a bare filename, so the file has
to be somewhere the tool doing the reading will look. Vivado handles that by
copying every file registered in the project into the simulation/synthesis
working directory -- which means the file must be TRACKED in the project, not
merely present on disk.
```

### Simulation and hardware after a firmware change

*Signals:* `$readmemh`

```text
  6c. Simulation: right-click sim_1 -> "Reset Behavioral Simulation" (a plain
      re-run may reuse the old working directory and thus the old hex), then
      run it. If the file was not found, xsim does NOT stop with an error --
      it prints a WARNING in simulate.log ("File firmware.hex ... cannot be
      opened for reading"), leaves MEM full of X, and the CPU sits doing
      nothing while LEDS stay at their reset value of 0. If a program appears
      to do nothing at all, check simulate.log for that warning FIRST.

  6d. Hardware: re-run synthesis -> implementation -> generate bitstream ->
      program device. The hex contents are baked into the Block RAM
      initialization at synthesis time, so changing firmware.hex requires a
      full rebuild, not just re-programming.
```

### Practical notes learned the hard way

*Signals:* toolchain, `wait.S`, UART

```text
  * ld's flag is --no-relax, with TWO dashes. Older instructions show
    "-norelax", which binutils 2.42 rejects outright:
    "unable to disambiguate: -norelax (did you mean --norelax ?)".
    The assembler's spelling is different again: -mno-relax.

  * "warning: <file> has a LOAD segment with RWX permissions" from ld is
    expected and harmless. It is a security warning about memory that is
    simultaneously writable and executable -- which is exactly what a single
    unified bare-metal BRAM is. There is no OS here to enforce W^X.

  * Delay loops are tuned for far slower boards. wait.S uses 2^17 iterations,
    which on this 200MHz core is about 5.24ms -- so blinker.S alternates its
    two LED patterns at roughly 190Hz. That is far above the eye's flicker
    fusion threshold, so LEDS[3:0] simply look CONTINUOUSLY LIT (each of those
    four bits is set in exactly one of 0x05/0x0A) rather than blinking.
    Nothing is broken; change the shift in wait.S from 17 to 23 (a 64x longer
    delay, ~335ms) to actually see it blink.

  * Simulation runtimes must be generous. A single wait() call is ~5.24ms of
    simulated time, and UART output runs at 115200 baud = ~87us PER CHARACTER,
    so sieve.c's full prime list takes tens of milliseconds. Vivado's default
    run time is far too short; use "run 70ms" in the Tcl console. In
    the old iverilog testbench the equivalent knob is the #<time> before $finish.

  * To watch UART output in simulation, read the "UART PIN byte:" lines
    printed by the testbench's serial decoder -- it samples the actual
    uart_rx_out pin like a real receiver. Do NOT trust the old top-level's
    "UART TX char:" debug prints for anything pin-related: they print what the CPU
    handed to the UART, not what left the chip, and were blind to the
    TX/RX pin-direction bug that once stopped all output reaching the PC.

  * On real hardware, UART output appears on /dev/ttyUSB0 via the board's
    separate "USB UART" connector (J15, an FT232R), NOT the JTAG connector:
        gtkterm --port /dev/ttyUSB0 --speed 115200

  * Watch the occupancy figure firmware_words prints. This RAM is only 6KB
    and the stack grows down into the very same space from 0x1800. A program
    that nearly fills RAM will have its code silently overwritten by its own
    stack, and the CPU will wander off into garbage.
```

### The riscv64 prefix builds RV32I code

*Signals:* toolchain

```text
    Despite the "riscv64" in the name, this toolchain builds 32-bit RV32I code
    perfectly well -- that is what the -march=rv32i -mabi=ilp32 flags select.
    There is no separate riscv32- package to look for.
```

### firmware_words arguments; -max_addr as a stack guard

*Signals:* `firmware_words`

```text
firmware_words arguments:
  -ram 6144        size of this machine's RAM in BYTES; must match MEM below.
  -max_addr 6144   refuse to emit anything reaching past this address. Useful
                   as a guard: set it lower than -ram to reserve headroom for
                   the stack, since the stack grows DOWN from 0x1800 into the
                   same 6KB and silently overwriting your own code is a
                   miserable bug to chase.
  -out <file>      output filename; the .hex extension selects hex output
                   (the same tool can also emit raw .bin).
```

### How the stub header is found

*Signals:* `-I.`

```text
    HOW IT GETS FOUND. Adding -I. to the compile command means "also search
    the current directory for headers". Since you compile from inside
    the firmware directory, #include <stdio.h> then resolves
    to this stub. This does NOT affect the real hardware in any way -- it only
    silences a compile-time lookup. The actual printf machinery comes from
    print.c, which in turn calls putchar.S, which writes to the UART.
```

### RAM size and the firmware load

*Signals:* `MEM`, `$readmemh`

```text
// 1536 words x 4 bytes/word = 6144 bytes = 6KB of RAM, mapped by Vivado
// onto the FPGA's Block RAM tiles.
reg [31:0] MEM [0:1535];

initial begin
    // Load the assembled program (and its initial data) from a plain
    // hex text file, one 32-bit word per line. This runs once, setting
    // the RAM's starting contents for both simulation and synthesis
    // (Vivado turns it into the Block RAM's init values).
    //
    // firmware.hex is produced by the GNU RISC-V toolchain, NOT by hand and
    // not by this project's older VERILOG assembler -- see the full
    // "HOW TO BUILD firmware.hex" section at the top of this file for the
    // complete compile/link/convert recipe, the flags each step needs, and
    // how to register the file with Vivado so it is actually found here.
    //
    // Note the bare filename: it is resolved relative to whatever directory
    // the simulator or synthesizer runs in, not relative to this .v file.
    // If it cannot be found, $readmemh does NOT fail loudly -- MEM is simply
    // left as X and the CPU executes nothing.
```

### Word index and the registered read

*Signals:* `mem_addr`, `mem_rdata`

```text
mem_addr[31:2] is the word index (the 2 dropped LSBs would select a
byte within a word -- irrelevant here, since a read always returns
the whole word and a write is masked per byte, not re-addressed).

Read is registered (synchronous): like all Block RAM, one clock cycle
passes between mem_rstrb going high and the requested word appearing
on mem_rdata. Processor.v accounts for this with a dedicated WAIT_*
state after every memory request.
```

### Per-byte write enables

*Signals:* `mem_wmask`

```text
Each mem_wmask bit independently enables writing its matching
byte of mem_wdata -- this is what lets SB/SH modify a single
byte/halfword of a word without touching the other bytes.
```

## program_asm (`sim/asm/program_asm.v`)

The file is the first mandelbrot, written for the Verilog assembler; `MEM` and `memPC`
keep their upper-case names because
`riscv_assembly.v` (upstream, included verbatim) writes to them.

### What the program does and how it multiplies

*Signals:* module header

```text
* Mandelbrot set in ASCII art over UART. Pure software -- no
* hardware changes; the same Processor/Memory/SOC/UART this
* project already has hardware-verified is reused completely unchanged.
*
* There is no hardware multiplier (this core implements plain RV32I, and
* MUL is part of the separate RV32M extension), so real-number math is
* done two ways at once here:
*   - Numbers are represented in Q22.10 fixed point: 10 fractional bits,
*     so a real number x is stored as the integer x*2^10. Add/subtract
*     need no adjustment (the 2^10 factor cancels); multiply produces a
*     2^20-scaled result that has to be shifted right by 10 to rescale.
*   - The actual multiply is done in software: mulsi3_ below is the same
*     shift-and-add routine ported from gcc's libgcc (the
*     library routine gcc itself emits calls to when targeting an RV32I
*     core with no MUL instruction).
*
* Renders an 80x80 character escape-time Mandelbrot over the viewport
* [-2,2]x[-2,2]: each pixel iterates Z <- Z^2+C (up to 9 times, starting
* from Z=C), and is colored by how many iterations it survived before
* |Z| exceeded 2, via colormap_'s darkest-to-brightest 10-character ramp.
* Loops forever, redrawing the same fixed view every pass; modify it
* to draw your own graphics if you want to animate/zoom/pan instead.
```

### Why the LEDs blink before each frame

*Signals:* `blink_`

```text
Blink LEDS 5 times: a visible "starting a fresh render" cue --
useful here because one full 80x80 frame takes a while on this
non-pipelined, no-hardware-multiply core.
```

### Label workflow

*Signals:* the `integer ..._` labels

```text
Labels left uninitialized on purpose: run once under -DBENCH first,
read the "Label:" values it prints (in the same order as the Label()
calls below), then fill them in here and re-run until ASMerror is 0.
See riscv_assembly.v's own header comment for this workflow.
```

### Register roles

*Signals:* `s0`..`s11`

```text
Register roles through the render loop:
  s0,s1    : pixel X,Y (column, row)
  s2,s3    : C (real, imaginary) -- current pixel's coordinate
  s4,s5    : Z (real, imaginary) -- the iterate, starts at C
  s6,s7,s8 : Zr*Zr, 2*Zr*Zi, Zi*Zi -- scratch for one Z<-Z^2+C step
  s10      : iterations remaining, counts down from 9. Its value
             when the loop exits selects colormap_'s character:
             escaping immediately leaves it high ("far outside",
             a bright character); never escaping runs it to 0
             ("probably inside", the blank character).
  s11      : 80, the loop bound (both X and Y)
```

### Line ending after each row

*Signals:* `putc_`

```text
LI(a0, 13);          // CR: return to column 0 -- not every terminal
CALL(LabelRef(putc_)); // treats a bare LF as an implicit CR too (see
                       // the note by this project's self-test's
                       // banner_ string for the same convention)
```

### Delay loop

*Signals:* `wait_`

```text
wait_: fixed delay, only used by the LED blink above (slow_bit=0
for fast BENCH simulation, 20 for a visible on-board blink rate,
same convention as this project's earlier self-test program).
```

### Leaf subroutines, and why every CALL() targets forward

*Signals:* `putc_`, `CALL`, `AUIPC`

```text
putc_ / putc_L0_: unchanged from this project's earlier
self-test program (already proven working end-to-end on real
hardware). No subroutine in this file calls another subroutine
(mulsi3_/putc_/wait_ are all leaves), so unlike that earlier
program's putstring_, nothing here needs ra saved on the stack.

NOTE on CALL() and code placement: CALL(offset) expands to
AUIPC(x6,offset); JALR(x1,x6,offset[11:0]), and AUIPC's task
takes the raw offset as its upper-immediate with no "round up
when the low 12 bits are negative" correction (unlike LI(),
which does apply that correction). That correction is exactly
what's needed whenever offset[11:0]'s own bit 11 is set -- which
happens for essentially any *backward* CALL(), even a very
short one. So every CALL() in this file is deliberately arranged
to target something defined AFTER it (the render loop calls
forward into mulsi3_/putc_, blink_ calls forward into wait_).
J() and the B-type branches (BEQ/BNE/BGT/BEQZ/BNEZ) encode their
target directly as one signed field and are not affected --
backward branches/jumps elsewhere in this file are fine.
```

### Colour map padding

*Signals:* `colormap_`

```text
colormap_: darkest-to-brightest character ramp, indexed 0..9 by
the iteration count left in s10 when a pixel's loop exits. The
last two bytes are padding to fill out the final DATAB word --
never read, since s10 never exceeds 9.
```
