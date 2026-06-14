// SPDX-FileCopyrightText: 2020 Bruno Levy
// SPDX-License-Identifier: BSD-3-Clause
// Origin: clockworks.v from Bruno Levy's learn-fpga; the PLL and power-on
// reset branches are removed, the gearbox is kept as is; ports renamed and
// SLOW moved into the ANSI parameter list.
//
// Clockworks -- clock enable and reset for the design.
//   clk_enable: high once every 2^SLOW cycles of clk (every cycle when SLOW=0)
//   reset_n:    the button forwarded; the Genesys 2 reset button is active-low
`timescale 1ns/1ps

module Clockworks #(
   parameter integer SLOW = 0
) (
   input  wire clk,
   input  wire reset_button_n,

   output wire clk_enable,
   output wire reset_n
);

   assign reset_n = reset_button_n;

   generate

      if (SLOW != 0) begin : slowdown
         // tick is high for one cycle in 2^SLOW, the one after div wraps.
         reg [SLOW-1:0] div = {SLOW{1'b0}};
         reg tick = 1'b0;

         always @(posedge clk) begin
            if (!reset_button_n) begin
               div  <= {SLOW{1'b0}};
               tick <= 1'b0;
            end else begin
               div  <= div + 1'b1;
               tick <= (div == {SLOW{1'b1}});
            end
         end

         assign clk_enable = tick;

      end

      else begin : no_slowdown
         assign clk_enable = 1'b1;
      end

   endgenerate

endmodule
