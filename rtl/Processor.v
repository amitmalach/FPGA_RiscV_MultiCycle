`timescale 1ns/1ps
`include "defines.vh"
// Processor -- multi-cycle RV32I core.
// Instantiates the decoder, ALU, register file and control FSM and keeps the
// datapath glue: pc, the instruction register, the write-back path and the
// bus outputs. Bus: a read requested with mem_rstrb is answered on mem_rdata
// the next cycle, later if mem_rbusy is high; the write port is present but
// idle until stores arrive. Reset is synchronous.
module Processor (
    input  wire                 clk,
    input  wire                 clk_enable, // everything holds still while low
    input  wire                 reset_n,    // synchronous, active-low

    output wire [`ADDR_W-1:0]   mem_addr,
    input  wire [`DATA_W-1:0]   mem_rdata,
    output wire                 mem_rstrb,  // one-cycle read request at mem_addr
    output wire [`DATA_W-1:0]   mem_wdata,
    output wire [`WMASK_W-1:0]  mem_wmask,  // per-byte write enable, zero for now
    input  wire                 mem_rbusy   // read still in flight, mem_rdata not valid
);

    // ADD x0, x0, x0: the instruction register's value until the first fetch lands
    localparam [`DATA_W-1:0] NOP = 32'b0000000_00000_00000_000_00000_0110011;

    reg [`ADDR_W-1:0] pc    = `RAM_BASE;
    reg [`DATA_W-1:0] instr = NOP;

    // ---- decoder ------------------------------------------------------------
    wire        is_alu_reg, is_alu_imm, is_system;
    wire [4:0]  rs1_id, rs2_id, rd_id;
    wire [2:0]  funct3;
    wire [6:0]  funct7;
    wire        alu_sub, alu_sra;
    wire [`DATA_W-1:0] imm_i;

    Decoder decoder (
        .instr      (instr),
        .is_alu_reg (is_alu_reg),
        .is_alu_imm (is_alu_imm),
        .is_system  (is_system),
        .rs1_id     (rs1_id),
        .rs2_id     (rs2_id),
        .rd_id      (rd_id),
        .funct3     (funct3),
        .funct7     (funct7),
        .alu_sub    (alu_sub),
        .alu_sra    (alu_sra),
        .imm_i      (imm_i)
    );

    // ---- control FSM --------------------------------------------------------
    wire latch_instr, read_regs, update_pc, write_rd;

    Control control (
        .clk         (clk),
        .clk_enable  (clk_enable),
        .reset_n     (reset_n),
        .mem_rbusy   (mem_rbusy),
        .is_system   (is_system),
        .mem_rstrb   (mem_rstrb),
        .latch_instr (latch_instr),
        .read_regs   (read_regs),
        .update_pc   (update_pc),
        .write_rd    (write_rd)
    );

    // ---- register file ------------------------------------------------------
    wire [`DATA_W-1:0] rs1, rs2;
    wire [`DATA_W-1:0] wb_data;

    RegisterFile register_file (
        .clk        (clk),
        .read_en    (read_regs),
        .rs1_id     (rs1_id),
        .rs2_id     (rs2_id),
        .rs1        (rs1),
        .rs2        (rs2),
        .write_en   (write_rd),
        .rd_id      (rd_id),
        .rd_data    (wb_data)
    );

    // ---- ALU ----------------------------------------------------------------
    wire [`DATA_W-1:0] alu_result;

    ALU alu (
        .rs1         (rs1),
        .rs2         (rs2),
        .imm_i       (imm_i),
        .use_rs2     (is_alu_reg),
        .funct3      (funct3),
        .sub         (alu_sub),
        .sra         (alu_sra),
        .result      (alu_result)
    );

    // ---- pc and instruction register ----------------------------------------
    wire [`ADDR_W-1:0] next_pc = pc + 32'd4;

    always @(posedge clk) begin
        if (!reset_n) begin
            pc    <= `RAM_BASE;
            instr <= NOP;
        end else begin
            if (latch_instr) instr <= mem_rdata;
            if (update_pc)   pc    <= next_pc;
        end
    end

    // ---- write-back and bus outputs -----------------------------------------
    assign wb_data = alu_result;

    assign mem_addr  = pc;
    assign mem_wdata = {`DATA_W{1'b0}};
    assign mem_wmask = {`WMASK_W{1'b0}};

endmodule
