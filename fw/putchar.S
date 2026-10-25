# IO-reg offsets from IO_BASE, which start*.S load into gp.
# To read or write one of them, use IO_XXX(gp)
.equ IO_UART_DAT, 8
.equ IO_UART_CNTL, 16

.section .text
.globl putchar

putchar:
   sw a0, IO_UART_DAT(gp)
   li t0, 1<<9
.L0:  
   lw t1, IO_UART_CNTL(gp)
   and t1, t1, t0
   bnez t1, .L0
  ret

