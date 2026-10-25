`timescale 1ns/1ps
`include "defines.vh"

// ALUBench -- unit testbench for rtl/ALU.v. Drives the ALU's ports with the
// right shifts (funct3 101: SRL, SRA, SRLI, SRAI) and compares each result
// with a value worked out by hand from the RV32I specification, not from the
// RTL. Immediate operands are imm_i as the decoder produces it: SRAI carries
// funct7 = 0100000 in imm[11:5], so SRAI by 9 arrives as 0x409. Prints one
// FAIL line per mismatch and a final PASS or FAIL line; sim/run_unit.sh runs
// it under iverilog and keys on that last line.

module ALUBench();

   reg  [`DATA_W-1:0] rs1     = 0;
   reg  [`DATA_W-1:0] rs2     = 0;
   reg  [`DATA_W-1:0] imm_i   = 0;
   reg                use_rs2 = 1'b0;
   reg  [2:0]         funct3  = 3'b000;
   reg                sra     = 1'b0;
   wire [`DATA_W-1:0] result;
   wire               take_branch;   // branch comparator: not checked here

   ALU alu (
      .rs1         (rs1),
      .rs2         (rs2),
      .imm_i       (imm_i),
      .use_rs2     (use_rs2),
      .funct3      (funct3),
      .sub         (1'b0),
      .sra         (sra),
      .result      (result),
      .take_branch (take_branch)
   );

   integer cases    = 0;
   integer failures = 0;

   // One right shift: operand is rs2 when use_reg is set, else imm_i.
   task shift_right;
      input [8*24:1]      name;
      input               arith;
      input               use_reg;
      input [`DATA_W-1:0] value;
      input [`DATA_W-1:0] operand;
      input [`DATA_W-1:0] expected;
      begin
         funct3  = 3'b101;
         sra     = arith;
         use_rs2 = use_reg;
         rs1     = value;
         rs2     = use_reg ? operand : 32'hDEAD_BEEF;   // the unused operand must not matter
         imm_i   = use_reg ? 32'hDEAD_BEEF : operand;
         #1;
         cases = cases + 1;
         if (result !== expected) begin
            failures = failures + 1;
            $display("FAIL: %0s: got %h, expected %h", name, result, expected);
         end
      end
   endtask

   initial begin
      // -1544416 = 0xFFE86F20; -1544416 / 512 = -3016.4, floor -3017 = 0xFFFFF437.
      shift_right("SRA  negative by 9", 1'b1, 1'b1, 32'hFFE8_6F20, 32'd9,         32'hFFFF_F437);
      shift_right("SRAI negative by 9", 1'b1, 1'b0, 32'hFFE8_6F20, 32'h0000_0409, 32'hFFFF_F437);
      shift_right("SRL  negative by 9", 1'b0, 1'b1, 32'hFFE8_6F20, 32'd9,         32'h007F_F437);
      shift_right("SRLI negative by 9", 1'b0, 1'b0, 32'hFFE8_6F20, 32'h0000_0009, 32'h007F_F437);
      shift_right("SRA  positive by 4", 1'b1, 1'b1, 32'h7FFF_FFF0, 32'd4,         32'h07FF_FFFF);
      shift_right("SRA  min by 0",      1'b1, 1'b1, 32'h8000_0000, 32'd0,         32'h8000_0000);
      shift_right("SRA  min by 31",     1'b1, 1'b1, 32'h8000_0000, 32'd31,        32'hFFFF_FFFF);
      shift_right("SRL  min by 31",     1'b0, 1'b1, 32'h8000_0000, 32'd31,        32'h0000_0001);
      shift_right("SRA  rs2[4:0] only", 1'b1, 1'b1, 32'h8000_0000, 32'hFFFF_FFE4, 32'hF800_0000);
      if (failures == 0)
         $display("PASS: ALUBench (%0d cases)", cases);
      else
         $display("FAIL: ALUBench (%0d of %0d cases)", failures, cases);
      $finish;
   end

endmodule
