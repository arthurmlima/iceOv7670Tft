`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// icebreaker_st7789_top.v
//
// OV7670 -> 256x16 FIFO -> ST7789, no CPU and no external framebuffer.
// The display wiring and 39.00 MHz PLL are retained from the working test
// pattern project. Camera timing is deliberately slowed to match the proven
// 9.75 MHz SPI interface.
// ============================================================================
module icebreaker_st7789_top #(
    parameter integer USE_PLL        = 1,
    parameter integer SYS_CLK_HZ     = 39000000,
    parameter integer SPI_HZ         = 9750000,
    parameter integer POR_MS         = 10,
    parameter integer BL_ACTIVE_HIGH = 1
)(
    input  wire       CLK,
    input  wire       BTN_N,
    output wire       LEDR_N,
    output wire       LEDG_N,

    // ST7789 - existing working display pins
    output wire       tft_scl,
    output wire       tft_sda,
    output wire       tft_res,
    output wire       tft_dc,
    output wire       tft_cs,
    output wire       tft_blk,

    // OV7670
    input  wire [7:0] cam_d,
    output wire       cam_xclk,
    input  wire       cam_pclk,
    input  wire       cam_href,
    input  wire       cam_vsync,
    output wire       cam_sioc,
    inout  wire       cam_siod,
    output wire       cam_rst_n,
    output wire       cam_pwdn
);
    // ---------------- system clock ----------------
    wire clk_sys;
    wire pll_lock;

    generate
        if (USE_PLL != 0) begin : g_pll
            wire pll_clk;
            // 12 MHz * (51+1) / 2^4 = 39.00 MHz
            SB_PLL40_PAD #(
                .FEEDBACK_PATH("SIMPLE"),
                .DIVR(4'b0000),
                .DIVF(7'b0110011),
                .DIVQ(3'b100),
                .FILTER_RANGE(3'b001)
            ) pll (
                .PACKAGEPIN   (CLK),
                .PLLOUTGLOBAL (pll_clk),
                .LOCK         (pll_lock),
                .RESETB       (1'b1),
                .BYPASS       (1'b0)
            );
            assign clk_sys = pll_clk;
        end else begin : g_bypass
            assign clk_sys  = CLK;
            assign pll_lock = 1'b1;
        end
    endgenerate

    // ---------------- synchronized reset / POR ----------------
    localparam integer POR_CYCLES = (SYS_CLK_HZ/1000)*POR_MS;
    localparam integer POR_W = (POR_CYCLES <= 2) ? 1 : $clog2(POR_CYCLES+1);

    reg [POR_W-1:0] por_count = {POR_W{1'b0}};
    reg btn_meta = 1'b1;
    reg btn_sync = 1'b1;

    always @(posedge clk_sys) begin
        btn_meta <= BTN_N;
        btn_sync <= btn_meta;

        if (!pll_lock || !btn_sync)
            por_count <= {POR_W{1'b0}};
        else if (por_count < POR_CYCLES)
            por_count <= por_count + 1'b1;
    end

    wire resetn = pll_lock && btn_sync && (por_count >= POR_CYCLES);
    wire rst = !resetn;

    // ---------------- camera clock and static controls ----------------
    reg cam_xclk_q;
    always @(posedge clk_sys) begin
        if (rst)
            cam_xclk_q <= 1'b0;
        else
            cam_xclk_q <= ~cam_xclk_q;
    end

    assign cam_xclk  = cam_xclk_q;  // 19.500 MHz
    assign cam_rst_n = resetn;
    assign cam_pwdn  = 1'b0;

    // ---------------- SCCB configuration ----------------
    wire cam_siod_low;
    wire cam_cfg_done;

    cam_init #(
        .TICK_DIV   (98),
        .BOOT_TICKS (4000),
        .GAP_TICKS  (800),
        .RST_TICKS  (4000)
    ) camera_config (
        .clk      (clk_sys),
        .rst      (rst),
        .sioc     (cam_sioc),
        .siod_low (cam_siod_low),
        .done     (cam_cfg_done)
    );

    // Open-drain SIOD with an internal pull-up. OUTPUT_ENABLE=1 drives zero;
    // OUTPUT_ENABLE=0 releases the line.
    SB_IO #(
        .PIN_TYPE (6'b101001),
        .PULLUP   (1'b1)
    ) cam_siod_io (
        .PACKAGE_PIN   (cam_siod),
        .OUTPUT_ENABLE (cam_siod_low),
        .D_OUT_0       (1'b0)
    );

    // ---------------- panel controller status ----------------
    wire lcd_init_done;
    wire lcd_frame_done;
    wire lcd_sync_error;
    wire lcd_stream_active;
    wire bl_raw;
    wire stream_enable = cam_cfg_done && lcd_init_done;

    // ---------------- camera capture ----------------
    wire [15:0] cap_pixel;
    wire        cap_wr;
    wire        cap_frame_sync;

    cam_capture capture (
        .clk        (clk_sys),
        .rst        (rst),
        .enable     (stream_enable),
        .pclk_i     (cam_pclk),
        .vsync_i    (cam_vsync),
        .href_i     (cam_href),
        .d_i        (cam_d),
        .pix_data   (cap_pixel),
        .pix_wr     (cap_wr),
        .frame_sync (cap_frame_sync)
    );

    // ---------------- one-EBR rate-matching FIFO ----------------
    wire        fifo_full;
    wire        fifo_empty;
    wire [15:0] fifo_rd_data;
    wire        fifo_rd_valid;
    wire        fifo_rd_en;
    wire        fifo_overflow;
    wire        fifo_underflow;
    wire [8:0]  fifo_level;

    pixel_fifo fifo (
        .clk       (clk_sys),
        .rst       (rst),
        .flush     (cap_frame_sync),
        .wr_en     (cap_wr),
        .wr_data   (cap_pixel),
        .full      (fifo_full),
        .rd_en     (fifo_rd_en),
        .rd_data   (fifo_rd_data),
        .rd_valid  (fifo_rd_valid),
        .empty     (fifo_empty),
        .overflow  (fifo_overflow),
        .underflow (fifo_underflow),
        .level     (fifo_level)
    );

    // ---------------- ST7789 camera stream ----------------
    st7789_camera_ctrl #(
        .CLK_HZ     (SYS_CLK_HZ),
        .SPI_HZ     (SPI_HZ),
        .WIDTH      (280),
        .HEIGHT     (240),
        .X_SHIFT    (20),
        .Y_SHIFT    (0),
        .MADCTL_VAL (8'hA0)
    ) display (
        .clk           (clk_sys),
        .resetn        (resetn),
        .stream_enable (stream_enable),
        .frame_sync    (cap_frame_sync),
        .fifo_empty    (fifo_empty),
        .fifo_rd_data  (fifo_rd_data),
        .fifo_rd_valid (fifo_rd_valid),
        .fifo_rd_en    (fifo_rd_en),
        .tft_sclk      (tft_scl),
        .tft_mosi      (tft_sda),
        .tft_cs_n      (tft_cs),
        .tft_dc        (tft_dc),
        .tft_resn      (tft_res),
        .tft_bl        (bl_raw),
        .init_done     (lcd_init_done),
        .frame_done    (lcd_frame_done),
        .sync_error    (lcd_sync_error),
        .stream_active (lcd_stream_active)
    );

    assign tft_blk = BL_ACTIVE_HIGH ? bl_raw : ~bl_raw;

    // Green: both devices initialized. Red: sticky stream/FIFO timing fault.
    wire stream_fault = fifo_overflow || fifo_underflow || lcd_sync_error;
    assign LEDG_N = ~stream_enable;
    assign LEDR_N = ~stream_fault;

    // Explicitly consume status nets that are useful for probing but not pins.
    wire _unused_ok = &{1'b0, fifo_full, fifo_level[8], lcd_frame_done,
                        lcd_stream_active};
endmodule
`default_nettype wire
