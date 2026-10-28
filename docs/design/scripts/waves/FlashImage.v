`timescale 1ns/1ps
`include "defines.vh"
// FlashImage -- a model of the S25FL256S's READ command (03h) for WaveBench, holding a
// flash-boot image at the code offset (SPIFLASH_CODE_OFFSET): every other byte, and every
// byte past the image, reads FFh, as an erased flash does. +flash=<file> names the image, one
// byte per line in hex ($readmemh), and +flash_bytes=<n> its length; run_bench.sh writes it
// from the .spiflash.bin. Without them every byte reads FFh.
// SPI mode 0, one bit wide: mosi sampled on the rising edge, miso driven on the falling
// edge with no delay from the edge after the last address bit on, and high-impedance before
// it and while cs_n is high. Any other opcode reads FFh. Prints nothing, unless the image is
// larger than the model.
module FlashImage #(
    parameter integer SIZE = 65536    // bytes the model can hold from the code offset
) (
    input  wire cs_n,
    input  wire sclk,
    input  wire mosi,
    output reg  miso
);
    reg [7:0]  image [0:SIZE-1];
    reg [7:0]  shift = 8'h00, cmd = 8'h00, out_byte = 8'hFF;
    reg        data_phase = 1'b0;    // miso driven
    reg [23:0] addr = 24'd0;
    integer    nbit = 0, nbyte = 0, image_bytes = 0, i;
    reg [1023:0] file;

    initial begin
        miso = 1'bz;
        for (i = 0; i < SIZE; i = i + 1) image[i] = 8'hFF;
        if ($value$plusargs("flash=%s", file) &&
            $value$plusargs("flash_bytes=%d", image_bytes)) begin
            if (image_bytes > SIZE) begin
                $display("FlashImage: the image is %0d bytes, the model holds %0d",
                         image_bytes, SIZE);
                $finish;
            end
            if (image_bytes > 0) $readmemh(file, image, 0, image_bytes - 1);
        end
    end

    function [7:0] byte_at(input [23:0] a);
        if (a >= `SPIFLASH_CODE_OFFSET && a - `SPIFLASH_CODE_OFFSET < SIZE)
            byte_at = image[a - `SPIFLASH_CODE_OFFSET];
        else
            byte_at = 8'hFF;
    endfunction

    // The opcode, three address bytes, then one data byte out per byte clocked.
    always @(posedge sclk) if (!cs_n) begin
        shift = {shift[6:0], mosi};
        nbit  = nbit + 1;
        if (nbit == 8) begin
            nbit = 0;
            if (nbyte == 0)
                cmd = shift;
            else if (nbyte <= 3)
                addr = {addr[15:0], shift};
            if (nbyte >= 3) data_phase = 1'b1;
            if (cmd == 8'h03 && nbyte >= 3) begin
                out_byte = byte_at(addr);
                addr     = addr + 24'd1;
            end else begin
                out_byte = 8'hFF;
            end
            nbyte = nbyte + 1;
        end
    end

    always @(negedge sclk) if (!cs_n && data_phase) miso = out_byte[7 - nbit];

    always @(posedge cs_n) begin
        miso     = 1'bz;
        data_phase = 1'b0;
        nbit     = 0;
        nbyte    = 0;
        cmd      = 8'h00;
        out_byte = 8'hFF;
    end
endmodule
