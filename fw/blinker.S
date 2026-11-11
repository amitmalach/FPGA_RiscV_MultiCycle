# Simple blinker.
# Origin: blinker.S from Bruno Levy's learn-fpga, FROM_BLINKER_TO_RISCV/FIRMWARE
# (BSD-3-Clause; see LICENSE). Each wait is 5.24 ms (wait.S), so the pattern
# repeats about 95 times a second: LD0 to LD3 look steadily lit, at half
# brightness, rather than blinking.

.equ IO_LEDS, 4

.section .text

.globl main

main:
.L0:
	
	li   t0, 5
	sw   t0, IO_LEDS(gp)
	call wait
	li   t0, 10
	sw   t0, IO_LEDS(gp)
	call wait
	j .L0


