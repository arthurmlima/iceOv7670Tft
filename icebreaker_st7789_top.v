`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// icebreaker_st7789_top.v
//
// OV7670 -> 256x16 FIFO -> ST7789, no CPU and no external framebuffer.
// PLL stays at the original 39.00 MHz. Raising it to 42.00 MHz (see git
// history) closes timing with the *old* SPI engine, but once the SPI engine
// below was rebuilt with SB_IO DDR/NEG_TRIGGER cells, the added IO logic
// shifted placement enough that the unrelated async BTN_N -> tft_cs path
// (this design's recurring critical path) only cleared 42.00 MHz by 0.17%
// margin -- reproducible, but too close to PVT variation to trust on real
// hardware. 39.00 MHz with the new SPI engine reproducibly closes with
// 43.25 MHz max (10.9% margin), so the PLL was left at the safe baseline
// and all the speed gain was taken from the SPI/CLKRC changes instead.
//
// SPI now runs at a full sys_clk = 39.00 MHz (double the previous sys_clk/2
// ceiling) via an SB_IO DDR output cell for SCLK plus NEG_TRIGGER cells for
// MOSI/DC -- see spi_stream_tx.v. That headroom let the camera's CLKRC
// divider tighten from /3 to /2 (CAM_INT_HZ = XCLK/2 = 9.75 MHz) while
// *growing* the line-time margin from 4.76% to 28.6%, since display drain
// rate doubled (from the DDR SPI engine) while the camera clock only grew
// 1.5x. CLKRC=/1 (bypass) was checked and rejected: it makes the camera
// faster than the display can drain even at this SPI rate, see
// timing_check.py.
// ============================================================================
module icebreaker_st7789_top #(
    parameter integer USE_PLL            = 1,
    parameter integer SYS_CLK_HZ         = 39000000,
    parameter integer SPI_HZ             = 39000000,
    parameter integer POR_MS             = 10,
    parameter integer BL_ACTIVE_HIGH     = 1,
    parameter integer ENABLE_XORMAP      = 1,
    parameter integer ENCRYPTION_DEFAULT = 0,
    parameter [31:0]  XORMAP_INITIAL_SEED = 32'h1ACE_B00C
)(
    input  wire       CLK,
    input  wire       BTN_N,
    input  wire       BTN1,
    input  wire       BTN3,
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

    // A local registered reset keeps the XOR-map's high-fanout state control
    // off the already timing-sensitive top-level reset path.  Camera startup
    // takes far longer than this intentional one-cycle release delay.
    reg encryption_rst = 1'b1;
    always @(posedge clk_sys)
        encryption_rst <= rst;

    // ---------------- frame-safe encryption controls ----------------
    // The snap-off BTN1/BTN3 inputs are active-high.  BTN1 requests
    // encryption; BTN3 requests bypass and has priority if both are held.
    // Separate set/clear buttons make contact bounce harmless because it only
    // repeats the same idempotent assignment.  pixel_xor_stage applies the
    // request at the next accepted frame boundary.
    (* ASYNC_REG = "TRUE" *) reg [1:0] btn1_sync = 2'b00;
    (* ASYNC_REG = "TRUE" *) reg [1:0] btn3_sync = 2'b00;
    reg encrypt_requested = (ENCRYPTION_DEFAULT != 0);

    always @(posedge clk_sys) begin
        if (rst) begin
            btn1_sync         <= 2'b00;
            btn3_sync         <= 2'b00;
            encrypt_requested <= (ENCRYPTION_DEFAULT != 0);
        end else begin
            btn1_sync <= {btn1_sync[0], BTN1};
            btn3_sync <= {btn3_sync[0], BTN3};

            if (btn3_sync[1])
                encrypt_requested <= 1'b0;
            else if (btn1_sync[1])
                encrypt_requested <= 1'b1;
        end
    end

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

    // ---------------- atomic camera/display frame acceptance ----------------
    // A new camera frame is accepted only while the display is waiting for it.
    // If the display is still busy, retain its remaining FIFO data and suppress
    // the complete incoming frame instead of mixing it into the old RAMWR.
    wire accepted_frame_sync;
    wire accepted_cap_wr;
    wire dropped_frame_error;
    wire lcd_frame_ready = lcd_init_done && !lcd_stream_active;

    frame_stream_gate frame_gate (
        .clk           (clk_sys),
        .rst           (rst),
        .frame_sync_i  (cap_frame_sync),
        .frame_ready_i (lcd_frame_ready),
        .pixel_valid_i (cap_wr),
        .frame_sync_o  (accepted_frame_sync),
        .pixel_valid_o (accepted_cap_wr),
        .drop_error    (dropped_frame_error)
    );

    // ---------------- frame-seeded pixel encryption ----------------
    wire [15:0] encrypted_pixel;
    wire        encrypted_wr;
    wire        encryption_active;

    pixel_xor_stage #(
        .ENABLE_XORMAP      (ENABLE_XORMAP),
        .ENCRYPTION_DEFAULT (ENCRYPTION_DEFAULT),
        .INITIAL_SEED       (XORMAP_INITIAL_SEED)
    ) encryption (
        .clk           (clk_sys),
        .rst           (encryption_rst),
        .frame_sync    (accepted_frame_sync),
        .enable_i      (encrypt_requested),
        .pixel_i       (cap_pixel),
        .pixel_valid_i (accepted_cap_wr),
        .pixel_o       (encrypted_pixel),
        .pixel_valid_o (encrypted_wr),
        .encrypt_active (encryption_active)
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
        .flush     (accepted_frame_sync),
        .wr_en     (encrypted_wr),
        .wr_data   (encrypted_pixel),
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
    wire tft_sclk_d0, tft_sclk_d1, tft_mosi_bit, tft_dc_bit;

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
        .frame_sync    (accepted_frame_sync),
        .fifo_empty    (fifo_empty),
        .fifo_rd_data  (fifo_rd_data),
        .fifo_rd_valid (fifo_rd_valid),
        .fifo_rd_en    (fifo_rd_en),
        .tft_sclk_d0   (tft_sclk_d0),
        .tft_sclk_d1   (tft_sclk_d1),
        .tft_mosi_bit  (tft_mosi_bit),
        .tft_cs_n      (tft_cs),
        .tft_dc_bit    (tft_dc_bit),
        .tft_resn      (tft_res),
        .tft_bl        (bl_raw),
        .init_done     (lcd_init_done),
        .frame_done    (lcd_frame_done),
        .sync_error    (lcd_sync_error),
        .stream_active (lcd_stream_active)
    );

    // SCLK = clk_sys via an SB_IO DDR output cell: D_OUT_0 (rising-clk
    // phase) pulses high while spi_stream_tx is sending a bit, D_OUT_1
    // (falling-clk phase) is tied low so every bit gets its own discrete
    // pulse instead of a stretched-out one across a multi-bit burst.
    SB_IO #(
        .PIN_TYPE (6'b010000),
        .PULLUP   (1'b0)
    ) tft_sclk_io (
        .PACKAGE_PIN (tft_scl),
        .OUTPUT_CLK  (clk_sys),
        .D_OUT_0     (tft_sclk_d0),
        .D_OUT_1     (tft_sclk_d1)
    );

    // MOSI/DC = registered on clk_sys's falling edge (NEG_TRIGGER), giving
    // a half clk_sys-cycle setup margin ahead of the SCLK rising edge that
    // samples them. Verified in simulation against the SB_IO behavioral
    // model -- see spi_stream_tx.v.
    SB_IO #(
        .PIN_TYPE    (6'b010100),
        .NEG_TRIGGER (1'b1),
        .PULLUP      (1'b0)
    ) tft_mosi_io (
        .PACKAGE_PIN (tft_sda),
        .OUTPUT_CLK  (clk_sys),
        .D_OUT_0     (tft_mosi_bit)
    );

    SB_IO #(
        .PIN_TYPE    (6'b010100),
        .NEG_TRIGGER (1'b1),
        .PULLUP      (1'b0)
    ) tft_dc_io (
        .PACKAGE_PIN (tft_dc),
        .OUTPUT_CLK  (clk_sys),
        .D_OUT_0     (tft_dc_bit)
    );

    assign tft_blk = BL_ACTIVE_HIGH ? bl_raw : ~bl_raw;

    // Green: both devices initialized. Red: sticky stream/FIFO timing fault.
    wire stream_fault = fifo_overflow || fifo_underflow || lcd_sync_error ||
                        dropped_frame_error;
    assign LEDG_N = ~stream_enable;
    assign LEDR_N = ~stream_fault;

    // Explicitly consume status nets that are useful for probing but not pins.
    wire _unused_ok = &{1'b0, fifo_full, fifo_level[8], lcd_frame_done,
                        lcd_stream_active, encryption_active};
endmodule
`default_nettype wire
