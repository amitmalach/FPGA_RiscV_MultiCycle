`timescale 1ns/1ps
// FlashRegsBench -- runs the writing FlashRegs against FlashModel with short waits, and decodes
// its UART line. From the repository root with Vivado's settings64.sh sourced (the unisim
// models of IBUFDS, BUFG and STARTUPE2 come from the Vivado install):
//
//   U=$XILINX_VIVADO/data/verilog/src/unisims; F=docs/design/scripts/flashregs
//   iverilog -g2005 -I rtl -o /tmp/FlashRegsBench.vvp $F/FlashRegsBench.v $F/FlashModel.v \
//       $F/FlashRegs.v rtl/Clockworks.v rtl/UartTx.v $U/IBUFDS.v $U/BUFG.v $U/STARTUPE2.v \
//       $XILINX_VIVADO/data/verilog/src/glbl.v && vvp -n /tmp/FlashRegsBench.vvp
//
// Prints the model's commands and the tool's lines: "SR1=00 CR1=00 ID=010219 D30=AA995566",
// then, after the write, "SR1=00 CR1=02 ID=010219 D30=AA995566W" and that line once a pass.
// No pass/fail line: the reader compares. A wrong edge for sampling miso goes unnoticed here
// (FlashModel.v says why); the other faults tried, a swapped or missing WRR byte, no WREN, no
// WIP poll, LSB first, show in the lines.
module FlashRegsBench;
    localparam integer CLK_HZ = 200000000, BAUD = CLK_HZ / 16;
    reg clk = 1'b0; always #2.5 clk = ~clk;
    reg reset_n = 1'b0;
    wire [7:0] leds; wire tx, cs_n, mosi, miso;
    FlashRegs #(.WRITE_REGS(1), .UART_BAUD(BAUD), .SPI_HALF(4), .PASS_WAIT(20000),
                .EOS_WAIT(100)) dut (
        .sysclk_p(clk), .sysclk_n(~clk), .RESET(reset_n), .LEDS(leds), .uart_tx_in(1'b1),
        .uart_rx_out(tx), .spiflash_csn(cs_n), .spiflash_mosi(mosi), .spiflash_miso(miso));
    FlashModel flash (.cs_n(cs_n), .sclk(dut.sclk), .mosi(mosi), .miso(miso));
    // UART decoder
    integer i; reg [7:0] ch;
    always @(negedge tx) begin
        #(16 * 5 * 1.5);
        for (i = 0; i < 8; i = i + 1) begin ch[i] = tx; #(16 * 5); end
        $write("%c", ch);
    end
    initial begin
        #100 reset_n = 1'b1;
        #1500000;
        $display("\nBENCH end: leds=%02x", leds);
        $finish;
    end
endmodule
