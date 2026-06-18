`timescale 1ns/1ps
`include "defines.vh"
// IOBus -- address decoder and IO bus.
// Owns the memory map (defines.vh): selects RAM or IO space for each core
// access, holds the LED register and muxes read data back to the core.
// RAM and IO answer a read the cycle after the strobe; nothing stalls the
// core, so mem_rbusy is tied low. Any RAM access is masked off outside RAM
// space.
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

    // peripherals
    output reg  [`LEDS_W-1:0]          leds
);

    // ---- region select ------------------------------------------------------
    wire is_io       = |(mem_addr & `IO_BASE);
    wire is_ram      = !is_io;
    wire mem_wstrb   = |mem_wmask;
    wire io_write    = clk_enable & is_io & mem_wstrb;

    // ---- RAM ----------------------------------------------------------------
    assign ram_rstrb = is_ram & mem_rstrb;
    assign ram_wmask = {`WMASK_W{is_ram}} & mem_wmask;
    assign mem_rbusy = 1'b0;   // RAM and IO never stall

    // ---- LED register -------------------------------------------------------
    // Reset is not gated by clk_enable; the write is.
    always @(posedge clk) begin
        if (!reset_n)
            leds <= {`LEDS_W{1'b0}};
        else if (io_write && |(mem_addr & `IO_LEDS))
            leds <= mem_wdata[`LEDS_W-1:0];
    end

    // ---- read mux -----------------------------------------------------------
    // LEDS is write-only and reads as 0.
    assign mem_rdata = is_ram ? ram_rdata : {`DATA_W{1'b0}};

endmodule
