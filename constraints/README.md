# Constraints

`Genesys-2-Master.xdc` is the design's one constraints file, cut down from Digilent's master
file for the Genesys 2: the package pin and I/O standard of each of the 16 ports of `SOC`, the
200 MHz clock on `sysclk_p` (the design's one timing constraint, a 5 ns period), and the
configuration-bank voltage (`CFGBVS`, `CONFIG_VOLTAGE`). Each pin line keeps Digilent's comment
with the pin's function and its net name in the board schematic.

To use another part of the board, copy its pin's line from Digilent's master XDC for the
Genesys 2 and add a port of the same name to `SOC`: Vivado refuses to write a bitstream while
a port has no pin or no I/O standard.

There is no Makefile here; the scripts in `vivado/` read the file. The final report,
`docs/design/design.tex`, chapter "Board and tools", shows each pin on the schematic and on the
package.
