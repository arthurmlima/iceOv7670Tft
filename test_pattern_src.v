`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// test_pattern_src.v
//
// Drop-in stand-in for cam_capture, used to bisect the pipeline: it presents
// the same {pix_data, pix_wr, frame_sync} interface and reproduces the
// OV7670's *timing* as well as its data, so everything downstream --
// frame_stream_gate, the XOR stage, the FIFO, the panel FSM and the SPI pads
// -- sees exactly the rates it sees with a real camera.
//
// The picture is deliberately **frame-invariant** except for one small square,
// because a moving pattern cannot distinguish the two things that look alike
// on a real panel:
//
//   spatial defect   - pixels per row not matching the CASET window width.
//                      Every pixel lost or gained shifts the rest of the frame
//                      by one, so straight vertical lines lean, and the lean
//                      measures the error directly.
//   temporal effect  - simply seeing successive frames, or photographing a
//                      progressively-written panel with a rolling shutter.
//
// With static content, anything that is not straight and stable is spatial and
// therefore real.  What to look for:
//
//   1px white border  - must sit exactly on all four screen edges.  Missing or
//                       wrapped edges mean the window geometry is wrong.
//   40px white grid   - verticals must be vertical.  If they lean by N pixels
//                       over the 240 rows, the stream is losing (or repeating)
//                       N/240 pixels per row.
//   corner blocks     - red top-left, green top-right, blue bottom-left.
//                       Wrong corners = rotation/mirroring (MADCTL); wrong
//                       colours = RGB565 byte swap in cam_capture.
//   centre square     - the only thing that changes: it alternates black and
//                       white once per frame, so it proves frames are still
//                       being accepted without disturbing the geometry.
//
// Defaults reproduce the current clock plan: one pixel every 16 clk cycles
// (camera internal clock = clk/4, one pixel per 4 internal clocks), a line
// period of 1568 internal clocks = 6272 clk cycles, 510 lines per frame.
// ============================================================================
module test_pattern_src #(
    parameter integer WIDTH        = 280,
    parameter integer HEIGHT       = 240,
    parameter integer PIX_CYCLES   = 16,
    parameter integer LINE_CYCLES  = 6272,
    parameter integer TOTAL_LINES  = 510,
    parameter integer VBLANK_LINES = 10,
    parameter integer GRID         = 40,
    parameter integer MARK         = 20    // corner block size
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,

    output reg  [15:0] pix_data,
    output reg         pix_wr,
    output reg         frame_sync
);
    localparam integer LCW = $clog2(LINE_CYCLES);
    localparam integer LNW = $clog2(TOTAL_LINES);
    localparam integer PCW = $clog2(PIX_CYCLES);
    localparam integer CW  = $clog2(WIDTH+1);
    localparam integer RW  = $clog2(HEIGHT+1);
    localparam integer GW  = $clog2(GRID);

    localparam [15:0] C_WHITE = 16'hFFFF;
    localparam [15:0] C_BLACK = 16'h0000;
    localparam [15:0] C_RED   = 16'hF800;
    localparam [15:0] C_GREEN = 16'h07E0;
    localparam [15:0] C_BLUE  = 16'h001F;

    reg [LCW-1:0] line_cyc  = {LCW{1'b0}};
    reg [LNW-1:0] line_num  = {LNW{1'b0}};
    reg [PCW-1:0] pix_cyc   = {PCW{1'b0}};
    reg [CW-1:0]  col       = {CW{1'b0}};
    reg [GW-1:0]  col_mod   = {GW{1'b0}};
    reg [GW-1:0]  row_mod   = {GW{1'b0}};
    reg           frame_tog = 1'b0;

    wire active_line = (line_num >= VBLANK_LINES) &&
                       (line_num <  VBLANK_LINES + HEIGHT);
    wire [RW-1:0] row = line_num - VBLANK_LINES;

    wire on_border = (col == 0) || (col == WIDTH-1) ||
                     (row == 0) || (row == HEIGHT-1);
    wire on_grid   = (col_mod == 0) || (row_mod == 0);

    wire mark_tl = (col < MARK)         && (row < MARK);
    wire mark_tr = (col >= WIDTH-MARK)  && (row < MARK);
    wire mark_bl = (col < MARK)         && (row >= HEIGHT-MARK);

    wire in_centre = (col >= WIDTH/2 - 8) && (col < WIDTH/2 + 8) &&
                     (row >= HEIGHT/2 - 8) && (row < HEIGHT/2 + 8);

    // A dim ramp underneath everything: it makes an RGB565 byte swap obvious
    // (the smooth red/green wash turns into banded blue) without competing
    // with the white grid.
    wire [15:0] background = {col[7:3], row[7:2], 5'd0};

    wire [15:0] pattern =
          mark_tl   ? C_RED
        : mark_tr   ? C_GREEN
        : mark_bl   ? C_BLUE
        : in_centre ? (frame_tog ? C_WHITE : C_BLACK)
        : (on_border || on_grid) ? C_WHITE
        : background;

    always @(posedge clk) begin
        pix_wr     <= 1'b0;
        frame_sync <= 1'b0;

        if (rst || !enable) begin
            line_cyc <= {LCW{1'b0}};
            line_num <= {LNW{1'b0}};
            pix_cyc  <= {PCW{1'b0}};
            col      <= {CW{1'b0}};
            col_mod  <= {GW{1'b0}};
            row_mod  <= {GW{1'b0}};
            pix_data <= 16'h0000;
            if (rst)
                frame_tog <= 1'b0;
        end else if (line_cyc == LINE_CYCLES-1) begin
            line_cyc <= {LCW{1'b0}};
            pix_cyc  <= {PCW{1'b0}};
            col      <= {CW{1'b0}};
            col_mod  <= {GW{1'b0}};

            if (line_num == TOTAL_LINES-1) begin
                line_num  <= {LNW{1'b0}};
                frame_sync<= 1'b1;
                frame_tog <= ~frame_tog;
                row_mod   <= {GW{1'b0}};
            end else begin
                line_num <= line_num + 1'b1;
                // row_mod tracks the *output* row, so it only advances across
                // active lines and restarts with the first of them.
                if (line_num + 1 == VBLANK_LINES)
                    row_mod <= {GW{1'b0}};
                else if (active_line)
                    row_mod <= (row_mod == GRID-1) ? {GW{1'b0}} : row_mod + 1'b1;
            end
        end else begin
            line_cyc <= line_cyc + 1'b1;
            if (active_line) begin
                if (pix_cyc == PIX_CYCLES-1) begin
                    pix_cyc <= {PCW{1'b0}};
                    if (col < WIDTH) begin
                        pix_data <= pattern;
                        pix_wr   <= 1'b1;
                        col      <= col + 1'b1;
                        col_mod  <= (col_mod == GRID-1) ? {GW{1'b0}}
                                                       : col_mod + 1'b1;
                    end
                end else begin
                    pix_cyc <= pix_cyc + 1'b1;
                end
            end
        end
    end
endmodule
`default_nettype wire
