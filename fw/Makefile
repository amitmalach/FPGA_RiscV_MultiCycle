# Firmware build for the multi-cycle RV32I SoC.
#
#   make                              mandelbrot demo, BRAM boot -> canonical firmware.hex
#   make PROG=sieve                   another demo, BRAM boot
#   make PROG=ST_NICCC TARGET=flash   flash boot: build/<prog>.spiflash.{elf,bin,mcs}
#   make build/mandelbrot.s           a demo's assembly, for the reader: no firmware build uses it
#   make check                        memory-map mirrors match rtl/defines.vh; rebuild from clean
#                                     and compare against the committed image
#   make bram, make flash             the two halves of the default target, which TARGET picks
#   make clean
#
# Variables: PROG (default mandelbrot), TARGET (bram or flash), BUILD (output directory,
# default build/), HEX_OUT (the BRAM-boot image, below), RAM_SIZE (below), CROSS (the toolchain
# prefix), XILINX_RV32_ROOT (Vivado's RISC-V newlib, for tinyraytracer). A flash build runs
# Vivado's write_cfgmem, so it needs Vivado's settings64.sh sourced.
#
# Demos: blinker sieve mandelbrot riscv_logo ST_NICCC (BRAM or flash)
#        tinyraytracer (flash only: ~29 KB of code, the RAM holds 6 KB)
# TARGET=bram writes HEX_OUT, the one firmware image the RTL reads.
# TARGET=flash never touches HEX_OUT; BRAM contents are irrelevant when booting from flash.

PROG   ?= mandelbrot
TARGET ?= bram
BUILD  ?= build

# The single firmware image. Memory.v reads it with $readmemh("firmware.hex");
# vivado/create_project.tcl lists it in both the synthesis and simulation filesets.
HEX_OUT ?= ../rtl/firmware.hex

# Bytes of on-chip RAM and the flash code offset: copies of RAM_WORDS (x4) and
# SPIFLASH_CODE_OFFSET in rtl/defines.vh; tests/check_memory_map.sh keeps them
# equal. RAM_SIZE is the firmware's only copy of the RAM size: the assembler
# and linker receive it as the symbol RAM_SIZE (ASFLAGS, LDFLAGS below), so
# start*.S compute the stack top and memory.ld the RAM length from it. A SOC
# built with another RAM_WORDS needs its firmware from
# `make RAM_SIZE=<bytes> HEX_OUT=<path>`: the canonical image stays the default's.
RAM_SIZE          = 6144
FLASH_CODE_OFFSET = 0xD00000

DEMOS      = blinker sieve mandelbrot riscv_logo tinyraytracer ST_NICCC
FLASH_ONLY = tinyraytracer

# --- toolchain ----------------------------------------------------------------
CROSS   ?= riscv64-unknown-elf-
AS       = $(CROSS)as
CC       = $(CROSS)gcc
LD       = $(CROSS)ld
OBJCOPY  = $(CROSS)objcopy
VIVADO  ?= vivado

ARCHFLAGS = -march=rv32i -mabi=ilp32
ASFLAGS   = $(ARCHFLAGS) -mno-relax --defsym RAM_SIZE=$(RAM_SIZE)
CFLAGS    = $(ARCHFLAGS) -O2 -fno-pic -fno-stack-protector -I.
# --no-warn-rwx-segments: a single RWX region is the intended layout here.
LDFLAGS   = -m elf32lriscv -nostdlib --no-relax --no-warn-rwx-segments \
            --defsym RAM_SIZE=$(RAM_SIZE)
LIBGCC    = $(shell $(CC) $(ARCHFLAGS) -print-libgcc-file-name)

# The distro toolchain ships no C library. tinyraytracer needs <math.h> and
# libm; the rv32i/ilp32 newlib bundled with Vivado provides both and links
# cleanly against objects from riscv64-unknown-elf-gcc. Used only for
# tinyraytracer, so every other image builds without Vivado installed.
XILINX_RV32_ROOT ?= $(HOME)/Xilinx/2025.2/gnu/riscv/lin/riscv32-xilinx-elf/usr
MATH_INC = -I$(XILINX_RV32_ROOT)/include
MATH_LIB = -L$(XILINX_RV32_ROOT)/lib/rv32i/ilp32 -lm

# --- objects ------------------------------------------------------------------
LIBOBJS = $(addprefix $(BUILD)/,putchar.o wait.o print.o memcpy.o errno.o)

# Records which demo HEX_OUT currently holds, so `make PROG=x` after
# `make PROG=y` rebuilds the image even though both ELFs already exist.
IMAGE_DEMO_STAMP = $(BUILD)/image_demo
# Records the RAM_SIZE the start-up objects and the ELFs were built with (they take
# it as a symbol), so another RAM_SIZE rebuilds them.
RAM_SIZE_STAMP = $(BUILD)/ram_size

# Link: $(1) = linker script, $(2) = startup object. The demo object ($<)
# comes right after the startup code; libgcc (and libm when set) close the group.
link = $(LD) -T $(1) $(LDFLAGS) $(2) $< $(LIBOBJS) \
           --start-group $(LIBGCC) $(EXTRA_LIBS) --end-group -o $@

