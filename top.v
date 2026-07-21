// ============================================================================
// top.v - iCEBreaker (iCE40UP5K-SG48) OV7670 -> ST7789 240x280, no CPU.
//
// Clock plan (single PLL, single domain):
//   12 MHz xtal -> SB_PLL40_PAD -> 48 MHz sys
//     SCK  = 24 MHz  (spi8: 2 sys clocks per bit)
//     XCLK = 24 MHz  (toggle FF) -> OV7670 CLKRC/3 -> f_int 8 MHz
//                    -> QVGA PCLK 4 MHz, sampled as DATA at 48 MHz
//   One display line (280x16 SCK) fits in one camera line (1568 f_int):
//   24 MHz >= 2.857 x 8 MHz. Frame rate 8e6/(510x1568) = 10.0 fps,
//   display genlocked to the camera.
//
// LEDs (active low):
//   green = camera SCCB done AND panel init done (streaming)
//   red   = pixel FIFO ever overflowed (should stay dark)
// BTN (user button) = manual reset.
// ============================================================================

module top (
    input  wire       CLK,        // 12 MHz
    input  wire       BTN_N,
    output wire       LEDR_N,
    output wire       LEDG_N,

    // camera (PMOD1A = D[7:0], PMOD1B = control)
    output wire       CAM_XCLK,
    input  wire       CAM_PCLK,
    input  wire       CAM_HREF,
    input  wire       CAM_VSYNC,
    input  wire [7:0] CAM_D,
    output wire       CAM_SIOC,
    inout  wire       CAM_SIOD,
    output wire       CAM_RST_N,
    output wire       CAM_PWDN,

    // ST7789 (PMOD2)
    output wire       LCD_SCK,
    output wire       LCD_MOSI,
    output wire       LCD_DC,
    output wire       LCD_CS_N,
    output wire       LCD_RES_N,
    output wire       LCD_BL
);

    // ---------------- PLL: 12 -> 48 MHz (icepll -i 12 -o 48) ----------------
    wire clk;
    wire pll_lock;

    SB_PLL40_PAD #(
        .FEEDBACK_PATH ("SIMPLE"),
        .DIVR          (4'b0000),
        .DIVF          (7'b0111111),
        .DIVQ          (3'b100),
        .FILTER_RANGE  (3'b001)
    ) u_pll (
        .PACKAGEPIN    (CLK),
        .PLLOUTGLOBAL  (clk),
        .RESETB        (1'b1),
        .BYPASS        (1'b0),
        .LOCK          (pll_lock)
    );

    // ---------------- power-on reset + button ----------------
    reg [1:0]  lock_s = 2'b00;
    reg [15:0] por    = 16'd0;
    reg [1:0]  btn_s  = 2'b11;

    always @(posedge clk) begin
        lock_s <= {lock_s[0], pll_lock};
        btn_s  <= {btn_s[0], BTN_N};
        if (!lock_s[1])
            por <= 16'd0;
        else if (!por[15])
            por <= por + 16'd1;
    end

    wire rst = ~por[15] | ~btn_s[1];

    // ---------------- XCLK = 24 MHz ----------------
    // Free-running from configuration (not held in reset) so the camera has
    // a clock well before its first SCCB transaction.
    reg xclk_r = 1'b0;
    always @(posedge clk) xclk_r <= ~xclk_r;
    assign CAM_XCLK = xclk_r;

    assign CAM_RST_N = ~rst;    // hard-reset the camera on POR / button
    assign CAM_PWDN  = 1'b0;

    // ---------------- SCCB (camera init) ----------------
    wire sioc;
    wire siod_low;
    wire sccb_done;

    cam_init u_ci (
        .clk      (clk),
        .rst      (rst),
        .sioc     (sioc),
        .siod_low (siod_low),
        .done     (sccb_done)
    );

    assign CAM_SIOC = sioc;

    // SIOD is open-drain: drive 0 or release, with the pin's pull-up on.
    // (Most OV7670 modules also have their own pull-ups; both is fine.)
    SB_IO #(
        .PIN_TYPE (6'b1010_01),   // tristate output, simple input
        .PULLUP   (1'b1)
    ) u_siod (
        .PACKAGE_PIN   (CAM_SIOD),
        .OUTPUT_ENABLE (siod_low),
        .D_OUT_0       (1'b0),
        .D_IN_0        ()
    );

    // ---------------- display controller ----------------
    wire [15:0] fifo_rdata;
    wire        fifo_empty;
    wire        fifo_rd;
    wire        fifo_clear;
    wire        init_done;
    wire        frame_sync;

    st7789_ctrl u_lcd (
        .clk        (clk),
        .rst        (rst),
        .frame_sync (frame_sync),
        .fifo_rdata (fifo_rdata),
        .fifo_empty (fifo_empty),
        .fifo_rd    (fifo_rd),
        .fifo_clear (fifo_clear),
        .lcd_sck    (LCD_SCK),
        .lcd_mosi   (LCD_MOSI),
        .lcd_dc     (LCD_DC),
        .lcd_res_n  (LCD_RES_N),
        .lcd_cs_n   (LCD_CS_N),
        .lcd_bl     (LCD_BL),
        .init_done  (init_done)
    );

    // ---------------- camera capture ----------------
    wire [15:0] pix_data;
    wire        pix_wr;
    wire        cap_en = sccb_done & init_done;

    cam_capture u_cap (
        .clk        (clk),
        .rst        (rst),
        .enable     (cap_en),
        .pclk_i     (CAM_PCLK),
        .vsync_i    (CAM_VSYNC),
        .href_i     (CAM_HREF),
        .d_i        (CAM_D),
        .pix_data   (pix_data),
        .pix_wr     (pix_wr),
        .frame_sync (frame_sync)
    );

    // ---------------- the one and only image memory ----------------
    wire fifo_full;
    wire fifo_ovf;

    pixel_fifo u_fifo (
        .clk      (clk),
        .rst      (rst),
        .clear    (fifo_clear),
        .wr       (pix_wr),
        .wdata    (pix_data),
        .full     (fifo_full),
        .rd       (fifo_rd),
        .rdata    (fifo_rdata),
        .empty    (fifo_empty),
        .overflow (fifo_ovf)
    );

    // ---------------- status ----------------
    assign LEDG_N = ~(sccb_done & init_done);
    assign LEDR_N = ~fifo_ovf;

endmodule
