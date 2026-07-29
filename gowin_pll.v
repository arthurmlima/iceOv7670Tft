`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gowin_pll.v
//
// 50.000 MHz (Tang Primer 25K dock oscillator) ->
//     CLKOUT0  40.000 MHz  clk_sys : fabric and ST7789 SPI bit rate
//     CLKOUT1  48.000 MHz  cam_xclk: OV7670 master clock
//     CLKOUT2 100.000 MHz  clk_cap : oversamples the camera's 12 MHz PCLK
//
// The second output exists because the two clocks are not related by any
// useful small integer ratio.  Frame rate is fps = f_int / 799680, so 30 fps
// needs f_int = 24 MHz, and this sensor runs f_int at XCLK/2 whatever CLKRC
// asks for (measured -- see the clock note in cam_init.v).  Hence XCLK = 48
// MHz, which is also the OV7670's rated maximum: 30 fps is the ceiling for
// this part, with no headroom left in XCLK.  Dividing clk_sys instead would
// only offer 40 MHz (25 fps) or 20 MHz (12.5 fps), and raising clk_sys until
// a divide landed on 48 MHz would drag the panel's SPI clock up with it.
//
// GW5A's PLL primitive is PLLA (the GW1N/GW2A "rPLL" does not exist on this
// family).  With CLKFB_SEL="INTERNAL" the frequencies are
//
//     f_pfd  = FCLKIN * FBDIV_SEL / IDIV_SEL      =   50.0 MHz
//     f_vco  = f_pfd  * MDIV_SEL                  = 1200.0 MHz
//     f_outN = f_vco  / ODIVn_SEL
//
// 1200 MHz sits inside the GW5A VCO range (Sipeed's own Tang Primer 25K
// examples run this PLL at 1500 MHz), and a 50 MHz phase-detector frequency is
// the highest available here, which keeps jitter low.
//
// To retune: pick MDIV_SEL and the ODIVn so that 50*MDIV/ODIVn are the wanted
// frequencies with 50*MDIV inside the VCO range.  The fitter validates both
// and errors out rather than silently mis-locking.
// ============================================================================
module gowin_pll (
    input  wire clkin,
    output wire clkout0,     // 40 MHz
    output wire clkout1,     // 48 MHz
    output wire clkout2,     // 100 MHz
    output wire lock
);
    wire        gnd = 1'b0;
    wire        clkout3_nc;
    wire        clkout4_nc, clkout5_nc, clkout6_nc;
    wire        clkfbout_nc;
    wire [7:0]  mdrdo_nc;

    PLLA #(
        .FCLKIN     ("50"),
        .IDIV_SEL   (1),
        .FBDIV_SEL  (1),
        .MDIV_SEL   (24),      // VCO = 50 MHz * 24 = 1200 MHz
        .ODIV0_SEL  (30),      // CLKOUT0 = 1200 / 30 = 40 MHz
        .ODIV1_SEL  (25),      // CLKOUT1 = 1200 / 25 = 48 MHz
        .ODIV2_SEL  (12),      // CLKOUT2 = 1200 / 12 = 100 MHz
        .CLKFB_SEL  ("INTERNAL"),
        .CLKOUT0_EN ("TRUE"),
        .CLKOUT1_EN ("TRUE"),
        .CLKOUT2_EN ("TRUE"),
        .CLKOUT3_EN ("FALSE"),
        .CLKOUT4_EN ("FALSE"),
        .CLKOUT5_EN ("FALSE"),
        .CLKOUT6_EN ("FALSE")
    ) pll (
        .LOCK          (lock),
        .CLKOUT0       (clkout0),
        .CLKOUT1       (clkout1),
        .CLKOUT2       (clkout2),
        .CLKOUT3       (clkout3_nc),
        .CLKOUT4       (clkout4_nc),
        .CLKOUT5       (clkout5_nc),
        .CLKOUT6       (clkout6_nc),
        .CLKFBOUT      (clkfbout_nc),
        .MDRDO         (mdrdo_nc),
        .CLKIN         (clkin),
        .CLKFB         (gnd),
        .RESET         (gnd),
        .PLLPWD        (gnd),
        .RESET_I       (gnd),
        .RESET_O       (gnd),
        .PSSEL         (3'b000),
        .PSDIR         (gnd),
        .PSPULSE       (gnd),
        .SSCPOL        (gnd),
        .SSCON         (gnd),
        .SSCMDSEL      (7'b0000000),
        .SSCMDSEL_FRAC (3'b000),
        .MDCLK         (gnd),
        .MDOPC         (2'b00),
        .MDAINC        (gnd),
        .MDWDI         (8'h00)
    );
endmodule
`default_nettype wire
