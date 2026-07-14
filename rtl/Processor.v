`timescale 1ns/1ps
`include "defines.vh"
// Processor -- multi-cycle RV32I core.
// Instantiates the decoder, ALU, register file and control FSM and keeps the
// datapath glue: pc, the instruction register, next-pc and load/store address
// adders, byte-lane alignment for narrow loads and stores, the write-back mux
// and the bus outputs. Bus: a read requested with mem_rstrb is answered on
// mem_rdata the next cycle, later if mem_rbusy is high; a write is performed
// on the edge where mem_wmask is non-zero. Reset is synchronous.
module Processor (
    input  wire                 clk,
    input  wire                 clk_enable, // everything holds still while low
    input  wire                 reset_n,    // synchronous, active-low

    output wire [`ADDR_W-1:0]   mem_addr,
    input  wire [`DATA_W-1:0]   mem_rdata,
    output wire                 mem_rstrb,  // one-cycle read request at mem_addr
    output wire [`DATA_W-1:0]   mem_wdata,
    output wire [`WMASK_W-1:0]  mem_wmask,  // per-byte write enable, zero outside STORE
    input  wire                 mem_rbusy   // read still in flight, mem_rdata not valid
);

    // ADD x0, x0, x0: the instruction register's value until the first fetch lands
    localparam [`DATA_W-1:0] NOP = 32'b0000000_00000_00000_000_00000_0110011;

    reg [`ADDR_W-1:0] pc    = `RAM_BASE;
    reg [`DATA_W-1:0] instr = NOP;

    // ---- decoder ------------------------------------------------------------
    wire        is_alu_reg, is_alu_imm, is_branch, is_jalr, is_jal;
    wire        is_auipc, is_lui, is_load, is_store, is_system;
    wire [4:0]  rs1_id, rs2_id, rd_id;
    wire [2:0]  funct3;
    wire [6:0]  funct7;
    wire        alu_sub, alu_sra;
    wire [`DATA_W-1:0] imm_u, imm_i, imm_s, imm_b, imm_j;

    Decoder decoder (
        .instr      (instr),
        .is_alu_reg (is_alu_reg),
        .is_alu_imm (is_alu_imm),
        .is_branch  (is_branch),
        .is_jalr    (is_jalr),
        .is_jal     (is_jal),
        .is_auipc   (is_auipc),
        .is_lui     (is_lui),
        .is_load    (is_load),
        .is_store   (is_store),
        .is_system  (is_system),
        .rs1_id     (rs1_id),
        .rs2_id     (rs2_id),
        .rd_id      (rd_id),
        .funct3     (funct3),
        .funct7     (funct7),
        .alu_sub    (alu_sub),
        .alu_sra    (alu_sra),
        .imm_u      (imm_u),
        .imm_i      (imm_i),
        .imm_s      (imm_s),
        .imm_b      (imm_b),
        .imm_j      (imm_j)
    );

    // ---- control FSM --------------------------------------------------------
    wire fetching, storing, latch_instr, read_regs, update_pc, write_rd;

    Control control (
        .clk         (clk),
        .clk_enable  (clk_enable),
        .reset_n     (reset_n),
        .mem_rbusy   (mem_rbusy),
        .is_load     (is_load),
        .is_store    (is_store),
        .is_branch   (is_branch),
        .is_system   (is_system),
        .fetching    (fetching),
        .mem_rstrb   (mem_rstrb),
        .storing     (storing),
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
    wire        take_branch;

    ALU alu (
        .rs1         (rs1),
        .rs2         (rs2),
        .imm_i       (imm_i),
        .use_rs2     (is_alu_reg),
        .funct3      (funct3),
        .sub         (alu_sub),
        .sra         (alu_sra),
        .result      (alu_result),
        .take_branch (take_branch)
    );

    // ---- pc and instruction register ----------------------------------------
    // jalr_target is named so bit 0 can be cleared by slicing.
    wire [`ADDR_W-1:0] jalr_target = rs1 + imm_i;
    wire [`ADDR_W-1:0] next_pc = (is_branch && take_branch) ? pc + imm_b :
                                 is_jal                     ? pc + imm_j :
                                 is_jalr                    ? {jalr_target[31:1], 1'b0} :
                                                              pc + 32'd4;

    always @(posedge clk) begin
        if (!reset_n) begin
            pc    <= `RAM_BASE;
            instr <= NOP;
        end else begin
            if (latch_instr) instr <= mem_rdata;
            if (update_pc)   pc    <= next_pc;
        end
    end

    // ---- load and store alignment -------------------------------------------
    // Memory moves whole words; funct3[1:0] (00 byte, 01 halfword, 10 word)
    // and the address low bits pick the lane.
    wire [`ADDR_W-1:0] loadstore_addr = rs1 + (is_store ? imm_s : imm_i);
    wire        byte_access     = (funct3[1:0] == 2'b00);
    wire        halfword_access = (funct3[1:0] == 2'b01);

    wire [15:0] load_halfword = loadstore_addr[1] ? mem_rdata[31:16]    : mem_rdata[15:0];
    wire  [7:0] load_byte     = loadstore_addr[0] ? load_halfword[15:8] : load_halfword[7:0];
    wire        load_sign     = !funct3[2] & (byte_access ? load_byte[7] : load_halfword[15]);
    wire [`DATA_W-1:0] load_data = byte_access     ? {{24{load_sign}}, load_byte}     :
                                   halfword_access ? {{16{load_sign}}, load_halfword} :
                                                     mem_rdata;

    // rs2 is replicated into every lane it could land in; the mask selects.
    assign mem_wdata[ 7: 0] = rs2[7:0];
    assign mem_wdata[15: 8] = loadstore_addr[0] ? rs2[7:0] : rs2[15:8];
    assign mem_wdata[23:16] = loadstore_addr[1] ? rs2[7:0] : rs2[23:16];
    assign mem_wdata[31:24] = loadstore_addr[0] ? rs2[7:0] :
                              loadstore_addr[1] ? rs2[15:8] : rs2[31:24];

    wire [`WMASK_W-1:0] store_wmask =
        byte_access     ? (loadstore_addr[1] ? (loadstore_addr[0] ? 4'b1000 : 4'b0100)
                                             : (loadstore_addr[0] ? 4'b0010 : 4'b0001)) :
        halfword_access ? (loadstore_addr[1] ? 4'b1100 : 4'b0011) :
                          4'b1111;

    // ---- write-back and bus outputs -----------------------------------------
    // The class flags are mutually exclusive, so this is a plain mux.
    assign wb_data = (is_jal || is_jalr) ? pc + 32'd4 :
                     is_lui              ? imm_u      :
                     is_auipc            ? pc + imm_u :
                     is_load             ? load_data  :
                                           alu_result;

    assign mem_addr  = fetching ? pc : loadstore_addr;
    assign mem_wmask = {`WMASK_W{storing}} & store_wmask;

endmodule
