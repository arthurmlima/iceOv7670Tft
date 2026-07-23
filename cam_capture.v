`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// cam_capture.v - OV7670 RGB565 receiver in the 39.00 MHz system domain.
//
// PCLK is treated as data, not as a clock.  With XCLK=19.500 MHz, CLKRC=/6,
// and COM14 PCLK=/2, PCLK is about 1.625 MHz.  That leaves 24 system-clock
// periods per PCLK period, so 2-FF synchronization and edge detection provide
// a generous sampling window without an asynchronous clock domain.
//
// OV7670 RGB565 byte order:
//   byte 0 = {R[4:0], G[5:3]}
//   byte 1 = {G[2:0], B[4:0]}
//
// QVGA is 320x240.  Columns 20..299 are retained for the 280x240 landscape
// panel window.  No scaler and no framebuffer are used.
// ============================================================================
module cam_capture (
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,

    input  wire        pclk_i,
    input  wire        vsync_i,
    input  wire        href_i,
    input  wire [7:0]  d_i,

    output reg  [15:0] pix_data,
    output reg         pix_wr,
    output reg         frame_sync
);
    localparam [8:0] COL_FIRST = 9'd20;
    localparam [8:0] COL_LAST  = 9'd299;
    localparam [7:0] ROW_MAX   = 8'd240;

    // ---------------- synchronized camera inputs ----------------
    reg [2:0] pclk_s;
    reg [2:0] vs_s;
    reg [2:0] hr_s;
    reg [7:0] d_s0;
    reg [7:0] d_s1;

    always @(posedge clk) begin
        if (rst) begin
            pclk_s <= 3'b000;
            vs_s   <= 3'b000;
            hr_s   <= 3'b000;
            d_s0   <= 8'h00;
            d_s1   <= 8'h00;
        end else begin
            pclk_s <= {pclk_s[1:0], pclk_i};
            vs_s   <= {vs_s[1:0],   vsync_i};
            hr_s   <= {hr_s[1:0],   href_i};
            d_s0   <= d_i;
            d_s1   <= d_s0;
        end
    end

    wire pclk_rise = pclk_s[1] & ~pclk_s[2];
    wire vs_rise   = vs_s[1]   & ~vs_s[2];
    wire hr_rise   = hr_s[1]   & ~hr_s[2];
    wire hr_fall   = ~hr_s[1]  & hr_s[2];
    wire href_lvl  = hr_s[1];

    // ---------------- byte assembly and crop ----------------
    reg [8:0] col;
    reg [7:0] row;
    reg       byte_phase;
    reg [7:0] hi_byte;
    reg       armed;
    reg       in_window;

    // Registered comparison removes the crop comparators from the pixel-write
    // strobe path.  Coordinates change only at the much slower PCLK edges.
    always @(posedge clk) begin
        if (rst)
            in_window <= 1'b0;
        else
            in_window <= (row < ROW_MAX) &&
                         (col >= COL_FIRST) && (col <= COL_LAST);
    end

    always @(posedge clk) begin
        if (rst) begin
            col        <= 9'd0;
            row        <= 8'd0;
            byte_phase <= 1'b0;
            hi_byte    <= 8'h00;
            armed      <= 1'b0;
            pix_data   <= 16'h0000;
            pix_wr     <= 1'b0;
            frame_sync <= 1'b0;
        end else begin
            pix_wr     <= 1'b0;
            frame_sync <= 1'b0;

            // Arm only on a clean frame boundary after both devices are ready.
            if (vs_rise) begin
                col        <= 9'd0;
                row        <= 8'd0;
                byte_phase <= 1'b0;
                if (enable) begin
                    armed      <= 1'b1;
                    frame_sync <= 1'b1;
                end else begin
                    armed <= 1'b0;
                end
            end

            // HREF rising starts a new line and re-aligns the two-byte phase.
            if (hr_rise) begin
                col        <= 9'd0;
                byte_phase <= 1'b0;
            end else if (pclk_rise && href_lvl && armed) begin
                if (!byte_phase) begin
                    hi_byte    <= d_s1;
                    byte_phase <= 1'b1;
                end else begin
                    byte_phase <= 1'b0;
                    if (in_window) begin
                        pix_data <= {hi_byte, d_s1};
                        pix_wr   <= 1'b1;
                    end
                    col <= col + 1'b1;
                end
            end

            if (hr_fall && !vs_rise && armed && (row != 8'hFF))
                row <= row + 1'b1;
        end
    end
endmodule
`default_nettype wire
