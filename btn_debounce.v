`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// btn_debounce.v
//
// Two-flop synchronizer plus an integrate-and-commit debouncer for one
// active-high pushbutton.  A new level is adopted only after it has held
// steady for STABLE_CYCLES; any bounce back to the current level restarts the
// count, so a single press produces exactly one rise_o pulse.
//
// The iCEBreaker build avoided needing this by using two separate buttons for
// "encrypt" and "bypass" -- each press repeated an idempotent assignment, so
// bounce was harmless.  The Tang Primer 25K only has two buttons and one of
// them is the reset, so the encryption control became a toggle and a bouncing
// edge would flip it several times per press.
// ============================================================================
module btn_debounce #(
    parameter integer STABLE_CYCLES = 400000   // ~10 ms at 40 MHz
)(
    input  wire clk,
    input  wire rst,
    input  wire btn_i,

    output reg  level_o = 1'b0,   // debounced button level
    output reg  rise_o  = 1'b0    // one-cycle pulse on each debounced press
);
    localparam integer CW = (STABLE_CYCLES <= 2) ? 1 : $clog2(STABLE_CYCLES);

    (* ASYNC_REG = "TRUE" *) reg [1:0] sync = 2'b00;
    reg [CW-1:0] count = {CW{1'b0}};

    always @(posedge clk) begin
        rise_o <= 1'b0;

        if (rst) begin
            sync    <= 2'b00;
            count   <= {CW{1'b0}};
            level_o <= 1'b0;
        end else begin
            sync <= {sync[0], btn_i};

            if (sync[1] == level_o) begin
                count <= {CW{1'b0}};
            end else if (count >= STABLE_CYCLES-1) begin
                count   <= {CW{1'b0}};
                level_o <= sync[1];
                rise_o  <= sync[1];
            end else begin
                count <= count + 1'b1;
            end
        end
    end
endmodule
`default_nettype wire
