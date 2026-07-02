`timescale 1ns/1ps
`include "defines.vh"
// Control -- the multi-cycle sequencer: one FSM state per cycle.
//   FETCH_INSTR : drive pc on the bus with the read strobe
//   WAIT_INSTR  : latch the instruction word once mem_rbusy is low
//   FETCH_REGS  : read rs1 and rs2 from the register file
//   EXECUTE     : update pc (not for SYSTEM); write rd except for branch
// The edge strobes (latch_instr, read_regs, update_pc, write_rd) are already
// qualified by clk_enable and reset_n, so the datapath registers only test
// them; mem_rstrb is a plain state decode.
module Control (
    input  wire clk,
    input  wire clk_enable,
    input  wire reset_n,

    input  wire mem_rbusy,
    input  wire is_branch,
    input  wire is_system,

    output wire mem_rstrb,    // FETCH_INSTR
    output wire latch_instr,  // instruction word valid on mem_rdata this edge
    output wire read_regs,    // register file reads rs1 and rs2 this edge
    output wire update_pc,    // pc takes its next value this edge
    output wire write_rd      // rd takes the write-back value this edge
);

    localparam [1:0] FETCH_INSTR = 2'd0;
    localparam [1:0] WAIT_INSTR  = 2'd1;
    localparam [1:0] FETCH_REGS  = 2'd2;
    localparam [1:0] EXECUTE     = 2'd3;

    reg [1:0] state = FETCH_INSTR;  // power-on value matches the reset value

    wire run = clk_enable & reset_n;

    assign mem_rstrb   = (state == FETCH_INSTR);
    assign latch_instr = run & (state == WAIT_INSTR) & !mem_rbusy;
    assign read_regs   = run & (state == FETCH_REGS);
    assign update_pc   = run & (state == EXECUTE) & !is_system;
    assign write_rd    = run & (state == EXECUTE) & !is_branch;

    always @(posedge clk) begin
        if (!reset_n)
            state <= FETCH_INSTR;
        else if (clk_enable) begin
            case (state)
                FETCH_INSTR: state <= WAIT_INSTR;
                WAIT_INSTR:  if (!mem_rbusy) state <= FETCH_REGS;
                FETCH_REGS:  state <= EXECUTE;
                EXECUTE:     state <= FETCH_INSTR;
            endcase
        end
    end

endmodule
