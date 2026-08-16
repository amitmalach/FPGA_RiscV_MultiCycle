`timescale 1ns/1ps

// bench -- SoC-level regression testbench. Observes the SoC from the outside
// only (LEDs and the FPGA-to-PC UART line) and writes one line per event to a
// trace file: LEDS <time_ns> <hex>, UART <hex>, END <reason> cycles=<n>
// uart_bytes=<n> leds=<hex>. Nothing internal is read, so the RTL can change
// freely as long as the trace stays byte-identical to sim/golden/*.txt.
// BOOT_ADDR is forced to 0 (BRAM boot: no SPI-flash model); the run script
// links firmware.hex into xsim's working directory. The run stops when LEDS
// becomes STOP_LEDS (the mandelbrot frame counter, 1 = first frame drawn;
// negative = never) or after MAX_CYCLES. Plusargs override the parameters:
// +out=<file> +max_cycles=<n> +stop_leds=<n>. See sim/README.md.

module bench();

   parameter         OUT_FILE   = "sim_out.txt";
   parameter integer MAX_CYCLES = 400_000_000;  // 2 s of simulated time at 200 MHz
   parameter integer STOP_LEDS  = 1;
   parameter integer BAUD       = 115200;       // passed to the SoC, decoded below

   // Differential 200 MHz clock: period 5 ns.
   reg sysclk_p = 1'b0;
   reg sysclk_n = 1'b1;

   // Active-low reset button: 0 = pressed.
   reg reset_n = 1'b0;

   wire [7:0] leds;

   // uart_tx_in  : the PC's TX line, an input to the FPGA (unused: no receiver).
   // uart_rx_out : the PC's RX line, an output of the FPGA -- the line we decode.
   reg  uart_tx_in = 1'b1;
   wire uart_rx_out;

   // SPI flash pins: unused in BRAM boot. MISO is tied low.
   wire spiflash_csn;
   wire spiflash_mosi;

   SOC #(
      .BOOT_ADDR     (32'h00000000),    // BRAM boot; see header
      .UART_BAUD     (BAUD)
   ) uut (
      .sysclk_p      (sysclk_p),
      .sysclk_n      (sysclk_n),
      .RESET         (reset_n),
      .LEDS          (leds),
      .uart_tx_in    (uart_tx_in),
      .uart_rx_out   (uart_rx_out),
      .spiflash_csn  (spiflash_csn),
      .spiflash_mosi (spiflash_mosi),
      .spiflash_miso (1'b0)
   );

   always begin
      #2.5;
      sysclk_p = ~sysclk_p;
      sysclk_n = ~sysclk_n;
   end

   initial begin
      reset_n = 1'b0;
      #100;
      reset_n = 1'b1;
   end

   // ---- run control and trace file ------------------------------------------
   reg [1023:0] out_file   = OUT_FILE;
   integer      max_cycles = MAX_CYCLES;
   integer      stop_leds  = STOP_LEDS;
   integer      fd;
   integer      cycles     = 0;
   integer      uart_bytes = 0;
   reg          unused_ok;   // $value$plusargs returns "found"; absence is fine

   initial begin
      unused_ok = $value$plusargs("out=%s", out_file);
      unused_ok = $value$plusargs("max_cycles=%d", max_cycles);
      unused_ok = $value$plusargs("stop_leds=%d", stop_leds);
      fd = $fopen(out_file, "w");
      if (fd == 0) begin
         $display("bench: cannot open output file %0s", out_file);
         $finish;
      end
      $display("bench: writing trace to %0s (max_cycles=%0d stop_leds=%0d)",
               out_file, max_cycles, stop_leds);
   end

   task stop;
      input [8*16-1:0] reason;
      begin
         $fdisplay(fd, "END %0s cycles=%0d uart_bytes=%0d leds=%02h",
                   reason, cycles, uart_bytes, leds);
         $display("bench: %0s after %0d cycles, %0d UART bytes, LEDS=%02h",
                  reason, cycles, uart_bytes, leds);
         $fclose(fd);
         $finish;
      end
   endtask

   always @(posedge sysclk_p) begin
      cycles = cycles + 1;
      if (cycles >= max_cycles) stop("max_cycles");
   end

   // ---- LED trace -----------------------------------------------------------
   reg [7:0] prev_leds = 8'h00;

   always @(leds) begin
      if (leds !== prev_leds) begin
         $fdisplay(fd, "LEDS %0d %02h", $time, leds);
         prev_leds = leds;
         if (stop_leds >= 0 && leds === stop_leds[7:0]) stop("stop_leds");
      end
   end

   // ---- UART receiver: 8N1, LSB first ---------------------------------------
   localparam real BIT_PERIOD_NS = 1000000000.0 / BAUD;

   reg [7:0] rx_byte;
   integer   rx_i;

   initial begin
      forever begin
         @(negedge uart_rx_out);          // start bit
         #(BIT_PERIOD_NS * 1.5);          // middle of data bit 0
         for (rx_i = 0; rx_i < 8; rx_i = rx_i + 1) begin
            rx_byte[rx_i] = uart_rx_out;
            #(BIT_PERIOD_NS);
         end
         $fdisplay(fd, "UART %02h", rx_byte);
         uart_bytes = uart_bytes + 1;
      end
   end

endmodule
