# Vivado scripts

Tcl for Vivado 2025.2 in batch mode. The project is never committed: these scripts generate
it, referring to the sources where they are.

| File | What it does |
|---|---|
| `create_project.tcl` | Generates the project, `build/vivado/soc.xpr`, from the file list below |
| `build.tcl` | Regenerates the project, then runs synthesis, implementation and the bitstream, copied to `build/SOC.bit` |
| `baseline.tcl` | Synthesis, placement and routing in non-project mode, with utilization and timing reports and a routed checkpoint in `build/baseline/` |
| `common.tcl` | Shared by the three: the part, the file list, the paths, two helpers |
| `rtl_sources.txt` | The RTL file list, also read by the simulation scripts |

There is no Makefile here; the root `Makefile` runs the scripts from inside `build/`, since
Vivado writes `.Xil/` into the directory it starts in:

```sh
make check-synth   # synthesis only
make bitstream     # synthesis, implementation, build/SOC.bit; prints WNS, WHS and timing=MET|FAILED
make baseline      # the non-project run behind docs/baseline.md
```

`make bitstream` builds the flash-boot design. The root README, "Building the bitstream" and
"Running the demos", says how to build a BRAM-boot one, open the project in the GUI, and load a
bitstream on the board.
