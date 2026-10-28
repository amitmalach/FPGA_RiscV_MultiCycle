`timescale 1ns/1ps
// FlashRegs -- read the SPI flash's Status Register 1 and Configuration Register 1 over the
// board's flash pins, print them on the UART and show CR1 on the LEDs; with WRITE_REGS=1,
// rewrite them once (WREN, then WRR with SR1_NEW and CR1_NEW), wait for the write to end and
// read them again. Each pass also reads the chip's ID (RDID 9Fh, three bytes) and four bytes
// at 0x30 (READ 03h; a bitstream's sync word, AA995566), as a check that the bits line up.
// S25FL256S opcodes: RDSR1 05h, RDCR 35h, WREN 06h, WRR 01h, RDID 9Fh, READ 03h.
// Why: Vivado's flash programming clears the Quad Enable bit (CR1 bit 1) unless told not to,
// the bitstream the board boots at power-on needs it, and Vivado's Tcl reads no flash register
// (docs/design/figures/README.md, "The Quad Enable bit"). Built by build.tcl beside this file,
// loaded over JTAG with docs/design/scripts/board_program.tcl; the flash's data is never
// written, only its registers, once, with WRITE_REGS=1. Plain SPI mode 0, one bit wide: the
// clock idles low, mosi changes on the falling edge, miso is sampled on the rising edge. The
// SPI clock reaches the chip's CCLK pin only through STARTUPE2, which passes USRCCLKO on only
// after a few edges, so each pass starts with eight clocks while chip select is high.
// A line per pass: "SR1=xx CR1=xx ID=xxxxxx D30=xxxxxxxx" plus "W" on the pass after the write.
module FlashRegs #(
    parameter         WRITE_REGS = 0,
    parameter [7:0]   SR1_NEW    = 8'h00,
    parameter [7:0]   CR1_NEW    = 8'h02,       // QUAD = 1, LC = 00; OTP bits 2, 3, 5 written 0
    parameter integer CLK_HZ     = 200000000,
    parameter integer UART_BAUD  = 115200,
    parameter integer SPI_HALF   = 64,          // system clocks per SPI half period
    parameter integer PASS_WAIT  = 200000000,   // system clocks between passes (1 s)
    parameter integer EOS_WAIT   = 1000000      // system clocks after end of startup (5 ms)
) (
    input  wire       sysclk_p,
    input  wire       sysclk_n,
    input  wire       RESET,          // active-low button
    output wire [7:0] LEDS,           // CR1 as last read
    input  wire       uart_tx_in,     // unused
    output wire       uart_rx_out,    // the FPGA's transmit line
    output reg        spiflash_csn,
    output wire       spiflash_mosi,
    input  wire       spiflash_miso
);
    wire clk_ibuf, clk, clk_enable, reset_n, eos;
    IBUFDS sysclk_buffer (.I(sysclk_p), .IB(sysclk_n), .O(clk_ibuf));
    BUFG   sysclk_bufg   (.I(clk_ibuf), .O(clk));
    Clockworks #(.SLOW(0)) clockworks (
        .clk(clk), .reset_button_n(RESET), .clk_enable(clk_enable), .reset_n(reset_n));

    // ---- SPI byte engine ----------------------------------------------------
    reg        spi_start;
    reg  [7:0] spi_out;
    reg        spi_active = 1'b0;
    reg        sclk = 1'b0;
    reg [15:0] div_cnt = 16'd0;
    reg  [3:0] bit_cnt = 4'd0;
    reg  [7:0] sh_out = 8'd0;
    reg  [7:0] sh_in = 8'd0;
    always @(posedge clk) begin
        if (!reset_n) begin
            spi_active <= 1'b0; sclk <= 1'b0; div_cnt <= 16'd0;
        end else if (spi_start && !spi_active) begin
            spi_active <= 1'b1; sh_out <= spi_out; bit_cnt <= 4'd0; div_cnt <= 16'd0; sclk <= 1'b0;
        end else if (spi_active) begin
            if (div_cnt == SPI_HALF - 1) begin
                div_cnt <= 16'd0;
                if (!sclk) begin
                    sclk  <= 1'b1;                         // rising edge: sample
                    sh_in <= {sh_in[6:0], spiflash_miso};
                end else begin
                    sclk    <= 1'b0;                       // falling edge: shift
                    sh_out  <= {sh_out[6:0], 1'b0};
                    bit_cnt <= bit_cnt + 4'd1;
                    if (bit_cnt == 4'd7) spi_active <= 1'b0;
                end
            end else begin
                div_cnt <= div_cnt + 16'd1;
            end
        end
    end
    assign spiflash_mosi = sh_out[7];

    STARTUPE2 #(.PROG_USR("FALSE"), .SIM_CCLK_FREQ(0.0)) spiflash_cclk_access (
        .CLK(1'b0), .GSR(1'b0), .GTS(1'b0), .KEYCLEARB(1'b1), .PACK(1'b0),
        .USRCCLKO(sclk), .USRCCLKTS(1'b0), .USRDONEO(1'b1), .USRDONETS(1'b1),
        .CFGCLK(), .CFGMCLK(), .EOS(eos), .PREQ());

    // ---- UART ---------------------------------------------------------------
    reg        uart_valid;
    reg  [7:0] uart_data;
    wire       uart_ready;
    UartTx #(.CLK_HZ(CLK_HZ), .BAUD(UART_BAUD)) uart (
        .clk(clk), .reset_n(reset_n), .data(uart_data), .valid(uart_valid),
        .ready(uart_ready), .tx(uart_rx_out));

    function [7:0] hexdigit(input [3:0] n);
        hexdigit = (n < 4'd10) ? (8'h30 + n) : (8'h41 + n - 8'd10);
    endfunction

    // ---- the micro-program --------------------------------------------------
    // One byte per step: {dummy (chip select high), last byte of the transaction, byte to
    // send, register to capture the byte into (R_NONE: none)}.
    localparam [3:0] R_NONE = 4'd15, R_SR1 = 4'd0, R_CR1 = 4'd1, R_ID0 = 4'd2, R_ID1 = 4'd3,
                     R_ID2 = 4'd4, R_D0 = 4'd5, R_D1 = 4'd6, R_D2 = 4'd7, R_D3 = 4'd8,
                     R_POLL = 4'd9;
    localparam [5:0] P_DUMMY = 6'd0, P_PRINT = 6'd17, P_WREN = 6'd18, P_POLL = 6'd22,
                     P_POLL_DECIDE = 6'd24, P_PASS_WAIT = 6'd25;
    function [13:0] step(input [5:0] i);       // {dummy, last, tx[7:0], cap[3:0]}
        case (i)
            6'd0:  step = {1'b1, 1'b1, 8'hFF,   R_NONE};   // eight clocks, chip select high
            6'd1:  step = {1'b0, 1'b0, 8'h05,   R_NONE};   // RDSR1
            6'd2:  step = {1'b0, 1'b1, 8'h00,   R_SR1};
            6'd3:  step = {1'b0, 1'b0, 8'h35,   R_NONE};   // RDCR
            6'd4:  step = {1'b0, 1'b1, 8'h00,   R_CR1};
            6'd5:  step = {1'b0, 1'b0, 8'h9F,   R_NONE};   // RDID
            6'd6:  step = {1'b0, 1'b0, 8'h00,   R_ID0};
            6'd7:  step = {1'b0, 1'b0, 8'h00,   R_ID1};
            6'd8:  step = {1'b0, 1'b1, 8'h00,   R_ID2};
            6'd9:  step = {1'b0, 1'b0, 8'h03,   R_NONE};   // READ 0x000030
            6'd10: step = {1'b0, 1'b0, 8'h00,   R_NONE};
            6'd11: step = {1'b0, 1'b0, 8'h00,   R_NONE};
            6'd12: step = {1'b0, 1'b0, 8'h30,   R_NONE};
            6'd13: step = {1'b0, 1'b0, 8'h00,   R_D0};
            6'd14: step = {1'b0, 1'b0, 8'h00,   R_D1};
            6'd15: step = {1'b0, 1'b0, 8'h00,   R_D2};
            6'd16: step = {1'b0, 1'b1, 8'h00,   R_D3};
            // 17: print
            6'd18: step = {1'b0, 1'b1, 8'h06,   R_NONE};   // WREN
            6'd19: step = {1'b0, 1'b0, 8'h01,   R_NONE};   // WRR
            6'd20: step = {1'b0, 1'b0, SR1_NEW, R_NONE};
            6'd21: step = {1'b0, 1'b1, CR1_NEW, R_NONE};
            6'd22: step = {1'b0, 1'b0, 8'h05,   R_NONE};   // RDSR1, polling WIP
            6'd23: step = {1'b0, 1'b1, 8'h00,   R_POLL};
            // 24: decide, 25: wait between passes
            default: step = {1'b1, 1'b1, 8'hFF, R_NONE};
        endcase
    endfunction

    // ---- sequencer ----------------------------------------------------------
    localparam [2:0] S_WAIT_EOS = 3'd0, S_STEP = 3'd1, S_XFER = 3'd2, S_GAP = 3'd3,
                     S_PRINT = 3'd4, S_WAIT = 3'd5;
    reg  [2:0]  state = S_WAIT_EOS;
    reg  [5:0]  pc = P_DUMMY;
    reg  [13:0] cur;
    wire [13:0] cur_step = step(pc);
    reg  [7:0]  captured [0:9];         // the bytes read, indexed R_*
    reg         written = 1'b0;         // the one write has been done
    reg         wrote_msg = 1'b0;       // this print is the line after the write
    reg  [31:0] wait_cnt = 32'd0;
    reg  [7:0]  msg [0:39];
    reg  [5:0]  msg_len, msg_i;
    integer     k;
    initial for (k = 0; k < 10; k = k + 1) captured[k] = 8'hFF;
    assign LEDS = captured[R_CR1];

    always @(posedge clk) begin
        spi_start  <= 1'b0;
        uart_valid <= 1'b0;
        if (!reset_n) begin
            state <= S_WAIT_EOS; pc <= P_DUMMY; spiflash_csn <= 1'b1; written <= 1'b0;
            wrote_msg <= 1'b0; wait_cnt <= 32'd0;
        end else case (state)
            S_WAIT_EOS: begin
                spiflash_csn <= 1'b1;
                if (eos) begin
                    if (wait_cnt == EOS_WAIT) begin wait_cnt <= 32'd0; state <= S_STEP; end
                    else wait_cnt <= wait_cnt + 32'd1;
                end
            end
            S_STEP: begin
                if (pc == P_PRINT) begin
                    state <= S_PRINT;
                end else if (pc == P_POLL_DECIDE) begin
                    if (captured[R_POLL][0]) pc <= P_POLL;                  // WIP still set
                    else begin written <= 1'b1; wrote_msg <= 1'b1; pc <= P_DUMMY; end
                end else if (pc == P_PASS_WAIT) begin
                    wrote_msg <= 1'b0; state <= S_WAIT;
                end else begin
                    cur <= cur_step;
                    spiflash_csn <= cur_step[13];
                    spi_out <= cur_step[11:4];
                    spi_start <= 1'b1;
                    state <= S_XFER;
                end
            end
            S_XFER: begin                        // wait for the byte engine
                if (!spi_active && !spi_start) begin
                    if (cur[3:0] != R_NONE) captured[cur[3:0]] <= sh_in;
                    pc <= pc + 6'd1;
                    if (cur[12]) begin spiflash_csn <= 1'b1; state <= S_GAP; end
                    else state <= S_STEP;
                end
            end
            S_GAP: begin                         // chip select high between transactions
                if (wait_cnt == SPI_HALF * 4) begin wait_cnt <= 32'd0; state <= S_STEP; end
                else wait_cnt <= wait_cnt + 32'd1;
            end
            S_PRINT: begin
                if (wait_cnt == 32'd0) begin
                    msg[0] <= "S"; msg[1] <= "R"; msg[2] <= "1"; msg[3] <= "=";
                    msg[4] <= hexdigit(captured[R_SR1][7:4]);
                    msg[5] <= hexdigit(captured[R_SR1][3:0]);
                    msg[6] <= " "; msg[7] <= "C"; msg[8] <= "R"; msg[9] <= "1"; msg[10] <= "=";
                    msg[11] <= hexdigit(captured[R_CR1][7:4]);
                    msg[12] <= hexdigit(captured[R_CR1][3:0]);
                    msg[13] <= " "; msg[14] <= "I"; msg[15] <= "D"; msg[16] <= "=";
                    msg[17] <= hexdigit(captured[R_ID0][7:4]);
                    msg[18] <= hexdigit(captured[R_ID0][3:0]);
                    msg[19] <= hexdigit(captured[R_ID1][7:4]);
                    msg[20] <= hexdigit(captured[R_ID1][3:0]);
                    msg[21] <= hexdigit(captured[R_ID2][7:4]);
                    msg[22] <= hexdigit(captured[R_ID2][3:0]);
                    msg[23] <= " "; msg[24] <= "D"; msg[25] <= "3"; msg[26] <= "0"; msg[27] <= "=";
                    msg[28] <= hexdigit(captured[R_D0][7:4]);
                    msg[29] <= hexdigit(captured[R_D0][3:0]);
                    msg[30] <= hexdigit(captured[R_D1][7:4]);
                    msg[31] <= hexdigit(captured[R_D1][3:0]);
                    msg[32] <= hexdigit(captured[R_D2][7:4]);
                    msg[33] <= hexdigit(captured[R_D2][3:0]);
                    msg[34] <= hexdigit(captured[R_D3][7:4]);
                    msg[35] <= hexdigit(captured[R_D3][3:0]);
                    msg[36] <= wrote_msg ? "W" : " "; msg[37] <= 8'h0D; msg[38] <= 8'h0A;
                    msg_len <= 6'd39; msg_i <= 6'd0; wait_cnt <= 32'd1;
                end else if (msg_i == msg_len) begin
                    wait_cnt <= 32'd0; state <= S_STEP;
                    if (WRITE_REGS && !written) pc <= P_WREN; else pc <= P_PASS_WAIT;
                end else if (uart_ready && !uart_valid) begin
                    uart_data <= msg[msg_i]; uart_valid <= 1'b1; msg_i <= msg_i + 6'd1;
                end
            end
            S_WAIT: begin
                if (wait_cnt == PASS_WAIT) begin
                    wait_cnt <= 32'd0; pc <= P_DUMMY; state <= S_STEP;
                end
                else wait_cnt <= wait_cnt + 32'd1;
            end
            default: state <= S_WAIT_EOS;
        endcase
    end
endmodule
