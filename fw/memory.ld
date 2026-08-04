/* ===========================================================================
 * memory.ld -- the two memory regions, shared by every linker script
 * ===========================================================================
 * RAM   is the 6 KB on-chip BRAM (RAM_WORDS in rtl/defines.vh). The stack grows down
 *       from its top (0x1800, set in start*.S).
 * FLASH is the window of the board's SPI flash the core can execute from.
 *
 * FLASH ORIGIN 0x01D00000 = SPIFLASH_BASE (0x01000000, i.e. address bit 24,
 * the flash region bit in rtl/defines.vh) + 0x00D00000 (13MB into the physical
 * chip). That offset is forced by what already occupies the chip:
 *   0x000000..0xAE9E10  this design's FPGA bitstream (~10.91MB)
 *   0xC00000..0xC9C3E7  scene1.dat, the ST_NICCC polygon stream (640KB)
 *   0xD00000..0xFFFFFF  <- us: 3MB, 64KB-sector-aligned, clear of both
 * 0xFFFFFF is a hard ceiling: SPIFlash.v's 22-bit word_address reaches 16MB.
 *
 * A smaller layout (base 1<<23, code 128KB in) would be wrong here twice over:
 * 1<<23 would give an 8MB flash window, smaller than our own bitstream, and
 * 128KB is sized for a bitstream of a few tens of KB.
 *
 * RAM LENGTH must equal RAM_WORDS x 4 (rtl/defines.vh) and RAM_SIZE in the Makefile;
 * FLASH ORIGIN must equal SPIFLASH_BASE + SPIFLASH_CODE_OFFSET (rtl/defines.vh) and
 * FLASH_CODE_OFFSET in the Makefile. tests/check_memory_map.sh checks all of them.
 * =========================================================================== */

MEMORY {
    RAM   (rwx) : ORIGIN = 0x00000000, LENGTH = 0x1800      /* 6 KB in BRAM  */
    FLASH (rx)  : ORIGIN = 0x01D00000, LENGTH = 0x300000    /* 3 MB in flash */
}
