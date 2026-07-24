`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// cam_init.v - SCCB (I2C-like, write-only) master for the OV7670
// into the OV7670 after power-up. Replaces write_config_cam()/config_cam():
// there is no CPU, so the fabric owns camera bring-up.
//
// SIOC is push-pull (allowed by SCCB: the master always drives the clock).
// SIOD is open-drain: this module only says "pull low" (siod_low=1); the top
// level ties that to an SB_IO output-enable with the pin's pull-up on.
// The 9th (don't-care/ACK) bit of each phase is simply a released line,
// which falls out of the shift register naturally: shifting a '1' releases.
//
// A 3-phase write is {0x42, reg, val} = 27 clocked bits at ~100 kHz, one
// register per ~290 us, with a 2 ms gap between writes and a 10 ms gap after
// each COM7 soft reset. Whole table (118 entries) ~290 ms - still long done
// before the ST7789 finishes its own (~500 ms) init.
//
// ---------------------------------------------------------------------------
// Register table = the proven camera.h set, with exactly these deltas:
//
//   COM7  0x04 -> 0x14   select QVGA as well as RGB
//   CLKRC 0x00 -> 0x01   internal clock = XCLK/2 = 9.750 MHz
//   DBLV  0x4A -> 0x0A   PLL x4 OFF (x4 would quadruple everything)
//   COM3  0x00 -> 0x04   enable DCW              \
//   COM14 0x00 -> 0x19   manual scaling, PCLK/2   > QVGA, PCLK 1.625 MHz
//   + 0x70..0x73, 0xA2   canonical scaling regs  /
//   RGB444 0x03 -> 0x00  RGB444 OFF  \  the old table left the sensor in
//   COM15  0xF0 -> 0xD0  true RGB565 /  444/555 mode; the panel needs 565
//
// Color matrix and windowing/scaling registers are carried over verbatim
// from the working configuration. Gamma, AWB tuning, AEC/banding
// parameters, COM8, and pixel correction/edge enhancement were never
// programmed by the original table (left at chip reset defaults) and are
// now an added block at the end of the ROM -- see the comments there.
// ============================================================================

module cam_init #(
    parameter TICK_DIV   = 98,     // 39.00 MHz / 98 = 397.96 kHz quarter tick
    parameter BOOT_TICKS = 4000,   // ~10 ms after reset before first write
    parameter GAP_TICKS  = 800,    // ~2 ms between writes
    parameter RST_TICKS  = 4000    // ~10 ms settle after COM7 reset writes
)(
    input  wire clk,
    input  wire rst,
    output reg  sioc,
    output reg  siod_low,          // 1 = drive SIOD low, 0 = release
    output reg  done
);

    // ---------------- register ROM ----------------
    function [15:0] rom;
        input [6:0] i;
        begin
            case (i)
                6'd0 :  rom = 16'h1280;  // COM7   soft reset
                6'd1 :  rom = 16'h1280;  // COM7   soft reset (twice, as proven)
                6'd2 :  rom = 16'h1214;  // COM7   QVGA + RGB output
                6'd3 :  rom = 16'h1101;  // CLKRC  /2  (was 0x00)          [changed]
                6'd4 :  rom = 16'h0C04;  // COM3   DCW enable (was 0x00)   [changed]
                6'd5 :  rom = 16'h3E19;  // COM14  manual scale, PCLK/2    [changed]
                6'd6 :  rom = 16'h8C00;  // RGB444 disable (was 0x03)      [changed]
                6'd7 :  rom = 16'h0400;  // COM1
                6'd8 :  rom = 16'h40D0;  // COM15  full range, RGB565      [changed]
                6'd9 :  rom = 16'h3A04;  // TSLB
                6'd10:  rom = 16'h1438;  // COM9   AGC ceiling
                6'd11:  rom = 16'h4FB3;  // MTX1  \
                6'd12:  rom = 16'h50B3;  // MTX2  |
                6'd13:  rom = 16'h5100;  // MTX3  |
                6'd14:  rom = 16'h523D;  // MTX4  | color matrix
                6'd15:  rom = 16'h53A7;  // MTX5  |
                6'd16:  rom = 16'h54E4;  // MTX6  /
                6'd17:  rom = 16'h589E;  // MTXS
                6'd18:  rom = 16'h3DC0;  // COM13  gamma en, UV auto
                6'd19:  rom = 16'h1101;  // CLKRC  /2 again
                6'd20:  rom = 16'h1711;  // HSTART
                6'd21:  rom = 16'h1861;  // HSTOP
                6'd22:  rom = 16'h32A4;  // HREF
                6'd23:  rom = 16'h1903;  // VSTART
                6'd24:  rom = 16'h1A7B;  // VSTOP
                6'd25:  rom = 16'h030A;  // VREF
                6'd26:  rom = 16'h0E61;  // COM5
                6'd27:  rom = 16'h0F4B;  // COM6
                6'd28:  rom = 16'h1602;  // reserved magic
                6'd29:  rom = 16'h1E34;  // MVFP  (as proven; flips also possible in MADCTL)
                6'd30:  rom = 16'h2102;
                6'd31:  rom = 16'h2291;
                6'd32:  rom = 16'h2907;
                6'd33:  rom = 16'h330B;
                6'd34:  rom = 16'h350B;
                6'd35:  rom = 16'h371D;
                6'd36:  rom = 16'h3871;
                6'd37:  rom = 16'h392A;
                6'd38:  rom = 16'h3C78;  // COM12
                6'd39:  rom = 16'h4D40;
                6'd40:  rom = 16'h4E20;
                6'd41:  rom = 16'h6900;  // GFIX
                6'd42:  rom = 16'h6B0A;  // DBLV  PLL bypass (was 0x4A)    [changed]
                6'd43:  rom = 16'h7410;
                6'd44:  rom = 16'h8D4F;
                6'd45:  rom = 16'h8E00;
                6'd46:  rom = 16'h8F00;
                6'd47:  rom = 16'h9000;
                6'd48:  rom = 16'h9100;
                6'd49:  rom = 16'h9600;
                6'd50:  rom = 16'h9A00;
                6'd51:  rom = 16'hB084;  // reserved magic (color, important)
                6'd52:  rom = 16'hB10C;  // ABLC1
                6'd53:  rom = 16'hB20E;
                6'd54:  rom = 16'hB382;  // THL_ST
                6'd55:  rom = 16'hB80A;
                6'd56:  rom = 16'h703A;  // SCALING_XSC        \            [added]
                6'd57:  rom = 16'h7135;  // SCALING_YSC        |            [added]
                6'd58:  rom = 16'h7211;  // SCALING_DCWCTR /2  | QVGA       [added]
                6'd59:  rom = 16'h73F1;  // SCALING_PCLK_DIV/2 |            [added]
                6'd60:  rom = 16'hA202;  // SCALING_PCLK_DELAY /            [added]

                // ---- image-quality tuning block, added -----------------
                // Verbatim/standard values from the widely-deployed Linux
                // kernel ov7670 driver's default register set (the closest
                // thing to a vetted-in-production OV7670 tuning reference),
                // restricted to registers orthogonal to the QVGA/RGB565/
                // timing setup above -- nothing here touches CLKRC, COM7,
                // COM3, COM14, the window/scaling registers, or DBLV, all
                // of which are load-bearing for this design's pixel-clock
                // and line-timing budget (see README.md).

                // AEC operating region + banding-filter parameters, set
                // before COM8 turns the auto-exposure loop on below.
                7'd61:  rom = 16'h2495;  // AEW     AEC/AGC stable region, upper limit
                7'd62:  rom = 16'h2533;  // AEB     AEC/AGC stable region, lower limit
                7'd63:  rom = 16'h26E3;  // VPT     fast-mode large-step threshold
                7'd64:  rom = 16'h3B03;  // COM11   EXP | HZAUTO: night mode + auto 50/60 Hz banding detect
                7'd65:  rom = 16'hA505;  // BD50MAX max banding step, 50 Hz
                7'd66:  rom = 16'hAB07;  // BD60MAX max banding step, 60 Hz
                7'd67:  rom = 16'h9F78;  // HAECC1
                7'd68:  rom = 16'hA068;  // HAECC2
                7'd69:  rom = 16'hA103;  // reserved, paired with HAECC1/2
                7'd70:  rom = 16'hA6D8;  // HAECC3
                7'd71:  rom = 16'hA7D8;  // HAECC4
                7'd72:  rom = 16'hA8F0;  // HAECC5
                7'd73:  rom = 16'hA990;  // HAECC6
                7'd74:  rom = 16'hAA94;  // HAECC7

                // Enable AGC/AEC/AWB now that their operating parameters
                // are programmed: fast algorithm, unlimited AEC step,
                // banding filter, AGC, AEC, AWB all on. Previously COM8 was
                // never written, leaving it at its post-reset default.
                7'd75:  rom = 16'h13FF;  // COM8    FASTAEC|AECSTEP|BFILT|AGC|AEC|AWB

                // AWB tuning block. The OV7670's default/untuned AWB is the
                // classic source of the purple/magenta color cast this
                // sensor is known for; this block plus COM16 below is the
                // standard fix.
                7'd76:  rom = 16'h0140;  // BLUE    initial blue channel gain (AWB adjusts from here)
                7'd77:  rom = 16'h0260;  // RED     initial red channel gain
                7'd78:  rom = 16'h430A;
                7'd79:  rom = 16'h44F0;
                7'd80:  rom = 16'h4534;
                7'd81:  rom = 16'h4658;
                7'd82:  rom = 16'h4728;
                7'd83:  rom = 16'h483A;
                7'd84:  rom = 16'h5988;
                7'd85:  rom = 16'h5A88;
                7'd86:  rom = 16'h5B44;
                7'd87:  rom = 16'h5C67;
                7'd88:  rom = 16'h5D49;
                7'd89:  rom = 16'h5E0E;
                7'd90:  rom = 16'h6C0A;
                7'd91:  rom = 16'h6D55;
                7'd92:  rom = 16'h6E11;
                7'd93:  rom = 16'h6F9F;
                7'd94:  rom = 16'h6A40;
                7'd95:  rom = 16'h4138;  // COM16   AWB gain enable -- required for the block above to take effect

                // Pixel correction / edge enhancement: REG76 in particular
                // suppresses the salt-and-pepper white/black pixel noise
                // this sensor shows without it.
                7'd96:  rom = 16'h3F00;  // EDGE    edge enhancement factor (auto)
                7'd97:  rom = 16'h7505;  // edge enhancement lower limit
                7'd98:  rom = 16'h76E1;  // REG76   white/black pixel correction enable
                7'd99:  rom = 16'h4B09;
                7'd100: rom = 16'h7701;
                7'd101: rom = 16'hC960;

                // Gamma curve (GAM1..GAM15 + SLOP, 0x7A-0x89). Left
                // entirely at chip reset defaults before this change; a
                // flat/uncorrected gamma curve reads as low-contrast,
                // washed-out video.
                7'd102: rom = 16'h7A20;
                7'd103: rom = 16'h7B10;
                7'd104: rom = 16'h7C1E;
                7'd105: rom = 16'h7D35;
                7'd106: rom = 16'h7E5A;
                7'd107: rom = 16'h7F69;
                7'd108: rom = 16'h8076;
                7'd109: rom = 16'h8180;
                7'd110: rom = 16'h8288;
                7'd111: rom = 16'h838F;
                7'd112: rom = 16'h8496;
                7'd113: rom = 16'h85A3;
                7'd114: rom = 16'h86AF;
                7'd115: rom = 16'h87C4;
                7'd116: rom = 16'h88D7;
                7'd117: rom = 16'h89E8;

                default: rom = 16'hFFFF; // end marker
            endcase
        end
    endfunction

    localparam [6:0] N_ENTRIES = 7'd118;  // entries 0..117 above

    // ---------------- quarter-bit tick (~400 kHz) ----------------
    reg [$clog2(TICK_DIV)-1:0] div;
    reg tick;
    always @(posedge clk) begin
        if (rst) begin
            div  <= 0;
            tick <= 1'b0;
        end else begin
            tick <= (div == TICK_DIV - 1);
            div  <= (div == TICK_DIV - 1) ? {$clog2(TICK_DIV){1'b0}}
                                          : div + 1'b1;
        end
    end

    // ---------------- engine ----------------
    localparam ST_BOOT  = 3'd0,
               ST_FETCH = 3'd1,   // register the ROM lookup (timing)
               ST_LOAD  = 3'd2,
               ST_START = 3'd3,
               ST_BITS  = 3'd4,
               ST_STOP  = 3'd5,
               ST_GAP   = 3'd6,
               ST_DONE  = 3'd7;

    reg [2:0]  state;
    reg [6:0]  idx;
    reg [26:0] sh;
    reg [4:0]  bitn;
    reg [1:0]  ph;
    reg [15:0] gap;
    reg        long_gap;
    reg [15:0] rom_q;   // registered ROM output: the 118-entry mux tree and
                        // everything it feeds never share a cycle

    always @(posedge clk) begin
        if (rst) begin
            state    <= ST_BOOT;
            idx      <= 7'd0;
            rom_q    <= 16'd0;
            bitn     <= 5'd0;
            ph       <= 2'd0;
            gap      <= BOOT_TICKS[15:0];
            long_gap <= 1'b0;
            sioc     <= 1'b1;
            siod_low <= 1'b0;
            done     <= 1'b0;
        end else begin
            case (state)

            ST_BOOT: if (tick) begin
                if (gap == 16'd1) state <= ST_FETCH;
                else              gap   <= gap - 16'd1;
            end

            ST_FETCH: begin
                rom_q <= rom(idx);
                state <= ST_LOAD;
            end

            // The end-of-table test is on idx (7-bit equality against a
            // constant), not on the 16-bit ROM data - keeps the ROM output
            // out of the state-transition cone. N_ENTRIES must track the
            // table above.
            ST_LOAD: begin
                if (idx == N_ENTRIES) begin
                    state <= ST_DONE;
                end else begin
                    long_gap <= (idx[6:1] == 6'd0);  // entries 0,1 = COM7 reset
                    bitn     <= 5'd26;
                    ph       <= 2'd0;
                    state    <= ST_START;
                end
            end

            // START: SIOD falls while SIOC is high, then SIOC falls.
            ST_START: if (tick) begin
                case (ph)
                    2'd0: begin siod_low <= 1'b1; ph <= 2'd1; end
                    default: begin
                        sioc  <= 1'b0;
                        ph    <= 2'd0;
                        state <= ST_BITS;
                    end
                endcase
            end

            // Each bit: set SIOD while SIOC low, raise SIOC, hold, drop SIOC.
            ST_BITS: if (tick) begin
                case (ph)
                    2'd0: begin siod_low <= ~sh[26]; ph <= 2'd1; end
                    2'd1: begin sioc     <= 1'b1;    ph <= 2'd2; end
                    2'd2: begin                      ph <= 2'd3; end
                    default: begin
                        sioc <= 1'b0;
                        ph   <= 2'd0;
                        if (bitn == 5'd0) state <= ST_STOP;
                        else              bitn  <= bitn - 5'd1;
                    end
                endcase
            end

            // STOP: SIOD low with SIOC low, SIOC rises, SIOD releases.
            ST_STOP: if (tick) begin
                case (ph)
                    2'd0: begin siod_low <= 1'b1; ph <= 2'd1; end
                    2'd1: begin sioc     <= 1'b1; ph <= 2'd2; end
                    default: begin
                        siod_low <= 1'b0;
                        ph       <= 2'd0;
                        gap      <= long_gap ? RST_TICKS[15:0] : GAP_TICKS[15:0];
                        idx      <= idx + 7'd1;
                        state    <= ST_GAP;
                    end
                endcase
            end

            ST_GAP: if (tick) begin
                if (gap == 16'd1) state <= ST_FETCH;
                else              gap   <= gap - 16'd1;
            end

            ST_DONE: begin
                done     <= 1'b1;
                sioc     <= 1'b1;
                siod_low <= 1'b0;
            end

            default: state <= ST_DONE;
            endcase
        end
    end

    // ------------- 27-bit shift register (own always block) -------------
    // sh has exactly two enables: a 1-LUT state decode (load) and a
    // registered strobe (shift), so its 27-FF clock-enable cone is one
    // level deep (this net gets promoted to a global buffer by nextpnr;
    // with the old deep decode it was the critical path). The strobe
    // samples state/ph during the div-wrap cycle, one clock before 'tick',
    // when both have been stable for a full tick period (TICK_DIV >= 3).
    reg sh_shift_q;

    always @(posedge clk) begin
        if (rst)
            sh_shift_q <= 1'b0;
        else
            sh_shift_q <= (state == ST_BITS) && (ph == 2'd3) &&
                          (div == TICK_DIV - 1);
    end

    always @(posedge clk) begin
        if (state == ST_LOAD)
            sh <= {8'h42, 1'b1, rom_q[15:8], 1'b1, rom_q[7:0], 1'b1};
        else if (sh_shift_q)
            sh <= sh << 1;
    end

endmodule
`default_nettype wire
