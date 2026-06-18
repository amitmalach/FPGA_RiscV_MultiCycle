`timescale 1ns/1ps
`include "defines.vh"
// SOC -- top level for the Digilent Genesys 2.
// Wiring only: clock and reset (IBUFDS, BUFG, Clockworks), the IO bus
// (address decode, LED register) and the RAM. The core bus is declared here;
// the core that drives it is the next layer.
// Memory map: defines.vh.
module SOC #(
    parameter integer       RAM_WORDS = `RAM_WORDS    // on-chip RAM depth in words
) (
    input  wire               sysclk_p,       // 200 MHz differential system clock
    input  wire               sysclk_n,
    input  wire               RESET,          // reset button, active-low on this board
    output wire [`LEDS_W-1:0] LEDS
);

    // ---- clock and reset ----------------------------------------------------
    wire clk_ibuf;
    wire clk;
    wire clk_enable;
    wire reset_n;

    IBUFDS sysclk_buffer (.I(sysclk_p), .IB(sysclk_n), .O(clk_ibuf));
    BUFG   sysclk_bufg   (.I(clk_ibuf), .O(clk));

    Clockworks #(
        .SLOW           (0)         // no gearbox: clk_enable high every cycle
    ) clockworks (
        .clk            (clk),
        .reset_button_n (RESET),
        .clk_enable     (clk_enable),
        .reset_n        (reset_n)
    );

    // ---- core bus -----------------------------------------------------------
    wire [`ADDR_W-1:0]  mem_addr;
    wire [`DATA_W-1:0]  mem_rdata;
    wire                mem_rstrb;
    wire [`DATA_W-1:0]  mem_wdata;
    wire [`WMASK_W-1:0] mem_wmask;
    wire                mem_rbusy;

    // ---- address decode and IO ----------------------------------------------
    wire                ram_rstrb;
    wire [`WMASK_W-1:0] ram_wmask;
    wire [`DATA_W-1:0]  ram_rdata;

    IOBus bus (
        .clk        (clk),
        .clk_enable (clk_enable),
        .reset_n    (reset_n),
        .mem_addr   (mem_addr),
        .mem_rdata  (mem_rdata),
        .mem_rstrb  (mem_rstrb),
        .mem_wdata  (mem_wdata),
        .mem_wmask  (mem_wmask),
        .mem_rbusy  (mem_rbusy),
        .ram_rstrb  (ram_rstrb),
        .ram_wmask  (ram_wmask),
        .ram_rdata  (ram_rdata),
        .leds       (LEDS)
    );

    // ---- RAM ----------------------------------------------------------------
    Memory #(
        .WORDS      (RAM_WORDS)
    ) ram (
        .clk        (clk),
        .clk_enable (clk_enable),
        .mem_addr   (mem_addr),
        .mem_rdata  (ram_rdata),
        .mem_rstrb  (ram_rstrb),
        .mem_wdata  (mem_wdata),
        .mem_wmask  (ram_wmask)
    );

endmodule
