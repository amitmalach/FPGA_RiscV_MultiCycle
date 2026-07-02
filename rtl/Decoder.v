`timescale 1ns/1ps
`include "defines.vh"
// Decoder -- RV32I instruction fields, immediates and instruction-class flags.
// Purely combinational on the instruction word. The class flags come from
// disjoint opcodes, so at most one is high.
module Decoder (
    input  wire [`DATA_W-1:0] instr,

    // instruction class, from the 7-bit opcode
    output wire               is_alu_reg,   // R-type: rd <- rs1 OP rs2
    output wire               is_alu_imm,   // I-type: rd <- rs1 OP imm_i
    output wire               is_branch,    // B-type: if (rs1 OP rs2) pc <- pc + imm_b
    output wire               is_jalr,      // I-type: rd <- pc + 4; pc <- rs1 + imm_i
    output wire               is_jal,       // J-type: rd <- pc + 4; pc <- pc + imm_j
    output wire               is_auipc,     // U-type: rd <- pc + imm_u
    output wire               is_lui,       // U-type: rd <- imm_u
    output wire               is_system,    // ECALL / EBREAK

    // register indices and function fields, at fixed positions in every format
    output wire [4:0]         rs1_id,
    output wire [4:0]         rs2_id,
    output wire [4:0]         rd_id,
    output wire [2:0]         funct3,
    output wire [6:0]         funct7,
    output wire               alu_sub,      // funct3 000 is SUB, not ADD
    output wire               alu_sra,      // funct3 101 is SRA, not SRL

    // immediates, sign-extended from instr[31]; imm_b and imm_j have bit 0 forced to 0
    output wire [`DATA_W-1:0] imm_u,
    output wire [`DATA_W-1:0] imm_i,
    output wire [`DATA_W-1:0] imm_b,
    output wire [`DATA_W-1:0] imm_j
);

    wire [6:0] opcode = instr[6:0];

    assign is_alu_reg = (opcode == 7'b0110011);
    assign is_alu_imm = (opcode == 7'b0010011);
    assign is_branch  = (opcode == 7'b1100011);
    assign is_jalr    = (opcode == 7'b1100111);
    assign is_jal     = (opcode == 7'b1101111);
    assign is_auipc   = (opcode == 7'b0010111);
    assign is_lui     = (opcode == 7'b0110111);
    assign is_system  = (opcode == 7'b1110011);

    assign rs1_id = instr[19:15];
    assign rs2_id = instr[24:20];
    assign rd_id  = instr[11:7];
    assign funct3 = instr[14:12];
    assign funct7 = instr[31:25];

    // instr[5] is set for the register-register form; there is no SUBI, so an
    // ADDI with instr[30] set must still add.
    assign alu_sub = funct7[5] & instr[5];
    assign alu_sra = funct7[5];

    assign imm_u = {    instr[31],   instr[30:12], {12{1'b0}}};
    assign imm_i = {{21{instr[31]}}, instr[30:20]};
    assign imm_b = {{20{instr[31]}}, instr[7],  instr[30:25], instr[11:8], 1'b0};
    assign imm_j = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};

endmodule
