# Origin: wait.S from Bruno Levy's learn-fpga, FROM_BLINKER_TO_RISCV/FIRMWARE
# (BSD-3-Clause; see LICENSE). Busy-waits 2^17 loop turns: 5.24 ms at 200 MHz.

.section .text
.globl wait

wait:
        li t0,1
	slli t0, t0,17
.L0:       
        addi t0,t0,-1
	bnez t0, .L0
	ret

