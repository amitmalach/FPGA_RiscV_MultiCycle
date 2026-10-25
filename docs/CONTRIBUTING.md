# Contributing: conventions for RTL, simulation and firmware

Read during review. The mechanical parts are enforced by `make lint` (rules listed in
`scripts/lint.sh`); the rest are judgement calls a reviewer holds the change to.

## Language

Verilog-2001. Every RTL file must compile in both xsim and iverilog. No SystemVerilog
constructs, no `always_ff`, no `logic`, no interfaces. `$clog2` is accepted because both
tools support it.

## Files and modules

- One module per file, file name equals module name (`rtl/IOBus.v` declares `module IOBus`).
  Lint rule 5.
- Every `rtl/*.v` and `rtl/*.vh` is listed in `vivado/rtl_sources.txt`, the single file list
  shared by the Vivado scripts and the regression script. Lint rule 4.
- Shared constants live in `rtl/defines.vh`, included by bare name (`` `include "defines.vh" ``).
  Scripts pass `rtl/` as an include directory where the tool needs it.
- The SoC top keeps the module name `SOC` and its port names, directions and widths: the
  constraints file and the testbench bind to them.

## Naming

| Thing | Style | Example |
|---|---|---|
| Signals, ports, instances | `lower_snake_case` | `mem_rdata`, `spiflash_rstrb`, `bus` |
| Active-low signals | `_n` suffix (lint rule 6) | `reset_n`, `spiflash_csn` is a frozen port |
| Parameters, localparams, macros | `UPPER_CASE` (lint rule 9) | `BOOT_ADDR`, `IO_BASE` |
| Modules | one word, capitalised as the file is named | `IOBus`, `Processor`, `UartTx` |

Rule 9 exempts `sim/asm/riscv_assembly.v`: it is third-party and its lower-case localparams
are the RISC-V ABI register names (`a0`, `sp`, `ra`) that the assembly programs use.

## Comments

- Module header: a few lines stating purpose, interface notes and timing caveats.
- Section banners inside a module read `// ---- name ----` padded with dashes to end at
  column 80 (lint rule 7).
- Inline comments: one line, where the code does not say why. Two lines only when one line
  would lose the reason.
- Rationale that explains a bug, workaround, tweak, timing subtlety or deliberate quirk
  belongs in `docs/design/notes.md`, verbatim apart from re-wrapping and current file names,
  grouped by module and naming the signal. A
  comment removed from RTL goes there before the commit that removes it. Extract the quote
  with `scripts/quote_comment.sh <rev>:<file> <from> <to>`: it keeps the block's relative
  indentation and reports the lines over 100 characters that need re-wrapping by hand.
- Refer to files by their current name. Ticket numbers go in commit messages and issue
  comments, not in code comments; describe the condition instead ("until rtl/ comments are
  trimmed").
- Third-party modules keep their upstream attribution lines at the top of the file.

## Gates and evidence

The gates are the targets of the root `Makefile`. Each gate writes
`build/logs/<target>-<timestamp>.log`, ending in `PASS: <target>` or `FAIL: <target>`, and
prints `LOG: build/logs/<target>-<timestamp>.log` as its last line. That log is the only
evidence a commit message or closing comment may cite, and the cited log must postdate the
last edit it covers. Copy the citation from the `LOG:` line.

Two hooks in `scripts/hooks` hold the mechanical part (enable both once with
`git config core.hooksPath scripts/hooks`): the pre-commit hook runs `make lint`, and the
commit-msg hook refuses a message that cites a log which does not exist or does not end in
PASS (or `timing=MET`), or that says pass, passes, passed or verified without citing any log.
Whether the cited log is the right gate, and postdates the edits, stays a review judgement.

- `make lint` before every commit. Cite its log; for a comment-only commit it is the only
  citation.
- `make smoke` after each RTL edit. It also runs `make unit` (`sim/ALUBench.v` under
  iverilog, seconds, no Vivado); cite both logs.
- `make -j2 check` once per ticket, after the code review and its fixes (lint and smoke first,
  then review, fix, then check), and before any push. Add `make baseline` when the ticket's
  acceptance criteria say timing met: `make check` stops after synthesis and reports no timing.
- `make check-moves BASE=<rev>` for a move-only commit.
- Commits that touch only comments, `*.md`, `docs/`, `.gitignore` or `scripts/` need
  `make lint` only, including before a push, provided the last passing `make check` covers the
  current `rtl/`, `fw/` and `sim/` sources; cite its `unit`, `check-sim` and `check-synth` logs
  (`check` itself writes no log).

A change that alters the golden trace is a behaviour change and needs
`sim/run_regression.sh --update-golden` with the reason in the commit message.

## Review judgement calls

Things no lint can hold, which a reviewer checks on every diff:

- Cross-file claims are true, in comments, README and docs alike: a statement about what a
  module, script or demo does was checked against that file before it was written (a header
  that names what the testbench passes matches what the testbench passes).
- Instance names in one file follow one style.
- A constant defined in `rtl/defines.vh` is not re-declared literally in the modules this
  change touches.
- A new firmware copy of a memory-map constant is added to `fw/tests/check_memory_map.sh`
  (lint rule 8 holds the existing ones equal to `rtl/defines.vh`).
- Commit messages claim only what the tool output in the session shows.
