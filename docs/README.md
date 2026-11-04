# Documentation

| Path | What it is |
|---|---|
| `CONTRIBUTING.md` | The coding conventions, the gates and which log a commit cites, and the review checklist |
| `baseline.md` | The reference numbers: the golden trace's cycle count and the synthesis and timing results |
| `design/` | The final report and everything behind it |

## The final report, `design/`

| Path | What it is |
|---|---|
| `design.tex` | The report's LaTeX source |
| `design.pdf` | The built report, committed |
| `notes.md` | The design notes: one entry per design question, grouped by module, each answered in the current names; the report cites them by title |
| `figures/` | The figures, and a README with the script or recipe behind each one |
| `scripts/` | The scripts that make the figures and record the board captures, the board's flash tools, and `flashregs/`, a small FPGA design that reads and sets the flash's Quad Enable bit |
| `captures/` | The UART output of the demos, recorded from the board |

Its `Makefile`:

```sh
make -C docs/design            # build/design.pdf from the committed figures: pdflatex only
make -C docs/design publish    # the same, copied to design/design.pdf, the committed copy
make -C docs/design figures    # regenerate every scriptable figure: Vivado, xvfb-run, Ghostscript
make -C docs/design captures   # record the board captures again: the board, Vivado, RISC-V gcc
make -C docs/design clean
```

`figures` is also available in parts: `board-figures`, `waves`, `flow`, `impl` and
`schematics`. The header of `design/Makefile` says what each needs.
