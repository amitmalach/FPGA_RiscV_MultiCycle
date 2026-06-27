`timescale 1ns/1ps
`include "defines.vh"
// ALU -- RV32I integer operations, combinational.
// The second operand is rs2 for register-register instructions and imm_i for
// everything else; the shift amount is its low five bits either way.
module ALU (
    input  wire [`DATA_W-1:0] rs1,
    input  wire [`DATA_W-1:0] rs2,
    input  wire [`DATA_W-1:0] imm_i,
    input  wire               use_rs2,      // second operand is rs2, not imm_i
    input  wire [2:0]         funct3,       // operation
    input  wire               sub,          // funct3 000: subtract instead of add
    input  wire               sra,          // funct3 101: arithmetic instead of logical shift
    output reg  [`DATA_W-1:0] result
);

    wire [`DATA_W-1:0] in1   = rs1;
    wire [`DATA_W-1:0] in2   = use_rs2 ? rs2 : imm_i;
    wire [4:0]         shamt = in2[4:0];

    always @(*) begin
        case (funct3)
            3'b000: result = sub ? (in1 - in2) : (in1 + in2);
            3'b001: result = in1 << shamt;
            3'b010: result = {{(`DATA_W-1){1'b0}}, ($signed(in1) < $signed(in2))};
            3'b011: result = {{(`DATA_W-1){1'b0}}, (in1 < in2)};
            3'b100: result = in1 ^ in2;
            3'b101: result = sra ? ($signed(in1) >>> shamt) : (in1 >> shamt);
            3'b110: result = in1 | in2;
            3'b111: result = in1 & in2;
        endcase
    end

endmodule
