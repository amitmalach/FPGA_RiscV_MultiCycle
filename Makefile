# Repository gates. Run `make lint` before every commit (the pre-commit hook
# does, after `git config core.hooksPath scripts/hooks`) and `make check`
# before pushing or closing a ticket.
#
#   make lint          seconds: by-products, stale paths, line length, naming (no tools needed)
#   make smoke         ~10 s: short xsim run, trace must match the start of the golden file
#   make check         minutes: firmware reproducibility, xsim regression, Vivado synthesis
#   make -j2 check     same, regression and synthesis in parallel
#   make check-moves BASE=<rev>   every file moved since <rev> is a 100 % rename
#   make bitstream     synthesis, implementation, bitstream to build/SOC.bit
#   make baseline      non-project synth/impl with reports in build/baseline/
#
# smoke and check need riscv64-unknown-elf-gcc on PATH and Vivado's settings64.sh sourced.
# Inner loop: lint + smoke after each RTL edit; check before closing a ticket, plus
# baseline when the ticket's criteria say timing met (check stops after synthesis).
#
# Every tool-running target writes its output to build/logs/<target>-<timestamp>.log
# as well as the terminal; targets of one make invocation share the timestamp. Those
# logs are the evidence a commit message or closing comment cites (docs/agents/review.md).

SHELL  := /bin/bash
VIVADO ?= vivado
BUILD   = build
LOGS    = $(BUILD)/logs
STAMP  := $(shell date +%Y%m%d-%H%M%S)
# logged,<target>,<command>: run the command, tee to the target's log, keep its exit code.
logged = mkdir -p $(LOGS) && { $(2); } 2>&1 | tee $(LOGS)/$(1)-$(STAMP).log; exit $${PIPESTATUS[0]}
# Vivado writes .Xil/ into the directory it is launched from, so every Vivado
# run starts inside build/. The scripts take absolute paths.
VIVADO_BATCH = mkdir -p $(BUILD) && cd $(BUILD) && $(VIVADO) -mode batch -nojournal -nolog

.PHONY: lint smoke check check-fw check-sim check-synth check-moves bitstream baseline

lint:
	$(call logged,lint,scripts/lint.sh)

check: check-sim check-synth

# The firmware check deletes and regenerates rtl/firmware.hex, so the gates
# that read the image wait for it.
check-fw:
	$(call logged,check-fw,$(MAKE) --no-print-directory -C fw check)

check-sim: check-fw
	$(call logged,check-sim,sim/run_regression.sh)

SMOKE_CYCLES ?= 4000000
smoke: check-fw
	$(call logged,smoke,sim/run_regression.sh --max-cycles $(SMOKE_CYCLES))

check-synth: check-fw
	$(call logged,check-synth,$(VIVADO_BATCH) -source $(CURDIR)/vivado/build.tcl -tclargs $(CURDIR)/$(BUILD)/vivado synth)

# Full bitstream, and the non-project baseline run (the numbers in docs/baseline.md).
bitstream:
	$(call logged,bitstream,$(VIVADO_BATCH) -source $(CURDIR)/vivado/build.tcl -tclargs $(CURDIR)/$(BUILD)/vivado bitstream)

baseline:
	$(call logged,baseline,$(VIVADO_BATCH) -source $(CURDIR)/vivado/baseline.tcl -tclargs $(CURDIR)/$(BUILD)/baseline)

check-moves:
	scripts/lint.sh --moves $(BASE)
