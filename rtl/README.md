# RTL

The synthesizable Verilog-2001 of the SoC, one module per file, each file named after its
module. Everything runs in one clock domain, the board's 200 MHz clock.

| File | What it is |
|---|---|
| `SOC.v` | The top level: the clock buffers, `Clockworks`, the core, the bus, the RAM, the UART, the flash controller and `STARTUPE2`, wired together |
| `Processor.v` | The multi-cycle RV32I core: `pc`, the instruction register and the glue around the four modules below |
| `Control.v` | The core's state machine, one state per cycle |
| `Decoder.v` | The instruction decoder: class flags, register indices, immediates |
| `ALU.v` | The arithmetic and logic unit and the branch comparator |
| `RegisterFile.v` | The 32 registers, in LUT RAM |
| `IOBus.v` | The address decode, the LED register and the read-data multiplexer |
| `Memory.v` | The 6 KB of block RAM, loaded from `firmware.hex` |
| `UartTx.v` | The UART transmitter, 115200 baud, 8N1 |
| `SPIFlash.v` | The SPI flash read controller: one 32-bit word per transaction |
| `Clockworks.v` | The clock enable and the reset button |
| `defines.vh` | The memory map and the bus widths, defined once for the whole design |
| `firmware.hex` | The one firmware image: the mandelbrot demo, BRAM boot |

There is no Makefile here. The root `Makefile` synthesizes these files (`make check-synth`,
`make bitstream`, `make baseline`, through the scripts in `vivado/`) and simulates them
(`make smoke`, `make check`, through `sim/`). `vivado/rtl_sources.txt` lists every file, and
`make lint` fails when the list and the folder differ.

`make -C fw` regenerates `firmware.hex`; never edit it by hand. `Memory.v` reads it by bare
name, relative to the working directory of the tool, so every script that synthesizes or
simulates runs in a directory of its own with the image copied or linked in.
