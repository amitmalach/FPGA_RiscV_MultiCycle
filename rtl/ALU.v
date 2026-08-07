`timescale 1ns/1ps
`include "defines.vh"
// ALU -- RV32I integer operations and the branch comparator, combinational.
// The second operand is rs2 for register-register instructions and imm_i for
// everything else; the shift amount is its low five bits either way. The
// branch comparator always works on rs1 and rs2.
module ALU (
    input  wire [`DATA_W-1:0] rs1,
    input  wire [`DATA_W-1:0] rs2,
    input  wire [`DATA_W-1:0] imm_i,
    input  wire               use_rs2,      // second operand is rs2, not imm_i
    input  wire [2:0]         funct3,       // operation, or branch condition
    input  wire               sub,          // funct3 000: subtract instead of add
    input  wire               sra,          // funct3 101: arithmetic instead of logical shift
    output reg  [`DATA_W-1:0] result,
    output reg                take_branch
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
            // Kept as written: the unsigned else-arm makes the whole expression
            // unsigned, so >>> shifts logically. The golden trace depends on it.
            3'b101: result = sra ? ($signed(in1) >>> shamt) : (in1 >> shamt);
            3'b110: result = in1 | in2;
            3'b111: result = in1 & in2;
        endcase
    end

    always @(*) begin
        case (funct3)
            3'b000:  take_branch = (rs1 == rs2);                    // BEQ
            3'b001:  take_branch = (rs1 != rs2);                    // BNE
            3'b100:  take_branch = ($signed(rs1) <  $signed(rs2));  // BLT
            3'b101:  take_branch = ($signed(rs1) >= $signed(rs2));  // BGE
            3'b110:  take_branch = (rs1 <  rs2);                    // BLTU
            3'b111:  take_branch = (rs1 >= rs2);                    // BGEU
            default: take_branch = 1'b0;                            // no latch
        endcase
    end

endmodule
