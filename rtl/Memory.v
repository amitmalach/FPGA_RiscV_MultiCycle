`timescale 1ns / 1ps
`include "defines.vh"
// Memory -- program and data RAM: WORDS words of block RAM (default RAM_WORDS,
// 6 KB), one port shared by instruction fetch and load/store. A read is
// registered: the word requested with mem_rstrb appears on mem_rdata the next
// cycle. A write lands on the edge its address, data and mask are presented,
// one byte lane per mem_wmask bit, so the core needs no wait state after a
// store. The initial contents come from firmware.hex (one word per line,
// written by make -C fw), resolved by bare name against the working directory
// of the tool that reads it; a missing file leaves the RAM at X without an
// error.
module Memory #(
    parameter integer WORDS = `RAM_WORDS
) (
    input  wire                 clk,
    input  wire                 clk_enable,
    input  wire [`ADDR_W-1:0]   mem_addr,   // byte address; bits [1:0] are ignored
    output reg  [`DATA_W-1:0]   mem_rdata,  // valid the cycle after mem_rstrb
    input  wire                 mem_rstrb,
    input  wire [`DATA_W-1:0]   mem_wdata,
    input  wire [`WMASK_W-1:0]  mem_wmask   // per-byte write enable; zero means no write
);

    reg [`DATA_W-1:0] ram [0:WORDS-1];

    initial begin
        $readmemh("firmware.hex", ram);
    end

    always @(posedge clk) begin
        if (clk_enable) begin
            if (mem_rstrb) begin
                mem_rdata <= ram[mem_addr[`ADDR_W-1:2]];
            end
            if (mem_wmask[0]) ram[mem_addr[`ADDR_W-1:2]][ 7: 0] <= mem_wdata[ 7: 0];
            if (mem_wmask[1]) ram[mem_addr[`ADDR_W-1:2]][15: 8] <= mem_wdata[15: 8];
            if (mem_wmask[2]) ram[mem_addr[`ADDR_W-1:2]][23:16] <= mem_wdata[23:16];
            if (mem_wmask[3]) ram[mem_addr[`ADDR_W-1:2]][31:24] <= mem_wdata[31:24];
        end
    end

endmodule
