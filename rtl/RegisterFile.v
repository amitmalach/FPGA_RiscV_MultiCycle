`timescale 1ns/1ps
`include "defines.vh"
// RegisterFile -- the 32 RV32I integer registers.
// Synchronous read: rs1 and rs2 are latched on the edge where read_en is
// high and hold until the next read. Synchronous write of rd on write_en.
// x0 is never written and always reads as 0. Both strobes arrive already
// qualified by clk_enable and reset_n (Control.v). No reset: after reset the
// core fetches an instruction before it reads any register.
module RegisterFile (
    input  wire               clk,

    input  wire               read_en,
    input  wire [4:0]         rs1_id,
    input  wire [4:0]         rs2_id,
    output reg  [`DATA_W-1:0] rs1,
    output reg  [`DATA_W-1:0] rs2,

    input  wire               write_en,
    input  wire [4:0]         rd_id,
    input  wire [`DATA_W-1:0] rd_data
);

    reg [`DATA_W-1:0] regs [0:31];

    always @(posedge clk) begin
        if (write_en && rd_id != 5'd0)
            regs[rd_id] <= rd_data;
        if (read_en) begin
            rs1 <= (rs1_id == 5'd0) ? {`DATA_W{1'b0}} : regs[rs1_id];
            rs2 <= (rs2_id == 5'd0) ? {`DATA_W{1'b0}} : regs[rs2_id];
        end
    end

endmodule
