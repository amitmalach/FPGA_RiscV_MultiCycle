.equ IO_BASE, 0x400000
# RAM_SIZE (bytes) comes from fw/Makefile via --defsym; the stack grows down from the RAM top.
.section .text
.globl start
start:
	li   gp,IO_BASE
	li   sp,RAM_SIZE
	call main
	ebreak
	