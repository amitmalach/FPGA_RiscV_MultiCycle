`timescale 1ns/1ps
`include "defines.vh"
// SPIFlash -- SPI NOR flash read controller, plain 03h Read command.
// One rstrb pulse reads one 32-bit word: spi_cs_n drops, the 8-bit opcode and the
// 24-bit byte address go out on spi_mosi, 32 data bits come back on spi_miso, spi_cs_n
// rises. rbusy is high for the whole transaction and rdata is valid only once
// it has dropped. SPI mode 0: the clock idles low, spi_mosi changes on the falling
// edge, spi_miso is sampled on the rising edge. The SPI clock is the system clock
// divided by 6 (33.3 MHz against the S25FL256S limit of 50 MHz for 03h reads).
// spi_clk reaches the chip's CCLK pin only through STARTUPE2 (SOC.v).
module SPIFlash(
    input  wire                        clk,
    input  wire                        rstrb,        // one-cycle read request
    input  wire [`SPIFLASH_ADDR_W-3:0] word_address, // byte address >> 2; 16 MB reach
    output wire [`DATA_W-1:0]          rdata,        // little-endian, valid when rbusy is low
    output wire                        rbusy,        // high from rstrb until the last bit is in

    output wire                        spi_clk,
    output reg                         spi_cs_n,
    output wire                        spi_mosi,
    input  wire                        spi_miso
);
    // ---- clock divider: one SPI period = 6 system clocks --------------------
    // Explicit initial values: X+1 stays X in simulation and the divider
    // would never start.
    reg [1:0] div = 2'd0;
    reg       sclk = 1'b0;

    // The cycle on which sclk is about to flip, not its level.
    wire      sclk_rise = (div == 2'd2) && !sclk;
    wire      sclk_fall = (div == 2'd2) &&  sclk;

    always @(posedge clk) begin
        if (spi_cs_n) begin
            // Held at reset while idle so the first pulse of a transaction is
            // a full period (a free-running divider produced a short one).
            div  <= 2'd0;
            sclk <= 1'b0;
        end else if (div == 2'd2) begin
            div  <= 2'd0;
            sclk <= !sclk;
        end else begin
            div <= div + 2'd1;
        end
    end

    // Forced low while idle: mode 0 needs the clock low before the first edge.
    assign spi_clk = spi_cs_n ? 1'b0 : sclk;

    // ---- shift registers ----------------------------------------------------
    // cmd_addr, MSB first: 8'h03, the word address, 2'b00 (makes a byte address).
    localparam [5:0] CMD_BITS  = 8 + `SPIFLASH_ADDR_W;
    localparam [5:0] DATA_BITS = `DATA_W;

    reg [5:0]            snd_bitcount;
    reg [CMD_BITS-1:0]   cmd_addr;
    reg [5:0]            rcv_bitcount;
    reg [`DATA_W-1:0]    rcv_data;

    wire       sending   = (snd_bitcount != 0);
    wire       receiving = (rcv_bitcount != 0);
    wire       busy      = sending | receiving;

    assign     rbusy     = !spi_cs_n;      // spi_cs_n is low exactly while a transaction runs
    assign     spi_mosi  = cmd_addr[CMD_BITS-1];

    initial spi_cs_n = 1'b1;

    // Bytes arrive lowest address first, MSB first, so rcv_data[31:24] is the
    // byte at the lowest address; the swap makes rdata little-endian (4-byte word).
    assign rdata = {rcv_data[7:0], rcv_data[15:8], rcv_data[23:16], rcv_data[31:24]};

    // ---- transaction --------------------------------------------------------
    always @(posedge clk) begin
        if (rstrb) begin
            // Not gated by an SPI edge: a one-cycle rstrb must never be missed.
            spi_cs_n     <= 1'b0;
            cmd_addr     <= {8'h03, word_address, 2'b00};
            snd_bitcount <= CMD_BITS;
        end else begin
            if (sending && sclk_fall) begin
                // Arm the receiver on the last command bit: no gap cycle.
                if (snd_bitcount == 1) rcv_bitcount <= DATA_BITS;
                snd_bitcount <= snd_bitcount - 6'd1;
                cmd_addr     <= {cmd_addr[CMD_BITS-2:0], 1'b1};   // the 1 is never sent
            end

            if (receiving && sclk_rise) begin
                rcv_bitcount <= rcv_bitcount - 6'd1;
                rcv_data     <= {rcv_data[`DATA_W-2:0], spi_miso};
            end

            // Deselect as soon as both phases are done, on any cycle.
            if (!busy) spi_cs_n <= 1'b1;
        end
    end
endmodule
