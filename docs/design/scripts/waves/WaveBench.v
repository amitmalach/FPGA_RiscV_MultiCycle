`timescale 1ns/1ps
// WaveBench -- the SoC driven as sim/bench.v drives it (a 200 MHz clock, the reset button
// released at 100 ns), dumping the signals the final report's waveforms draw or trigger on to
// a VCD file, and only those: the clock, the control FSM's state and its four strobes, pc and
// the instruction register, the core's bus with mem_rbusy, the LED register, the flash pins,
// CCLK and the flash controller's receive count. Nothing is checked; scripts/vcd_wave.py
// picks the window and renders it.
// run_bench.sh runs it under iverilog with Vivado's unisim models of IBUFDS, BUFG and
// STARTUPE2.
//   FLASH_BOOT    0: BRAM boot with the committed firmware image, as sim/bench.v (default);
//                 1: flash boot, BOOT_ADDR_FLASH, with FlashImage holding the image
//   +vcd=<file>   the output (default wave.vcd)
//   +ns=<n>       simulated time (default 3000 ns, 600 cycles: in BRAM boot, start-up,
//                 main's prologue and the first byte handed to the UART)
//   +flash=<file> +flash_bytes=<n>   the flash-boot image, for FlashImage
// FlashImage is clocked from glbl.CCLKO_GLBL, the CCLK pin as the STARTUPE2 model drives it,
// not from the controller's spi_clk: after end of startup the model holds the pin high until
// USRCCLKO has risen twice, and passes USRCCLKO from then on.
`include "defines.vh"
module WaveBench;
    parameter FLASH_BOOT = 0;

    reg clk = 1'b0;
    always #2.5 clk = ~clk;
    reg reset_n = 1'b0;
    wire [7:0] leds;
    wire uart_rx_out, spiflash_csn, spiflash_mosi, spiflash_miso;

    SOC #(
        .BOOT_ADDR     (FLASH_BOOT ? `BOOT_ADDR_FLASH : `BOOT_ADDR_BRAM)
    ) uut (
        .sysclk_p      (clk),
        .sysclk_n      (~clk),
        .RESET         (reset_n),
        .LEDS          (leds),
        .uart_tx_in    (1'b1),
        .uart_rx_out   (uart_rx_out),
        .spiflash_csn  (spiflash_csn),
        .spiflash_mosi (spiflash_mosi),
        .spiflash_miso (spiflash_miso)
    );

    FlashImage flash (
        .cs_n (spiflash_csn),
        .sclk (glbl.CCLKO_GLBL),
        .mosi (spiflash_mosi),
        .miso (spiflash_miso)
    );

    reg [1023:0] vcd = "wave.vcd";
    integer      ns  = 3000;
    reg          unused_ok;   // $value$plusargs returns "found"; absence is fine

    initial begin
        unused_ok = $value$plusargs("vcd=%s", vcd);
        unused_ok = $value$plusargs("ns=%d", ns);
        $dumpfile(vcd);
        $dumpvars(0, uut.clk,
                     uut.cpu.control.state, uut.cpu.control.latch_instr,
                     uut.cpu.control.read_regs, uut.cpu.control.update_pc,
                     uut.cpu.control.write_rd, uut.cpu.pc, uut.cpu.instr,
                     uut.mem_addr, uut.mem_rstrb, uut.mem_rdata,
                     uut.mem_wmask, uut.mem_wdata, uut.mem_rbusy, uut.LEDS,
                     uut.spiflash_csn, uut.spiflash_mosi, uut.spiflash_miso,
                     uut.spiflash.rcv_bitcount, glbl.CCLKO_GLBL);
        #100 reset_n = 1'b1;
        #(ns - 100) $finish;
    end
endmodule
