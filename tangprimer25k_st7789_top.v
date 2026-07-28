`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// tangprimer25k_st7789_top.v
//
// Sipeed Tang Primer 25K (Gowin GW5A-25A) port of the iCEBreaker
// OV7670 -> 256x16 FIFO -> ST7789 viewfinder.  Everything below the top level
// is unchanged, device-independent RTL; only the clock source, the four
// device primitives (PLL, three SPI output cells, the SCCB IO buffer) and the
// board's buttons/LEDs differ from the iCE40 build.
//
// ---------------------------------------------------------------------------
// Clock plan
// ---------------------------------------------------------------------------
// The dock oscillator is 50.000 MHz (the iCEBreaker's was 12 MHz), so the PLL
// settings had to be recomputed.  clk_sys is 40.000 MHz, deliberately close to
// the iCE40 build's 39.000 MHz, which keeps the two absolute limits at values
// that were already exercised on hardware: ST7789 SCLK at 40 MHz and OV7670
// XCLK at 20 MHz.
//
// Frame rate is set by one thing only -- the camera's internal clock:
//
//     fps = f_int / 799680          (510 lines x 1568 internal clocks)
//
// The iCE40 design ran f_int at clk_sys/4 (XCLK = clk_sys/2, CLKRC = /2),
// which made the camera's active-video pixel rate f_int/4 exactly equal to the
// panel's drain rate SPI/16.  With the two rates identical the FIFO never
// accumulates, which is why 256 entries sufficed -- but it also pinned the
// frame rate at 12.5 fps while the panel could have sustained 37.2.
//
// CLKRC is now bypassed and XCLK comes from its own 24 MHz PLL output, so
// f_int = 24 MHz -- the OV7670's rated maximum -- and the frame rate is
// 30.0 fps, 2.4x the iCE40 design, with the panel still clocked at 40 MHz.
//
// Two consequences, both handled below:
//
//   * The camera outruns the panel during active video.  The surplus is the
//     integral of the rate difference over the active region, up to 28000
//     pixels; hence FIFO_DEPTH.  See timing_check.py.
//
//   * PCLK (= f_int/2 = 12 MHz) is no longer slow enough to oversample in the
//     clk_sys domain, which gives only 4 samples per PCLK period.  cam_capture
//     now runs on its own 100 MHz PLL output (8.3 samples per period) and
//     async_fifo carries pixels into clk_sys.  That is the only clock-domain
//     crossing in the design: frame_stream_gate, pixel_xor_stage and
//     pixel_fifo all stay single-clock in clk_sys, unchanged, including
//     pixel_fifo's flush-on-frame-boundary which could not be done safely
//     across domains.  See README section 4.3 for why cam_capture does not
//     simply clock on PCLK itself.
//
// ---------------------------------------------------------------------------
// SPI output cells: SB_IO -> ODDR
// ---------------------------------------------------------------------------
// spi_stream_tx emits one bit per clk_sys cycle, so SCLK has to toggle at the
// full clk_sys rate and cannot come out of ordinary fabric flops.  On iCE40
// that was an SB_IO DDR cell for SCLK plus NEG_TRIGGER (falling-edge) cells
// for MOSI/DC.  Gowin's equivalent is ODDR, whose Q0 drives D0 while CLK is
// high and D1 while CLK is low -- the same "SCLK = active AND clk_high"
// discrete-pulse-per-bit behaviour SB_IO gave.
//
// The one thing that does *not* carry over is latency.  An SB_IO output
// register is one clk_sys cycle deep; Gowin's ODDR is three (D0/D1 each pass
// d*_reg_0 -> d*_reg_1 -> d*_reg_2 before reaching the pad).  Two consequences,
// both handled below:
//
//   1. MOSI/DC must still change half a cycle *before* the SCLK rising edge
//      that samples them.  Feeding an ODDR D0 with the bit delayed one cycle
//      and D1 with the undelayed bit puts the transition in the middle of the
//      cycle before the pulse.  Writing b(N) for the bit spi_stream_tx
//      presents in cycle N: MOSI holds b(N) from mid-cycle N+3 to mid-cycle
//      N+4, and SCLK (fed the *delayed* "active" flag, so its pulse for b(N)
//      lands in cycle N+4) rises at the start of cycle N+4 -- half a cycle of
//      setup and half a cycle of hold, exactly as on iCE40.
//
//   2. CS must move with the data.  st7789_camera_ctrl deasserts tft_cs_n two
//      cycles after the last bit's cycle, which was safe when the pad was one
//      cycle behind the fabric and is *not* safe when it is four: CS would
//      rise two cycles before the final SCLK pulse and truncate the last byte.
//      Routing CS through its own ODDR (D0 = D1, so no mid-cycle transition)
//      gives it the identical four-cycle path, restoring the original
//      "CS releases after the last SCLK pulse" ordering with a cycle to spare.
//
// This relationship is checked by tb_spi_gowin_io.v against Gowin's own ODDR
// behavioural model, the same way the iCE40 version was checked against
// SB_IO -- getting the phase wrong here silently corrupts every byte.
// ============================================================================
module tangprimer25k_st7789_top #(
    parameter integer USE_PLL            = 1,
    parameter integer SYS_CLK_HZ         = 40000000,
    parameter integer SPI_HZ             = 40000000,
    parameter integer POR_MS             = 10,
    parameter integer DEBOUNCE_MS        = 10,
    parameter integer BL_ACTIVE_HIGH     = 1,
    parameter integer LED_ACTIVE_HIGH    = 1,
    parameter integer ENABLE_XORMAP      = 1,
    parameter integer ENCRYPTION_DEFAULT = 0,
    parameter [31:0]  XORMAP_INITIAL_SEED = 32'h1ACE_B00C,
    // 1 = replace the camera with the built-in moving test pattern, keeping
    // the camera's exact pixel/line/frame timing.  Used to bisect the
    // pipeline; see tangprimer25k_pattern_top.v and `make pattern`.
    parameter integer PATTERN_SOURCE     = 0
)(
    // Dock board: 50 MHz oscillator, two active-high buttons, two status LEDs
    input  wire       clk50,
    input  wire       btn_s1,      // reset / re-init
    input  wire       btn_s2,      // toggle pixel encryption
    output wire       led_ready,   // READY LED: camera + panel initialised
    output wire       led_done,    // DONE LED: sticky stream fault

    // ST7789 - PMOD J6
    output wire       tft_scl,
    output wire       tft_sda,
    output wire       tft_res,
    output wire       tft_dc,
    output wire       tft_cs,
    output wire       tft_blk,

    // OV7670 - PMODs J4 + J5.  The sensor's 18-pin ribbon header is split one
    // row per connector in the sensor board's own pin order, so cam_d[] ends
    // up interleaved across the two (odd bits on J4, even bits on J5).  See
    // tangprimer25k.cst; cam_capture samples the bus synchronously and does
    // not care where the bits land.
    output wire       cam_xclk,
    input  wire       cam_pclk,
    input  wire       cam_href,
    input  wire       cam_vsync,
    output wire       cam_sioc,
    inout  wire       cam_siod,
    output wire       cam_rst_n,
    output wire       cam_pwdn,
    input  wire [7:0] cam_d
);
    // ---------------- camera clock ----------------
    // CLKRC is bypassed, so the sensor's internal clock is XCLK exactly and
    // PCLK (COM14 = /2) is half of it.
    localparam integer CAM_XCLK_HZ = 24000000;
    localparam integer CAM_INT_HZ  = CAM_XCLK_HZ;

    // Worst case the sensor emits its 240 output lines back to back, giving
    // the panel 240*1568/f_int = 15.7 ms to drain 67200 pixels at SPI/16.
    // It manages 39200, so 28000 have to wait.  DEPTH need not be a power of
    // two (pixel_fifo wraps its pointers explicitly), which matters here:
    // 65536 pixels would be 1024 Kb and would not fit in the 1008 Kb of BSRAM
    // at all, while 40960 leaves 46% headroom over the deficit and still fits.
    localparam integer FIFO_DEPTH = 40960;
    localparam integer FIFO_AW    = $clog2(FIFO_DEPTH);

    // Test-pattern timing, in clk_sys cycles, tracking the camera it stands in
    // for: 4 internal clocks per pixel, 1568 per line.  Scaled in kHz so the
    // products stay inside a 32-bit integer.
    localparam integer PAT_PIX_CYCLES  = (4*(SYS_CLK_HZ/1000))/(CAM_INT_HZ/1000);
    localparam integer PAT_LINE_CYCLES = (1568*(SYS_CLK_HZ/1000))/(CAM_INT_HZ/1000);

    // ---------------- system and camera clocks ----------------
    wire clk_sys;
    wire clk_xclk;
    wire clk_cap;
    wire pll_lock;

    generate
        if (USE_PLL != 0) begin : g_pll
            // 50 MHz -> 40 MHz (clk_sys) and 24 MHz (camera XCLK).
            // USE_PLL=0 is a fallback that runs clk_sys from the raw 50 MHz
            // oscillator and gives up on 30 fps: it has no 24 MHz source, so
            // XCLK falls back to clk_sys/2.  SYS_CLK_HZ/SPI_HZ/CAM_XCLK_HZ
            // must be overridden to match.
            gowin_pll pll (
                .clkin   (clk50),
                .clkout0 (clk_sys),
                .clkout1 (clk_xclk),
                .clkout2 (clk_cap),
                .lock    (pll_lock)
            );
        end else begin : g_bypass
            reg xclk_div = 1'b0;
            always @(posedge clk50) xclk_div <= ~xclk_div;
            assign clk_sys  = clk50;
            assign clk_xclk = xclk_div;
            assign clk_cap  = clk50;
            assign pll_lock = 1'b1;
        end
    endgenerate

    // ---------------- synchronized reset / POR ----------------
    // S1 is active high (external 100R to +3V3, internal pull-down holds it
    // low when released), so the sense is inverted from the iCEBreaker's
    // active-low BTN_N.  Bounce on S1 is harmless: it only restarts the POR
    // counter.
    localparam integer POR_CYCLES = (SYS_CLK_HZ/1000)*POR_MS;
    localparam integer POR_W = (POR_CYCLES <= 2) ? 1 : $clog2(POR_CYCLES+1);

    reg [POR_W-1:0] por_count = {POR_W{1'b0}};
    (* ASYNC_REG = "TRUE" *) reg btn_meta = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg btn_sync = 1'b0;

    always @(posedge clk_sys) begin
        btn_meta <= btn_s1;
        btn_sync <= btn_meta;

        if (!pll_lock || btn_sync)
            por_count <= {POR_W{1'b0}};
        else if (por_count < POR_CYCLES)
            por_count <= por_count + 1'b1;
    end

    wire resetn = pll_lock && !btn_sync && (por_count >= POR_CYCLES);
    wire rst = !resetn;

    // A local registered reset keeps the XOR-map's high-fanout state control
    // off the already timing-sensitive top-level reset path.  Camera startup
    // takes far longer than this intentional one-cycle release delay.
    reg encryption_rst = 1'b1;
    always @(posedge clk_sys)
        encryption_rst <= rst;

    // Same idea for the reset that crosses into the capture domain: `rst` is
    // combinational off the POR counter's comparator, and launching a
    // clock-domain crossing from that much logic left the first synchroniser
    // flop 1 ns short.  A crossing should always start at a flop.
    reg cam_rst_q = 1'b1;
    always @(posedge clk_sys)
        cam_rst_q <= rst;

    // ---------------- frame-safe encryption control ----------------
    // The iCEBreaker had three buttons and could afford separate set (BTN1)
    // and clear (BTN3) inputs, which made contact bounce harmless because
    // every bounce repeated the same idempotent assignment.  This board has
    // two buttons and S1 is already the reset, so S2 is a *toggle* and must
    // be debounced properly: one press = one flip.  pixel_xor_stage still
    // applies the request only at the next accepted frame boundary, so a
    // press can never produce a half-encrypted image.
    localparam integer DEBOUNCE_CYCLES = (SYS_CLK_HZ/1000)*DEBOUNCE_MS;

    wire s2_level;
    wire s2_press;

    btn_debounce #(.STABLE_CYCLES(DEBOUNCE_CYCLES)) s2_button (
        .clk     (clk_sys),
        .rst     (rst),
        .btn_i   (btn_s2),
        .level_o (s2_level),
        .rise_o  (s2_press)
    );

    reg encrypt_requested = (ENCRYPTION_DEFAULT != 0);

    always @(posedge clk_sys) begin
        if (rst)
            encrypt_requested <= (ENCRYPTION_DEFAULT != 0);
        else if (s2_press)
            encrypt_requested <= ~encrypt_requested;
    end

    // ---------------- camera clock and static controls ----------------
    // Forward the 24 MHz PLL output to the pad through an ODDR rather than
    // routing a clock net to a general output: this is the standard way to get
    // a clean full-rate, 50%-duty clock off-chip on Gowin, and it keeps the
    // clock on clock resources right up to the pin.
    ODDR cam_xclk_io (
        .Q0  (cam_xclk),
        .Q1  (),
        .D0  (1'b1),
        .D1  (1'b0),
        .TX  (1'b0),
        .CLK (clk_xclk)
    );

    assign cam_rst_n = resetn;
    assign cam_pwdn  = 1'b0;

    // ---------------- SCCB configuration ----------------
    wire cam_siod_low;
    wire cam_siod_in;
    wire cam_cfg_done;

    // TICK_DIV is the only clock-dependent camera parameter: it sets the SCCB
    // quarter-bit tick to ~400 kHz (a ~100 kHz bit rate) from clk_sys.
    cam_init #(
        .TICK_DIV   (SYS_CLK_HZ/400000),
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

    // Open-drain SIOD.  OEN=0 drives the pad, so cam_siod_low=1 pulls the line
    // to 0 and cam_siod_low=0 releases it to the pin's pull-up (PULL_MODE=UP
    // in the .cst -- the iCE40 build set the same pull-up via SB_IO PULLUP).
    IOBUF cam_siod_io (
        .O   (cam_siod_in),
        .IO  (cam_siod),
        .I   (1'b0),
        .OEN (~cam_siod_low)
    );

    // ---------------- panel controller status ----------------
    wire lcd_init_done;
    wire lcd_frame_done;
    wire lcd_sync_error;
    wire lcd_starve_error;
    wire lcd_stream_active;
    wire bl_raw;
    wire stream_enable = cam_cfg_done && lcd_init_done;

    // ---------------- pixel source ----------------
    // The camera half lives in the PCLK domain and reaches clk_sys through
    // async_fifo; the test pattern is generated directly in clk_sys, since it
    // has no external strobe to follow.  Either way the rest of the design
    // sees the same {cap_pixel, cap_wr, cap_frame_sync} interface.
    wire [15:0] cap_pixel;
    wire        cap_wr;
    wire        cap_frame_sync;
    wire        cdc_overflow;

    generate
        if (PATTERN_SOURCE != 0) begin : g_pattern
            assign cdc_overflow = 1'b0;

            test_pattern_src #(
                .WIDTH       (280),
                .HEIGHT      (240),
                .PIX_CYCLES  (PAT_PIX_CYCLES),
                .LINE_CYCLES (PAT_LINE_CYCLES),
                .TOTAL_LINES (510)
            ) source (
                .clk        (clk_sys),
                .rst        (rst),
                .enable     (stream_enable),
                .pix_data   (cap_pixel),
                .pix_wr     (cap_wr),
                .frame_sync (cap_frame_sync)
            );
        end else begin : g_camera
            // --- reset and enable into the capture domain ---
            // clk_cap and clk_sys come from the same PLL, so these crossings
            // are benign, but both signals are slow and the synchronisers cost
            // nothing.
            (* ASYNC_REG = "TRUE" *) reg [1:0] cap_rst_sync = 2'b11;
            always @(posedge clk_cap)
                cap_rst_sync <= {cap_rst_sync[0], cam_rst_q};
            wire cap_rst = cap_rst_sync[1];

            // stream_enable only changes once, hundreds of ms after reset.
            (* ASYNC_REG = "TRUE" *) reg [1:0] cap_en_sync = 2'b00;
            always @(posedge clk_cap) begin
                if (cap_rst) cap_en_sync <= 2'b00;
                else         cap_en_sync <= {cap_en_sync[0], stream_enable};
            end

            // --- capture, in the 100 MHz clk_cap domain ---
            wire [15:0] cap_src_pixel;
            wire        cap_src_wr;
            wire        cap_src_frame_sync;

            cam_capture capture (
                .clk        (clk_cap),
                .rst        (cap_rst),
                .enable     (cap_en_sync[1]),
                .pclk_i     (cam_pclk),
                .vsync_i    (cam_vsync),
                .href_i     (cam_href),
                .d_i        (cam_d),
                .pix_data   (cap_src_pixel),
                .pix_wr     (cap_src_wr),
                .frame_sync (cap_src_frame_sync)
            );

            // --- clk_cap -> clk_sys ---
            // Pixels and frame boundaries share one FIFO so their order is
            // preserved by construction.  cam_capture never emits both in the
            // same cycle: frame_sync fires on the VSYNC edge, where HREF is
            // low, so no byte is in flight.
            wire        cdc_full;
            wire        cdc_empty;
            wire [16:0] cdc_rd_data;

            // AW=3 (8 entries) rather than 16: pixels arrive one per ~17
            // clk_cap cycles and leave one per clk_sys cycle, so occupancy
            // never exceeds 1, and a shallower array halves the read mux
            // feeding the clk_sys capture register.
            async_fifo #(.WIDTH(17), .AW(3)) cdc (
                .wr_clk  (clk_cap),
                .wr_rst  (cap_rst),
                .wr_en   (cap_src_wr || cap_src_frame_sync),
                .wr_data ({cap_src_frame_sync, cap_src_pixel}),
                .wr_full (cdc_full),

                .rd_clk  (clk_sys),
                .rd_rst  (rst),
                .rd_en   (1'b1),
                .rd_data (cdc_rd_data),
                .rd_empty(cdc_empty)
            );

            // Draining one entry per clk_sys cycle is 40 M/s against an input
            // of 6 M/s, so the FIFO sits at 0 or 1 and overflow is only
            // reachable if clk_sys stops.  It is still reported, because a
            // silent pixel loss here would look exactly like a camera fault.
            reg [15:0] cap_pixel_q      = 16'h0000;
            reg        cap_wr_q         = 1'b0;
            reg        cap_frame_sync_q = 1'b0;
            reg        cdc_overflow_q   = 1'b0;

            always @(posedge clk_sys) begin
                if (rst) begin
                    cap_wr_q         <= 1'b0;
                    cap_frame_sync_q <= 1'b0;
                end else begin
                    cap_wr_q         <= 1'b0;
                    cap_frame_sync_q <= 1'b0;

                    if (!cdc_empty) begin
                        if (cdc_rd_data[16]) begin
                            cap_frame_sync_q <= 1'b1;
                        end else begin
                            cap_pixel_q <= cdc_rd_data[15:0];
                            cap_wr_q    <= 1'b1;
                        end
                    end
                end
            end

            // cdc_full belongs to clk_cap; it is only ever read as a sticky
            // "something went wrong" flag, so a two-flop sync is fine.
            (* ASYNC_REG = "TRUE" *) reg [1:0] cdc_full_sync;
            always @(posedge clk_sys) begin
                if (rst) begin
                    cdc_full_sync  <= 2'b00;
                    cdc_overflow_q <= 1'b0;
                end else begin
                    cdc_full_sync <= {cdc_full_sync[0], cdc_full};
                    if (cdc_full_sync[1])
                        cdc_overflow_q <= 1'b1;
                end
            end

            assign cap_pixel      = cap_pixel_q;
            assign cap_wr         = cap_wr_q;
            assign cap_frame_sync = cap_frame_sync_q;
            assign cdc_overflow   = cdc_overflow_q;
        end
    endgenerate

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

    // ---------------- rate-matching / surplus FIFO ----------------
    wire        fifo_full;
    wire        fifo_empty;
    wire [15:0] fifo_rd_data;
    wire        fifo_rd_valid;
    wire        fifo_rd_en;
    wire        fifo_overflow;
    wire        fifo_underflow;
    wire [FIFO_AW:0] fifo_level;

    pixel_fifo #(
        .DEPTH (FIFO_DEPTH),
        .AW    (FIFO_AW)
    ) fifo (
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
    wire tft_sclk_d0, tft_sclk_d1, tft_mosi_bit, tft_dc_bit, tft_cs_n;
    wire tft_resn;

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
        .tft_cs_n      (tft_cs_n),
        .tft_dc_bit    (tft_dc_bit),
        .tft_resn      (tft_resn),
        .tft_bl        (bl_raw),
        .init_done     (lcd_init_done),
        .frame_done    (lcd_frame_done),
        .sync_error    (lcd_sync_error),
        .starve_error  (lcd_starve_error),
        .stream_active (lcd_stream_active)
    );

    // ---------------- SPI pad cells (see file header) ----------------
    // One-cycle-delayed copies of the four SPI-domain signals.  Combined with
    // the ODDR half-cycle split below these reproduce the iCE40 SB_IO phase
    // relationship on top of Gowin's deeper ODDR pipeline.
    reg sclk_d0_q = 1'b0;
    reg mosi_q    = 1'b0;
    reg dc_q      = 1'b1;
    reg cs_n_q    = 1'b1;

    always @(posedge clk_sys) begin
        sclk_d0_q <= tft_sclk_d0;
        mosi_q    <= tft_mosi_bit;
        dc_q      <= tft_dc_bit;
        cs_n_q    <= tft_cs_n;
    end

    // SCLK: D1 is the engine's constant 0, so each active cycle produces one
    // discrete high-then-low pulse rather than a stretched pulse across a
    // multi-bit burst.
    ODDR tft_sclk_io (
        .Q0  (tft_scl),
        .Q1  (),
        .D0  (sclk_d0_q),
        .D1  (tft_sclk_d1),
        .TX  (1'b0),
        .CLK (clk_sys)
    );

    // MOSI/DC: delayed bit on the high phase, current bit on the low phase,
    // so the pad transitions mid-cycle -- half a cycle before the SCLK rising
    // edge that samples it.
    ODDR tft_mosi_io (
        .Q0  (tft_sda),
        .Q1  (),
        .D0  (mosi_q),
        .D1  (tft_mosi_bit),
        .TX  (1'b0),
        .CLK (clk_sys)
    );

    ODDR tft_dc_io (
        .Q0  (tft_dc),
        .Q1  (),
        .D0  (dc_q),
        .D1  (tft_dc_bit),
        .TX  (1'b0),
        .CLK (clk_sys)
    );

    // CS: same cell and same latency as the data pads, purely so the final
    // SCLK pulse of a burst still happens while CS is low.  Sharing the
    // mid-cycle transition also keeps CS from ever moving on an SCLK edge.
    ODDR tft_cs_io (
        .Q0  (tft_cs),
        .Q1  (),
        .D0  (cs_n_q),
        .D1  (tft_cs_n),
        .TX  (1'b0),
        .CLK (clk_sys)
    );

    // Reset and backlight move on millisecond timescales; no pad retiming.
    assign tft_res = tft_resn;
    assign tft_blk = BL_ACTIVE_HIGH ? bl_raw : ~bl_raw;

    // ---------------- status LEDs ----------------
    // Two LEDs cannot localise a fault by being on or off, so they carry
    // patterns instead: READY (E8) toggles once per completed frame, so a
    // frozen picture is immediately distinguishable from a stalled pipeline,
    // and DONE (D7) blinks the index of the first sticky fault -- off means no
    // fault has latched at all.  See status_led.v.
    wire [4:0] faults = {dropped_frame_error,              // 5 blinks
                         lcd_sync_error,                   // 4
                         lcd_starve_error,                 // 3
                         fifo_underflow,                   // 2
                         fifo_overflow || cdc_overflow};   // 1

    wire led_ready_raw;
    wire led_fault_raw;

    status_led #(.CLK_HZ(SYS_CLK_HZ)) status (
        .clk        (clk_sys),
        .rst        (rst),
        .ready      (stream_enable),
        .frame_done (lcd_frame_done),
        .faults     (faults),
        .led_ready  (led_ready_raw),
        .led_fault  (led_fault_raw)
    );

    assign led_ready = LED_ACTIVE_HIGH ? led_ready_raw : ~led_ready_raw;
    assign led_done  = LED_ACTIVE_HIGH ? led_fault_raw : ~led_fault_raw;

    // Explicitly consume status nets that are useful for probing but not pins.
    wire _unused_ok = &{1'b0, fifo_full, fifo_level[FIFO_AW],
                        lcd_stream_active, encryption_active, cam_siod_in,
                        s2_level};
endmodule
`default_nettype wire
