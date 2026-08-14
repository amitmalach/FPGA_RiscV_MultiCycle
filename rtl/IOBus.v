`timescale 1ns/1ps
`include "defines.vh"
// IOBus -- address decoder and IO bus.
// Owns the memory map (defines.vh): selects RAM, IO or SPI-flash space for
// each core access, holds the LED register, handshakes with the UART
// transmitter and the flash controller, and muxes read data back to the core.
// RAM and IO answer a read the cycle after the strobe; only flash stalls the
// core, via mem_rbusy. Any RAM access is masked off outside RAM space.
module IOBus (
    input  wire                        clk,
    input  wire                        clk_enable,
    input  wire                        reset_n,

    // core bus
    input  wire [`ADDR_W-1:0]          mem_addr,
    output wire [`DATA_W-1:0]          mem_rdata,
    input  wire                        mem_rstrb,
    input  wire [`DATA_W-1:0]          mem_wdata,
    input  wire [`WMASK_W-1:0]         mem_wmask,
    output wire                        mem_rbusy,

    // RAM (address and write data go straight from the core)
    output wire                        ram_rstrb,
    output wire [`WMASK_W-1:0]         ram_wmask,
    input  wire [`DATA_W-1:0]          ram_rdata,

    // SPI flash controller
    input  wire                        spiflash_eos,       // STARTUPE2 end-of-startup
    output wire                        spiflash_rstrb,
    output wire [`SPIFLASH_ADDR_W-3:0] spiflash_word_addr, // word index inside flash space
    input  wire [`DATA_W-1:0]          spiflash_rdata,
    input  wire                        spiflash_rbusy,

    // peripherals
    output reg  [`LEDS_W-1:0]          leds,
    output wire                        uart_valid,         // one-cycle "send uart_data"
    output wire [7:0]                  uart_data,
    input  wire                        uart_ready
);

    // ---- region select ------------------------------------------------------
    wire is_spiflash = |(mem_addr & `SPIFLASH_BASE);
    wire is_io       = |(mem_addr & `IO_BASE) & !is_spiflash;
    wire is_ram      = !is_io & !is_spiflash;
    wire mem_wstrb   = |mem_wmask;
    wire io_write    = clk_enable & is_io & mem_wstrb;

    // ---- RAM ----------------------------------------------------------------
    assign ram_rstrb = is_ram & mem_rstrb;
    assign ram_wmask = {`WMASK_W{is_ram}} & mem_wmask;

    // ---- SPI flash ----------------------------------------------------------
    assign spiflash_rstrb     = clk_enable & is_spiflash & mem_rstrb & spiflash_eos;
    assign spiflash_word_addr = mem_addr[`SPIFLASH_ADDR_W-1:2];
    assign mem_rbusy          = spiflash_rbusy;   // RAM and IO never stall

    // ---- LED register -------------------------------------------------------
    // Reset is not gated by clk_enable; the write is.
    always @(posedge clk) begin
        if (!reset_n)
            leds <= {`LEDS_W{1'b0}};
        else if (io_write && |(mem_addr & `IO_LEDS))
            leds <= mem_wdata[`LEDS_W-1:0];
    end

    // ---- UART ---------------------------------------------------------------
    assign uart_valid = io_write & |(mem_addr & `IO_UART_DAT);
    assign uart_data  = mem_wdata[7:0];

    // Status word: bit UART_BUSY_BIT = transmitter busy, all else 0. The only
    // readable IO register; LEDS and UART_DAT read as 0.
    wire [`DATA_W-1:0] uart_status =
        {{(`DATA_W-1-`UART_BUSY_BIT){1'b0}}, !uart_ready, {`UART_BUSY_BIT{1'b0}}};
    wire [`DATA_W-1:0] io_rdata = |(mem_addr & `IO_UART_CNTL) ? uart_status : {`DATA_W{1'b0}};

    // ---- read mux -----------------------------------------------------------
    assign mem_rdata = is_ram      ? ram_rdata :
                       is_spiflash ? spiflash_rdata :
                                     io_rdata;

endmodule
