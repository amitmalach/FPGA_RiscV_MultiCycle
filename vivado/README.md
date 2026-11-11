# Vivado scripts

Tcl for Vivado 2025.2 in batch mode: the project and the bitstream, and the board's JTAG and
flash. The project is never committed: these scripts generate it, referring to the sources
where they are.

| File | What it does |
|---|---|
| `create_project.tcl` | Generates the project, `build/vivado/soc.xpr`, from the file list below |
| `build.tcl` | Regenerates the project, then runs synthesis, implementation and the bitstream, copied to `build/SOC.bit` |
| `baseline.tcl` | Synthesis, placement and routing in non-project mode, with utilization and timing reports and a routed checkpoint in `build/baseline/` |
| `common.tcl` | Shared by every script here: the part, the file list, the paths, two helpers |
| `rtl_sources.txt` | The RTL file list, also read by the simulation scripts |
| `board_bitstream.tcl` | A bitstream in either boot mode, non-project, from the image in its output directory: BRAM boot sets `SOC`'s `BOOT_ADDR` to 0 at synthesis, leaving `rtl/SOC.v` as it is |
| `board_program.tcl` | Loads a bitstream into the FPGA over JTAG; the flash is not touched |
| `board_flash.tcl` | Reads the flash, or writes an image to it, over JTAG: only the bytes the image covers, never below `0xC00000`, keeping the Quad Enable bit |
| `board_jtag.tcl` | Opens the board's FPGA over JTAG, for `board_program.tcl` and `board_flash.tcl` |
| `flashregs/` | `FlashRegs.v`, a small design for the board that reads the flash's status and configuration registers and can set the Quad Enable bit again, with `build.tcl` and a bench, `FlashRegsBench.v` with `FlashModel.v` |

There is no Makefile here; the root `Makefile` runs the scripts from inside `build/`, since
Vivado writes `.Xil/` into the directory it starts in:

```sh
make check-synth   # synthesis only
make bitstream     # synthesis, implementation, build/SOC.bit; prints WNS, WHS and timing=MET|FAILED
make baseline      # the non-project run behind docs/baseline.md
```

`make bitstream` builds the flash-boot design. The board scripts have no make target: run them
from a directory under `build/`, as the root README, "Running the demos", shows for each demo
in either boot mode. Each script's header gives its arguments.

## The Quad Enable bit

The S25FL256S keeps a non-volatile Quad Enable bit (configuration register 1, bit 1), which the
bitstream the board boots at power-on needs: it reads the flash four bits wide. Vivado's flash
programming clears the bit unless the configuration memory's `PROGRAM.SKIP_QE_BIT_ERASE` is 1,
and without it the board no longer boots at power-on, with no error shown.
`board_flash.tcl write` sets the property. `docs/design/notes.md`, "Writing the flash clears the
Quad Enable bit", has the story.

Vivado's Tcl has no command that reads the flash's registers, so `flashregs/FlashRegs.v` does it
on the board: once a second it prints status register 1, configuration register 1, the chip's
ID and the four bytes at `0x30` (a bitstream's sync word, `AA995566`, as a check that the bits
line up) on the UART, and shows CR1 on the LEDs. Built with `WRITE_REGS=1`, it also writes SR1
`0x00` and CR1 `0x02` once, which sets the bit, and reads them again. To read the registers,
with a serial terminal open on the UART as in the root README:

```sh
mkdir -p build/flashregs && cd build/flashregs
vivado -mode batch -nojournal -nolog -source ../../vivado/flashregs/build.tcl -tclargs 0
vivado -mode batch -nojournal -nolog -source ../../vivado/board_program.tcl \
    -tclargs FlashRegs_w0.bit
cd -
```

The terminal shows `SR1=00 CR1=02 ID=010219 D30=AA995566` once a second on a flash whose bit is
set, `CR1=00` on one whose bit was cleared. `-tclargs 1` builds `FlashRegs_w1.bit`, which sets
the bit; load it the same way. The flash's data is never written, only its registers.
`FlashRegsBench.v`'s header says how to simulate the tool against `FlashModel.v` under Icarus
Verilog.
