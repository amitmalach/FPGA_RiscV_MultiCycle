/* bram.ld -- BRAM boot: the whole program lives in the 6 KB on-chip RAM.
 * Origin: bram.ld from Bruno Levy's learn-fpga, FROM_BLINKER_TO_RISCV/FIRMWARE, adapted (BSD-3-Clause; see LICENSE).
 * start.o is pinned first because the reset vector is address 0. */

INCLUDE memory.ld

SECTIONS
{
    /DISCARD/ : { *(.riscv.attributes) *(.comment) }
    everything :
    {
        . = ALIGN(4);
        */start.o (.text)
        *(.*)
    } >RAM
}
