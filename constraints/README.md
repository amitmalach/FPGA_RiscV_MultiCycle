# Constraints

`Genesys-2-Master.xdc` is the design's one constraints file: Digilent's master XDC for the
Genesys 2 (Rev. H) with the lines `SOC` uses uncommented and their ports renamed: the package
pin and I/O standard of each of the 16 port bits, the 200 MHz clock on `sysclk_p` (the
design's one timing constraint, a 5 ns period) and the configuration-bank voltage (`CFGBVS`,
`CONFIG_VOLTAGE`). Each pin line keeps Digilent's comment with the pin's function
and its net name in the board schematic.

To use another part of the board, uncomment its line, rename the port in it and add a port of
that name to `SOC`: Vivado refuses to write a bitstream while a port has no pin or no I/O
standard.

There is no Makefile here; the scripts in `vivado/` read the file. The final report, chapter
"The board", shows each pin on the package.
