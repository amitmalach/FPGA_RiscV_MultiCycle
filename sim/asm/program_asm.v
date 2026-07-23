`timescale 1ns/1ps
`default_nettype none

// program_asm -- sample program for the Verilog assembler: an 80x80 ASCII-art
// mandelbrot over UART in Q22.10 fixed point with a software multiply (no MUL
// in RV32I). Not part of the hardware. `make -C sim/asm [DEFS=-DBENCH]` writes
// program.hex, a RAM image in the format of rtl/firmware.hex.

module program_asm;

    reg [31:0] MEM [0:255];   // MEM and memPC are the names riscv_assembly.v writes to

    // Use the assembler
    `include "riscv_assembly.v"

    `ifdef BENCH
       localparam SLOW_BIT=0;
    `else
       localparam SLOW_BIT=20;
    `endif

    // Memory-mapped IO in IO page, using one-hot word addressing.
    localparam IO_LEDS_BIT      = 0;
    localparam IO_UART_DAT_BIT  = 1;
    localparam IO_UART_CNTL_BIT = 2;

    // Convert IO bit number into byte offset.
    //
    // bit 0 -> 1 << 2 = 4
    // bit 1 -> 1 << 3 = 8
    // bit 2 -> 1 << 4 = 16
    function [31:0] IO_BIT_TO_OFFSET;
        input [31:0] bitid;
        begin
            IO_BIT_TO_OFFSET = 1 << (bitid + 2);
        end
    endfunction

    integer i;
    integer fd;
    integer num_words;

    // Q22.10 fixed-point constants for the Mandelbrot viewport
    // [-2,2]x[-2,2], mapped across an 80x80 character grid.
    `define MANDEL_SHIFT 10
    `define MANDEL_MUL (1 << `MANDEL_SHIFT)
    `define XMIN (-2*`MANDEL_MUL)
    `define XMAX ( 2*`MANDEL_MUL)
    `define YMIN (-2*`MANDEL_MUL)
    `define YMAX ( 2*`MANDEL_MUL)
    `define DX ((`XMAX-`XMIN)/80)
    `define DY ((`YMAX-`YMIN)/80)
    `define NORM_MAX (4 << `MANDEL_SHIFT)

    // Label values: run under -DBENCH, copy the printed addresses here, re-run.
    integer mandelstart_ = 12;
    integer blink_       = 16;
    integer loop_y_      = 76;
    integer loop_x_      = 84;
    integer loop_Z_      = 96;
    integer exit_Z_      = 188;
    integer wait_        = 276;
    integer wait_L0_     = 284;
    integer putc_        = 296;
    integer putc_L0_     = 304;
    integer mulsi3_      = 320;
    integer mulsi3_L0_   = 328;
    integer mulsi3_L1_   = 340;
    integer colormap_    = 356;

    // s0,s1 pixel X,Y; s2,s3 C; s4,s5 Z; s6..s8 products; s10 iterations; s11 bound 80

    initial begin
        memPC = 0;

        LI(sp, 32'h1800);       // end of 6 KB RAM
        LI(gp, 32'h400000);     // I/O page base address

        Label(mandelstart_);

        // Blink the LEDs 5 times to mark the start of a frame.
        LI(s0, 5);

        Label(blink_);

            LI(a0, 8'h0F);
            SW(a0, gp, IO_BIT_TO_OFFSET(IO_LEDS_BIT));
            CALL(LabelRef(wait_));
            LI(a0, 8'hF0);
            SW(a0, gp, IO_BIT_TO_OFFSET(IO_LEDS_BIT));
            CALL(LabelRef(wait_));
            ADDI(s0, s0, -1);
            BNEZ(s0, LabelRef(blink_));

        LI(a0, 0);
        SW(a0, gp, IO_BIT_TO_OFFSET(IO_LEDS_BIT));

        // Outer loop: Y (row); s3 holds C imaginary.
        LI(s1, 0);
        LI(s3, `YMIN);
        LI(s11, 80);

        Label(loop_y_);

            LI(s0, 0);
            LI(s2, `XMIN);

        // Inner loop: X (column); s2 holds C real.
        Label(loop_x_);

            MV(s4, s2);          // Z <- C
            MV(s5, s3);

            LI(s10, 9);          // iterations remaining

        Label(loop_Z_);

            // Zrr <- (Zr*Zr) >> mandel_shift
            MV(a0, s4);
            MV(a1, s4);
            CALL(LabelRef(mulsi3_));
            SRLI(s6, a0, `MANDEL_SHIFT);

            // 2*Zri <- (Zr*Zi) >> (mandel_shift-1): the -1 folds in the factor 2
            MV(a0, s4);
            MV(a1, s5);
            CALL(LabelRef(mulsi3_));
            SRAI(s7, a0, `MANDEL_SHIFT-1);

            // Zii <- (Zi*Zi) >> mandel_shift
            MV(a0, s5);
            MV(a1, s5);
            CALL(LabelRef(mulsi3_));
            SRLI(s8, a0, `MANDEL_SHIFT);

            SUB(s4, s6, s8);     // Zr <- Zrr - Zii + Cr
            ADD(s4, s4, s2);
            ADD(s5, s7, s3);     // Zi <- 2*Zri + Ci

            ADD(s6, s6, s8);     // s6 <- Zrr+Zii, an approximation of |Z|^2
            LI(s7, `NORM_MAX);
            BGT(s6, s7, LabelRef(exit_Z_)); // escaped -> exit, s10 unchanged

            ADDI(s10, s10, -1);
            BNEZ(s10, LabelRef(loop_Z_));

        Label(exit_Z_);

            LI(a0, colormap_);
            ADD(a0, a0, s10);
            LBU(a0, a0, 0);
            CALL(LabelRef(putc_));

            ADDI(s0, s0, 1);
            ADDI(s2, s2, `DX);
            BNE(s0, s11, LabelRef(loop_x_));

        // end of row
        LI(a0, " ");
        CALL(LabelRef(putc_));
        LI(a0, 13);          // CR then LF: not every terminal treats LF as CR+LF
        CALL(LabelRef(putc_));
        LI(a0, "\n");
        CALL(LabelRef(putc_));

        ADDI(s1, s1, 1);
        ADDI(s3, s3, `DY);
        BNE(s1, s11, LabelRef(loop_y_));

        J(LabelRef(mandelstart_)); // redraw the same view again, forever

        EBREAK(); // never reached; kept in case the loop is changed to exit

        // wait_: fixed delay for the LED blink (SLOW_BIT=0 under -DBENCH).
        Label(wait_);

            LI(t0, 1);
            SLLI(t0, t0, SLOW_BIT);

        Label(wait_L0_);

            ADDI(t0, t0, -1);
            BNEZ(t0, LabelRef(wait_L0_));
            RET();

        // putc_, wait_ and mulsi3_ are leaves: no ra save needed. Every CALL()
        // targets forward: AUIPC gets no rounding fix for a negative low half.
        Label(putc_);

            SW(a0, gp, IO_BIT_TO_OFFSET(IO_UART_DAT_BIT));

            LI(t0, 1 << 9);

        Label(putc_L0_);

            LW(t1, gp, IO_BIT_TO_OFFSET(IO_UART_CNTL_BIT));
            AND(t1, t1, t0);
            BNEZ(t1, LabelRef(putc_L0_));
            RET();

        // mulsi3_: software 32x32 shift-and-add multiply, a0 <- a0 * a1.
        Label(mulsi3_);

            MV(a2, a0);
            LI(a0, 0);

        Label(mulsi3_L0_);

            ANDI(a3, a1, 1);
            BEQZ(a3, LabelRef(mulsi3_L1_));
            ADD(a0, a0, a2);

        Label(mulsi3_L1_);

            SRLI(a1, a1, 1);
            SLLI(a2, a2, 1);
            BNEZ(a1, LabelRef(mulsi3_L0_));
            RET();

        // colormap_: character ramp indexed by s10 (0..9); two padding bytes.
        Label(colormap_);
            DATAB(" ",".",",",":");
            DATAB(";","o","x","%");
            DATAB("#","@", 0 , 0 );

        endASM();

        num_words = memPC >> 2;

        fd = $fopen("program.hex", "w");
        for (i = 0; i < num_words; i = i + 1) begin
            $fdisplay(fd, "%08x", MEM[i]);
        end
        $fclose(fd);
        $display("Generated program.hex with %0d words.", num_words);
        $finish;
    end

endmodule

`default_nettype wire
