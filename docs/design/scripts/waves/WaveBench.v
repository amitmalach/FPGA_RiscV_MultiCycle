`timescale 1ns/1ps
// WaveBench -- the SoC in BRAM boot with the committed firmware image, driven as sim/bench.v
// drives it (a 200 MHz clock, the reset button released at 100 ns), dumping the signals the
// final report's waveforms draw to a VCD file, and only those: the clock, the control FSM's
// state and its four strobes, pc and the instruction register, the core's bus and the LED
// register. Nothing is checked; scripts/vcd_wave.py picks the window and renders it.
// run_bench.sh runs it under iverilog with Vivado's unisim models of IBUFDS, BUFG and
// STARTUPE2.
//   +vcd=<file>   the output (default wave.vcd)
//   +ns=<n>       simulated time (default 3000 ns, 600 cycles: start-up, main's prologue and
//                 the first byte handed to the UART)
module WaveBench;
    reg clk = 1'b0;
    always #2.5 clk = ~clk;
    reg reset_n = 1'b0;
    wire [7:0] leds;
    wire uart_rx_out, spiflash_csn, spiflash_mosi;

    SOC #(
        .BOOT_ADDR     (32'h00000000)    // BRAM boot: no SPI-flash model, as in sim/bench.v
    ) uut (
        .sysclk_p      (clk),
        .sysclk_n      (~clk),
        .RESET         (reset_n),
        .LEDS          (leds),
        .uart_tx_in    (1'b1),
        .uart_rx_out   (uart_rx_out),
        .spiflash_csn  (spiflash_csn),
        .spiflash_mosi (spiflash_mosi),
        .spiflash_miso (1'b0)
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
                     uut.mem_wmask, uut.mem_wdata, uut.LEDS);
        #100 reset_n = 1'b1;
        #(ns - 100) $finish;
    end
endmodule
