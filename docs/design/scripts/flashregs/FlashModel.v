`timescale 1ns/1ps
// FlashModel -- a byte-level model of the S25FL256S's register commands for FlashRegsBench:
// RDSR1 05h, RDCR 35h, WREN 06h, WRR 01h (SR1 then CR1; WIP set for 20 us), RDID 9Fh (01 02 19)
// and READ 03h (AA995566 at 0x30, FFh elsewhere). Prints each command it completes. SPI mode 0,
// one bit wide; miso changes on the falling edge with no delay, so a master sampling on the
// falling edge instead of the rising one reads the same bits: this model does not catch that.
module FlashModel(input cs_n, input sclk, input mosi, output reg miso);
    reg [7:0] sr1 = 8'h00, cr1 = 8'h00;
    reg       wel = 1'b0;
    reg [7:0] cmd = 8'h00, sh = 8'h00, out_byte = 8'h00;
    reg [23:0] addr = 24'd0;
    integer   nbit = 0, nbyte = 0;
    function [7:0] mem(input [23:0] a);
        case (a)
            24'h30: mem = 8'hAA; 24'h31: mem = 8'h99; 24'h32: mem = 8'h55; 24'h33: mem = 8'h66;
            default: mem = 8'hFF;
        endcase
    endfunction
    always @(posedge sclk) if (!cs_n) begin
        sh = {sh[6:0], mosi}; nbit = nbit + 1;
        if (nbit == 8) begin
            nbit = 0;
            if (nbyte == 0) begin
                cmd = sh;
                case (cmd)
                    8'h05: out_byte = sr1;
                    8'h35: out_byte = cr1;
                    8'h9F: out_byte = 8'h01;
                    8'h06: begin wel = 1'b1; $display("FLASH WREN"); end
                    8'h01, 8'h03: ;
                    default: $display("FLASH unknown opcode %02x", cmd);
                endcase
            end else case (cmd)
                8'h9F: out_byte = (nbyte == 1) ? 8'h02 : (nbyte == 2) ? 8'h19 : 8'h00;
                8'h03: begin
                    if (nbyte <= 3) addr = {addr[15:0], sh};
                    if (nbyte >= 3) begin out_byte = mem(addr); addr = addr + 24'd1; end
                end
                8'h01: if (wel) begin
                    if (nbyte == 1) begin
                        sr1 = {sh[7:1], 1'b1}; $display("FLASH WRR SR1=%02x", sh);
                    end
                    if (nbyte == 2) begin cr1 = sh; $display("FLASH WRR CR1=%02x", sh); end
                end
                default: ;
            endcase
            nbyte = nbyte + 1;
        end
    end
    always @(negedge sclk) if (!cs_n) miso = out_byte[7 - nbit];
    reg wip_pending = 1'b0;
    always @(posedge cs_n) begin
        if (cmd == 8'h05) $display("FLASH RDSR1 -> %02x", out_byte);
        if (cmd == 8'h35) $display("FLASH RDCR  -> %02x", out_byte);
        if (cmd == 8'h03) $display("FLASH READ, next address %06x", addr);
        if (cmd == 8'h01 && wel) begin wel = 1'b0; wip_pending = 1'b1; end
        nbit = 0; nbyte = 0; cmd = 8'h00;
    end
    always @(posedge wip_pending) begin
        #20000 sr1[0] = 1'b0; wip_pending = 1'b0;
        $display("FLASH write done, SR1=%02x CR1=%02x", sr1, cr1);
    end
endmodule
