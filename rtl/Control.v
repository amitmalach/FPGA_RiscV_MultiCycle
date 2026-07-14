`timescale 1ns/1ps
`include "defines.vh"
// Control -- the multi-cycle sequencer: one FSM state per cycle.
//   FETCH_INSTR : drive pc on the bus with the read strobe
//   WAIT_INSTR  : latch the instruction word once mem_rbusy is low
//   FETCH_REGS  : read rs1 and rs2 from the register file
//   EXECUTE     : update pc (not for SYSTEM); write rd except for load, branch
//   LOAD        : drive the load address with the read strobe
//   WAIT_DATA   : write the loaded value to rd once mem_rbusy is low
// Reset lands in WAIT_DATA, not FETCH_INSTR, so no read strobe is asserted
// while reset is held; WAIT_DATA falls through to FETCH_INSTR one cycle later.
// The edge strobes (latch_instr, read_regs, update_pc, write_rd) are already
// qualified by clk_enable and reset_n, so the datapath registers only test
// them; fetching and mem_rstrb are plain state decodes.
module Control (
    input  wire clk,
    input  wire clk_enable,
    input  wire reset_n,

    input  wire mem_rbusy,
    input  wire is_load,
    input  wire is_branch,
    input  wire is_system,

    output wire fetching,     // FETCH_INSTR or WAIT_INSTR: bus address is pc
    output wire mem_rstrb,    // FETCH_INSTR or LOAD
    output wire latch_instr,  // instruction word valid on mem_rdata this edge
    output wire read_regs,    // register file reads rs1 and rs2 this edge
    output wire update_pc,    // pc takes its next value this edge
    output wire write_rd      // rd takes the write-back value this edge
);

    localparam [2:0] FETCH_INSTR = 3'd0;
    localparam [2:0] WAIT_INSTR  = 3'd1;
    localparam [2:0] FETCH_REGS  = 3'd2;
    localparam [2:0] EXECUTE     = 3'd3;
    localparam [2:0] LOAD        = 3'd4;
    localparam [2:0] WAIT_DATA   = 3'd5;

    reg [2:0] state = WAIT_DATA;  // power-on value matches the reset value

    wire run = clk_enable & reset_n;

    assign fetching    = (state == FETCH_INSTR) || (state == WAIT_INSTR);
    assign mem_rstrb   = (state == FETCH_INSTR) || (state == LOAD);
    assign latch_instr = run & (state == WAIT_INSTR) & !mem_rbusy;
    assign read_regs   = run & (state == FETCH_REGS);
    assign update_pc   = run & (state == EXECUTE) & !is_system;
    assign write_rd    = run & (((state == EXECUTE) & !is_branch & !is_load) ||
                                ((state == WAIT_DATA) & !mem_rbusy));

    always @(posedge clk) begin
        if (!reset_n)
            state <= WAIT_DATA;
        else if (clk_enable) begin
            case (state)
                FETCH_INSTR: state <= WAIT_INSTR;
                WAIT_INSTR:  if (!mem_rbusy) state <= FETCH_REGS;
                FETCH_REGS:  state <= EXECUTE;
                EXECUTE:     state <= is_load ? LOAD : FETCH_INSTR;
                LOAD:        state <= WAIT_DATA;
                WAIT_DATA:   if (!mem_rbusy) state <= FETCH_INSTR;
            endcase
        end
    end

endmodule
