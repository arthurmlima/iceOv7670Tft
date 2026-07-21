// Minimal behavioural stubs so top.v can be dropped into iverilog if wanted.
// (The smoke test instantiates the design modules directly and does not
//  need these, but they are here for convenience.)

module SB_PLL40_PAD #(
    parameter FEEDBACK_PATH = "SIMPLE",
    parameter DIVR = 4'b0000,
    parameter DIVF = 7'b0000000,
    parameter DIVQ = 3'b000,
    parameter FILTER_RANGE = 3'b000
)(
    input  wire PACKAGEPIN,
    output wire PLLOUTGLOBAL,
    output wire PLLOUTCORE,
    input  wire RESETB,
    input  wire BYPASS,
    output reg  LOCK
);
    // Not a frequency model: just pass the pin through and assert LOCK.
    assign PLLOUTGLOBAL = PACKAGEPIN;
    assign PLLOUTCORE   = PACKAGEPIN;
    initial LOCK = 1'b1;
endmodule

module SB_IO #(
    parameter PIN_TYPE = 6'b000000,
    parameter PULLUP   = 1'b0
)(
    inout  wire PACKAGE_PIN,
    input  wire OUTPUT_ENABLE,
    input  wire D_OUT_0,
    output wire D_IN_0
);
    assign PACKAGE_PIN = OUTPUT_ENABLE ? D_OUT_0 : 1'bz;
    assign D_IN_0 = PACKAGE_PIN;
endmodule