.PHONY: all bram flash check clean print-hex-path
.DELETE_ON_ERROR:
# Keep chained intermediates instead of deleting them after each build.
# Never use a bare `.SECONDARY:` here: it would also mark the ELFs as
# intermediate, and make then skips rebuilding a missing ELF whenever the
# hex is newer than the sources, turning `make` into a no-op.
.SECONDARY: $(LIBOBJS) $(BUILD)/start.o $(BUILD)/start_spiflash.o $(BUILD)/$(PROG).o \
            $(BUILD)/$(PROG).spiflash.elf

ifeq ($(TARGET),bram)
all: bram
else ifeq ($(TARGET),flash)
all: flash
endif

# Validate the selectors only when a build goal is requested. The flash-only
# check applies to the image goals (`all`/`bram`), not to explicit flash files.
GOALS = $(if $(MAKECMDGOALS),$(MAKECMDGOALS),all)
ifneq ($(filter-out clean print-hex-path,$(GOALS)),)
  ifeq ($(filter bram flash,$(TARGET)),)
    $(error TARGET must be bram or flash, got '$(TARGET)')
  endif
  ifeq ($(filter $(PROG),$(DEMOS)),)
    $(error PROG must be one of: $(DEMOS))
  endif
  ifneq ($(filter all bram,$(GOALS)),)
    ifeq ($(TARGET)/$(filter $(PROG),$(FLASH_ONLY)),bram/$(PROG))
      $(error $(PROG) does not fit in the $(RAM_SIZE)-byte RAM; build it with TARGET=flash)
    endif
    ifeq ($(TARGET)/$(origin RAM_SIZE)/$(origin HEX_OUT),bram/command line/file)
      $(error RAM_SIZE=$(RAM_SIZE) would overwrite the canonical image $(HEX_OUT); add HEX_OUT=<path>)
    endif
  endif
  ifeq ($(PROG)/$(wildcard $(XILINX_RV32_ROOT)/lib/rv32i/ilp32/libm.a),tinyraytracer/)
    $(error tinyraytracer needs libm: no $(XILINX_RV32_ROOT)/lib/rv32i/ilp32/libm.a; set XILINX_RV32_ROOT to a Vivado RISC-V toolchain)
  endif
endif

$(BUILD):
	mkdir -p $@

$(BUILD)/%.o: %.S | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/%.o: %.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

# The assembly gcc produces from a C file with the same flags. gcc -c makes it too and
# assembles it within the same command, so the build never writes it out.
$(BUILD)/%.s: %.c | $(BUILD)
	$(CC) $(CFLAGS) -S $< -o $@

# Only tinyraytracer uses <math.h> and libm.
$(BUILD)/tinyraytracer.o:            CFLAGS     += $(MATH_INC)
$(BUILD)/tinyraytracer.spiflash.elf: EXTRA_LIBS  = $(MATH_LIB)

ifneq ($(file <$(IMAGE_DEMO_STAMP)),$(PROG))
.PHONY: $(IMAGE_DEMO_STAMP)
endif
$(IMAGE_DEMO_STAMP): | $(BUILD)
	@echo $(PROG) > $@

ifneq ($(file <$(RAM_SIZE_STAMP)),$(RAM_SIZE))
.PHONY: $(RAM_SIZE_STAMP)
endif
$(RAM_SIZE_STAMP): | $(BUILD)
	@echo $(RAM_SIZE) > $@
$(BUILD)/start.o $(BUILD)/start_spiflash.o: $(RAM_SIZE_STAMP)

# --- BRAM boot: start.S + program + support, everything in the 6 KB RAM --------
$(BUILD)/%.bram.elf: $(BUILD)/%.o $(BUILD)/start.o $(LIBOBJS) bram.ld memory.ld $(RAM_SIZE_STAMP)
	$(call link,bram.ld,$(BUILD)/start.o)

# The image: the program's bytes padded to the whole RAM, four little-endian words a line,
# the format $$readmemh reads. The linker's RAM region already refuses a program that does
# not fit.
$(HEX_OUT): $(BUILD)/$(PROG).bram.elf $(IMAGE_DEMO_STAMP)
	$(OBJCOPY) -O binary --pad-to=$(RAM_SIZE) $< $(BUILD)/$(PROG).bram.bin
	od -An -v -tx4 -w16 --endian=little $(BUILD)/$(PROG).bram.bin > $(BUILD)/$(PROG).bram.od
	sed 's/^ //; s/$$/ /' $(BUILD)/$(PROG).bram.od > $@

bram: $(HEX_OUT)

# --- flash boot: code in SPI flash, .data/.bss/fastcode copied to RAM at startup
$(BUILD)/%.spiflash.elf: $(BUILD)/%.o $(BUILD)/start_spiflash.o $(LIBOBJS) spiflash.ld memory.ld \
                         $(RAM_SIZE_STAMP)
	$(call link,spiflash.ld,$(BUILD)/start_spiflash.o)

$(BUILD)/%.spiflash.bin: $(BUILD)/%.spiflash.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD)/%.spiflash.mcs: $(BUILD)/%.spiflash.bin tools/write_mcs.tcl
	$(VIVADO) -mode batch -nolog -nojournal -notrace -source tools/write_mcs.tcl \
	    -tclargs $(abspath $<) $(abspath $@) $(FLASH_CODE_OFFSET)

flash: $(BUILD)/$(PROG).spiflash.bin $(BUILD)/$(PROG).spiflash.mcs

# --- utilities ------------------------------------------------------------------
check:
	tests/check_memory_map.sh
	tests/check_reproducible.sh

print-hex-path:
	@echo $(abspath $(HEX_OUT))

clean:
	rm -rf $(BUILD)
