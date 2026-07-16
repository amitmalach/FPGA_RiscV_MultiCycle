// SPDX-FileCopyrightText: 2023 Olof Kindgren <olof@award-winning.me>
// SPDX-License-Identifier: Apache-2.0
// Origin: emitter_uart.v (module corescore_emitter_uart) from CoreScore
// (https://github.com/olofk/corescore), as redistributed by learn-fpga.
// Modified for this project: module and ports renamed, reset made active-low,
// parameters typed integer, timescale added, comments rewritten.
//
// UartTx -- UART transmitter, 8N1, LSB first.
// valid high for one clock sends data; ready is low until the stop bit has
// been sent. Bit period = CLK_HZ / BAUD clocks. tx is the line the FPGA
// transmits on: the PC's RX, port uart_rx_out on the SoC top.
`timescale 1ns/1ps

module UartTx #(
    parameter integer CLK_HZ = 200000000,
    parameter integer BAUD   = 115200
) (
    input  wire       clk,
    input  wire       reset_n,
    input  wire [7:0] data,
    input  wire       valid,     // one-clock pulse: send data

    output reg        ready,     // high when a new byte can be accepted
    output reg        tx
);

    localparam integer CLKS_PER_BIT  = CLK_HZ / BAUD;
    localparam integer CLK_CNT_WIDTH = $clog2(CLKS_PER_BIT);

    localparam IDLE = 1'b0;
    localparam SEND = 1'b1;

    reg state;
    reg [CLK_CNT_WIDTH-1:0] clk_cnt;    // clocks into the current bit
    reg [3:0] bit_index;                // 0 start, 1..8 data, 9 stop
    reg [9:0] frame;                    // {stop, data[7:0], start}, sent from bit 0

    always @(posedge clk) begin
        if (!reset_n) begin
            // The line idles high.
            state     <= IDLE;
            ready     <= 1'b1;
            tx        <= 1'b1;
            clk_cnt   <= {CLK_CNT_WIDTH{1'b0}};
            bit_index <= 4'd0;
            frame     <= 10'b1111111111;

        end else begin
            case (state)

                IDLE: begin
                    tx        <= 1'b1;
                    ready     <= 1'b1;
                    clk_cnt   <= {CLK_CNT_WIDTH{1'b0}};
                    bit_index <= 4'd0;

                    if (valid) begin
                        frame <= {1'b1, data, 1'b0};
                        tx    <= 1'b0;              // start bit goes out now
                        ready <= 1'b0;
                        state <= SEND;
                    end
                end

                SEND: begin
                    ready <= 1'b0;

                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= {CLK_CNT_WIDTH{1'b0}};

                        if (bit_index == 4'd9) begin
                            state     <= IDLE;
                            ready     <= 1'b1;
                            tx        <= 1'b1;
                            bit_index <= 4'd0;

                        end else begin
                            bit_index <= bit_index + 4'd1;
                            frame     <= {1'b1, frame[9:1]};
                            tx        <= frame[1];
                        end

                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

            endcase
        end
    end

endmodule
