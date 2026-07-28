`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// tangprimer25k_pattern_top.v
//
// Diagnostic build: identical to tangprimer25k_st7789_top except the camera is
// replaced by test_pattern_src, which reproduces the OV7670's pixel, line and
// frame timing exactly but emits a known moving gradient.  Build it with
// `make pattern`, which only changes the top module -- same project, same
// constraints, same pins.
//
// It exists as a separate top rather than a parameter override because gw_sh
// has no -verilog_define / parameter-override option; selecting the top module
// is the one mechanism that is guaranteed to work headlessly.
//
// What it tells you:
//   * clean moving gradient  -> the panel, SPI pads, FIFO, frame gate and
//                               panel FSM are all fine; the fault is the
//                               camera, its SCCB configuration, or cam_capture
//   * same garbage as before -> the fault is downstream of the pixel source
//
// The camera pins are left unconnected here, so this build also runs with no
// camera plugged in at all (cam_init writes its table blind -- SCCB is
// write-only and never checks for an ACK -- so stream_enable still asserts).
// ============================================================================
module tangprimer25k_pattern_top (
    input  wire       clk50,
    input  wire       btn_s1,
    input  wire       btn_s2,
    output wire       led_ready,
    output wire       led_done,

    output wire       tft_scl,
    output wire       tft_sda,
    output wire       tft_res,
    output wire       tft_dc,
    output wire       tft_cs,
    output wire       tft_blk,

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
    tangprimer25k_st7789_top #(
        .PATTERN_SOURCE (1)
    ) core (
        .clk50     (clk50),
        .btn_s1    (btn_s1),
        .btn_s2    (btn_s2),
        .led_ready (led_ready),
        .led_done  (led_done),

        .tft_scl   (tft_scl),
        .tft_sda   (tft_sda),
        .tft_res   (tft_res),
        .tft_dc    (tft_dc),
        .tft_cs    (tft_cs),
        .tft_blk   (tft_blk),

        .cam_xclk  (cam_xclk),
        .cam_pclk  (cam_pclk),
        .cam_href  (cam_href),
        .cam_vsync (cam_vsync),
        .cam_sioc  (cam_sioc),
        .cam_siod  (cam_siod),
        .cam_rst_n (cam_rst_n),
        .cam_pwdn  (cam_pwdn),
        .cam_d     (cam_d)
    );
endmodule
`default_nettype wire
