// ============================================================================
// cam_capture.v - OV7670 pixel bus receiver, fully in the 48 MHz domain.
//
// PCLK is NOT used as a clock. At 4 MHz (QVGA, CLKRC /3, PCLK/2) one PCLK
// period is 12 system clocks, so PCLK/HREF/VSYNC/D[7:0] are run through
// 2-FF synchronizers and PCLK's rising edge is detected as data. By the
// time the synchronized edge is seen (~3 sys clocks after the real edge),
// D has been stable for ~125 ns and stays stable for ~60 ns more - a wide
// sampling window. The entire design is therefore single-clock: no async
// FIFO, no Gray pointers, no CDC constraints.
//
// The OV7670 in RGB565 sends two bytes per pixel while HREF is high:
//   byte 0: {R[4:0], G[5:3]}   byte 1: {G[2:0], B[4:0]}
// i.e. big-endian RGB565 - exactly the order the ST7789 wants. The byte
// phase is re-armed at every HREF rising edge so a line can never come out
// of the FIFO byte-swapped.
//
// Crop: QVGA gives 320 pixels/line; the landscape panel shows 280. Columns
// 20..299 are kept (centered crop), rows 0..239 all kept -> exact 1:1 map,
// no scaler, no line memory.
//
// 'armed' gating: pixels are only pushed starting from the first VSYNC seen
// after 'enable' (camera configured AND display initialized), so the first
// streamed frame is aligned and the FIFO never overflows during boot.
// ============================================================================

module cam_capture (
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,       // SCCB done && ST7789 init done

    // raw camera pins
    input  wire        pclk_i,
    input  wire        vsync_i,
    input  wire        href_i,
    input  wire [7:0]  d_i,

    output reg  [15:0] pix_data,
    output reg         pix_wr,       // 1-cycle strobe into the FIFO
    output reg         frame_sync    // 1-cycle pulse at VSYNC rising edge
);

    localparam [8:0] COL_FIRST = 9'd20;    // crop window: keep 20..299
    localparam [8:0] COL_LAST  = 9'd299;
    localparam [7:0] ROW_MAX   = 8'd240;

    // ---------------- input synchronizers ----------------
    reg [2:0] pclk_s;
    reg [2:0] vs_s;
    reg [2:0] hr_s;
    reg [7:0] d_s0, d_s1;

    always @(posedge clk) begin
        pclk_s <= {pclk_s[1:0], pclk_i};
        vs_s   <= {vs_s[1:0],   vsync_i};
        hr_s   <= {hr_s[1:0],   href_i};
        d_s0   <= d_i;
        d_s1   <= d_s0;
    end

    wire pclk_rise = pclk_s[1] & ~pclk_s[2];
    wire vs_rise   = vs_s[1]   & ~vs_s[2];
    wire hr_rise   = hr_s[1]   & ~hr_s[2];
    wire href_lvl  = hr_s[1];

    // ---------------- capture state ----------------
    reg [8:0] col;        // pixel index within the line, 0..319
    reg [7:0] row;        // line index within the frame (saturating)
    reg       byte_ph;    // 0 = expecting high byte, 1 = expecting low byte
    reg [7:0] hi_byte;
    reg       armed;      // saw a VSYNC while enabled -> stream from here

    // Crop-window test, PIPELINED: col/row only change on (synchronized)
    // PCLK or HREF events, 12+ system clocks apart, so a registered flag
    // computed every cycle is always fresh long before the next use. This
    // keeps two 9-bit magnitude comparators out of the pixel-strobe cone
    // (they were the post-route critical path).
    reg in_win;
    always @(posedge clk)
        in_win <= (row < ROW_MAX) && (col >= COL_FIRST) && (col <= COL_LAST);

    always @(posedge clk) begin
        if (rst) begin
            col        <= 9'd0;
            row        <= 8'd0;
            byte_ph    <= 1'b0;
            hi_byte    <= 8'd0;
            armed      <= 1'b0;
            pix_wr     <= 1'b0;
            pix_data   <= 16'd0;
            frame_sync <= 1'b0;
        end else begin
            pix_wr     <= 1'b0;
            frame_sync <= 1'b0;

            // Frame boundary
            if (vs_rise) begin
                row <= 8'd0;
                if (enable) begin
                    armed      <= 1'b1;
                    frame_sync <= 1'b1;
                end
            end

            // Line boundary: re-arm column counter and byte phase.
            // (OV7670 moves HREF on PCLK falling edges, so hr_rise never
            //  coincides with a data sample edge; the else-if is only a
            //  belt-and-braces priority.)
            if (hr_rise) begin
                col     <= 9'd0;
                byte_ph <= 1'b0;
            end else if (pclk_rise && href_lvl && armed) begin
                if (!byte_ph) begin
                    hi_byte <= d_s1;
                    byte_ph <= 1'b1;
                end else begin
                    byte_ph <= 1'b0;
                    if (in_win) begin
                        pix_data <= {hi_byte, d_s1};
                        pix_wr   <= 1'b1;
                    end
                    col <= col + 9'd1;
                end
            end

            // Count lines on HREF falling edge (saturate, never wrap)
            if (~hr_s[1] & hr_s[2]) begin
                if (row != 8'hFF)
                    row <= row + 8'd1;
            end
        end
    end

endmodule
