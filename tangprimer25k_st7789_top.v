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
// the iCE40 build's 39.000 MHz, which keeps the panel at a rate already
// exercised on hardware: ST7789 SCLK at 40 MHz.
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
// f_int is now 20 MHz -- 25.01 fps -- reached by driving XCLK at the full
// clk_sys 40 MHz and letting the sensor apply the /2 it applies regardless of
// what CLKRC asks for (measured; see the clock note in cam_init.v).  The
// camera then outruns the panel during active video, and the surplus -- the
// integral of the rate difference over the active region, up to 20160 pixels
// -- has to be buffered.  Hence FIFO_DEPTH below.  See timing_check.py for
// the arithmetic, and CAM_XCLK_DIV/CAM_CLKRC below for the other way to land
// on the same f_int if a sensor that honours its prescaler is fitted.
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
    // Camera clock pair.  These two are one setting in two halves and must be
    // changed together, against the measured divide chain in cam_init.v:
    //
    //   f_int = clk_sys / (CAM_XCLK_DIV * 2 * (CAM_CLKRC[5:0]+1))
    //                                    ^ this sensor's undocumented fixed /2
    //
    // has to come out at 20.000 MHz for the 25 fps this design is sized for,
    // which pins XCLK to the full 40 MHz with the prescaler asked for /1.
    // Do not change one without the other: raising XCLK and adding prescale
    // cancel exactly, which is how the first attempt at 25 fps stayed at 12.5.
    parameter integer CAM_XCLK_DIV       = 1,
    parameter [7:0]   CAM_CLKRC          = 8'h00,
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
    // ---------------- clock ratios ----------------
    // clk_sys periods per camera internal clock: the XCLK divider in the
    // fabric, times the fixed /2 this sensor applies whatever CLKRC says,
    // times CLKRC's own prescale.  1 * 2 * 1 = 2, i.e. f_int = 20 MHz and
    // PCLK (COM14 = /2) = clk_sys/4 = 10 MHz -- the floor for cam_capture's
    // 2-flop sampling.  Several things below are derived from this number.
    localparam integer CAM_FIXED_DIV = 2;   // measured, see cam_init.v
    localparam integer CAM_PRESCALE  = CAM_CLKRC[5:0] + 1;
    localparam integer CAM_INT_DIV   = CAM_XCLK_DIV * CAM_FIXED_DIV * CAM_PRESCALE;

    // Worst case the sensor emits its 240 output lines back to back, giving
    // the panel 240*1568/f_int = 18.8 ms to drain 67200 pixels at SPI/16.
    // It manages 47040, so 20160 have to wait.  32768 rounds that up to a
    // power of two with 60% headroom and costs 512 Kb of the 1008 Kb of BSRAM.
    localparam integer FIFO_DEPTH = 32768;
    localparam integer FIFO_AW    = $clog2(FIFO_DEPTH);

    // ---------------- system clock ----------------
    wire clk_sys;
    wire pll_lock;

    generate
        if (USE_PLL != 0) begin : g_pll
            // 50 MHz -> 40 MHz.  With USE_PLL=0 clk_sys is the raw 50 MHz
            // oscillator, in which case SYS_CLK_HZ/SPI_HZ must be overridden
            // to 50000000 so the millisecond and SCCB dividers stay correct.
            gowin_pll_40m pll (
                .clkin   (clk50),
                .clkout0 (clk_sys),
                .lock    (pll_lock)
            );
        end else begin : g_bypass
            assign clk_sys  = clk50;
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
    // CAM_XCLK_DIV=1 needs clk_sys itself on the pad, which a fabric flop
    // cannot produce -- it would have to toggle every half cycle.  ODDR does
    // it directly: Q0 drives D0 while CLK is high and D1 while CLK is low, so
    // D0=1/D1=0 emits a 50% duty copy of clk_sys.  Same cell the SPI pads use
    // (see file header); the extra ODDR pipeline latency is irrelevant for a
    // free-running clock.  The sensor is specified for 10-48 MHz XCLK, so
    // both 20 and 40 MHz are in range.
    generate
        if (CAM_XCLK_DIV == 1) begin : g_xclk_full
            ODDR cam_xclk_io (
                .Q0  (cam_xclk),        // 40.000 MHz
                .Q1  (),
                .D0  (1'b1),
                .D1  (1'b0),
                .TX  (1'b0),
                .CLK (clk_sys)
            );
        end else begin : g_xclk_div2
            reg cam_xclk_q = 1'b0;
            always @(posedge clk_sys) begin
                if (rst)
                    cam_xclk_q <= 1'b0;
                else
                    cam_xclk_q <= ~cam_xclk_q;
            end
            assign cam_xclk = cam_xclk_q;   // 20.000 MHz
        end
    endgenerate

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
        .RST_TICKS  (4000),
        .CLKRC_VAL  (CAM_CLKRC)
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
    wire [15:0] cap_pixel;
    wire        cap_wr;
    wire        cap_frame_sync;

    generate
        if (PATTERN_SOURCE != 0) begin : g_pattern
            test_pattern_src #(
                .WIDTH       (280),
                .HEIGHT      (240),
                .PIX_CYCLES  (4*CAM_INT_DIV),      // 4 internal clocks/pixel
                .LINE_CYCLES (1568*CAM_INT_DIV),
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
    wire [4:0] faults = {dropped_frame_error,   // 5 blinks
                         lcd_sync_error,        // 4
                         lcd_starve_error,      // 3
                         fifo_underflow,        // 2
                         fifo_overflow};        // 1

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
