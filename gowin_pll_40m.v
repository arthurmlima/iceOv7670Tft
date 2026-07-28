`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gowin_pll_40m.v
//
// 50.000 MHz (Tang Primer 25K dock oscillator) -> 40.000 MHz clk_sys.
//
// GW5A's PLL primitive is PLLA (the GW1N/GW2A "rPLL" does not exist on this
// family).  With CLKFB_SEL="INTERNAL" the frequencies are
//
//     f_pfd  = FCLKIN * FBDIV_SEL / IDIV_SEL      = 50.0 MHz
//     f_vco  = f_pfd  * MDIV_SEL                  = 1200.0 MHz
//     f_out0 = f_vco  / ODIV0_SEL                 =   40.0 MHz
//
// 1200 MHz sits inside the GW5A VCO range (Sipeed's own Tang Primer 25K
// examples run this PLL at 1500 MHz), and a 50 MHz phase-detector frequency
// is the highest available here, which keeps jitter low.
//
// To retune: pick MDIV_SEL/ODIV0_SEL so that 50*MDIV/ODIV0 is the wanted
// frequency and 50*MDIV stays in the VCO range.  The fitter validates both
// and errors out rather than silently mis-locking.
// ============================================================================
module gowin_pll_40m (
    input  wire clkin,
    output wire clkout0,
    output wire lock
);
    wire        gnd = 1'b0;
    wire        clkout1_nc, clkout2_nc, clkout3_nc;
    wire        clkout4_nc, clkout5_nc, clkout6_nc;
    wire        clkfbout_nc;
    wire [7:0]  mdrdo_nc;

    PLLA #(
        .FCLKIN     ("50"),
        .IDIV_SEL   (1),
        .FBDIV_SEL  (1),
        .MDIV_SEL   (24),      // VCO = 50 MHz * 24 = 1200 MHz
        .ODIV0_SEL  (30),      // CLKOUT0 = 1200 MHz / 30 = 40 MHz
        .CLKFB_SEL  ("INTERNAL"),
        .CLKOUT0_EN ("TRUE"),
        .CLKOUT1_EN ("FALSE"),
        .CLKOUT2_EN ("FALSE"),
        .CLKOUT3_EN ("FALSE"),
        .CLKOUT4_EN ("FALSE"),
        .CLKOUT5_EN ("FALSE"),
        .CLKOUT6_EN ("FALSE")
    ) pll (
        .LOCK          (lock),
        .CLKOUT0       (clkout0),
        .CLKOUT1       (clkout1_nc),
        .CLKOUT2       (clkout2_nc),
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
