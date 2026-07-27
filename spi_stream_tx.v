`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// spi_stream_tx.v
//
// Gapless transmit-only SPI mode-0 byte engine, one bit per clk_sys cycle
// (SCLK = clk_sys). The source presents tx_valid/tx_data/tx_dc; tx_accept
// pulses whenever a byte is taken; tx_ready is asserted on the final bit of
// the current byte so the next byte starts without an extra idle cycle.
//
// This module is device-independent: it emits the four raw signals a DDR
// output cell needs and leaves the cells themselves to the top level, which
// is the only file that differs between the Gowin and iCE40 builds.
//
// The contract the top level must honour:
//
//   sclk_d0/sclk_d1  drive a DDR output cell.  sclk_d0 = "sending a bit this
//                    cycle" appears while the clock is high and sclk_d1 (tied
//                    to 0) while it is low, so every active cycle produces a
//                    discrete high-then-low pulse instead of one long pulse
//                    across a multi-bit burst.
//   mosi_bit/dc_bit  must reach the pad half a clk cycle *before* the SCLK
//                    rising edge that samples them, and hold half a cycle
//                    after -- the same margin the older 2-cycle/bit engine
//                    got by changing data on SCLK's falling edge.
//   the chip select  must reach the pad with the same latency as sclk_d0, or
//                    the FSM's "deassert CS two cycles after the last bit"
//                    will truncate the final byte.
//
// Both builds verify this at the pads in simulation against the vendor's own
// behavioural cell models -- tb_spi_gowin_io.v here against ODDR, and the
// iCE40 build against SB_IO in cells_sim.v.  Getting the DDR phase wrong
// silently corrupts every byte, so it is not derived on paper alone.
// ============================================================================
module spi_stream_tx (
    input  wire       clk,
    input  wire       resetn,

    input  wire       tx_valid,
    input  wire [7:0] tx_data,
    input  wire       tx_dc,
    output wire       tx_ready,
    output reg        tx_accept,
    output reg        tx_done,

    output wire        sclk_d0,   // -> DDR cell, clock-high phase
    output wire        sclk_d1,   // -> DDR cell, clock-low phase (always 0)
    output wire        mosi_bit,  // -> half-cycle-early registered pad
    output wire        dc_bit,    // -> half-cycle-early registered pad
    output wire        busy
);
    reg        active;      // 1 while a bit is being clocked out this cycle
    reg [7:0]  shreg;
    reg [2:0]  bitcnt;
    reg        dc_hold;

    // Ready on the final bit of the current byte so the source can hand
    // over the next byte with no gap, same external contract as before.
    assign tx_ready = (!active) || (bitcnt == 3'd0);
    assign sclk_d0  = active;
    assign sclk_d1  = 1'b0;
    assign mosi_bit = shreg[7];
    assign dc_bit   = dc_hold;
    assign busy     = active;

    always @(posedge clk) begin
        if (!resetn) begin
            active    <= 1'b0;
            shreg     <= 8'h00;
            bitcnt    <= 3'd0;
            dc_hold   <= 1'b1;
            tx_accept <= 1'b0;
            tx_done   <= 1'b0;
        end else begin
            tx_accept <= 1'b0;
            tx_done   <= 1'b0;

            if (!active) begin
                if (tx_valid) begin
                    shreg     <= tx_data;
                    bitcnt    <= 3'd7;
                    dc_hold   <= tx_dc;
                    active    <= 1'b1;
                    tx_accept <= 1'b1;
                end
            end else if (bitcnt == 3'd0) begin
                tx_done <= 1'b1;
                if (tx_valid) begin
                    // Immediate next byte: no extra idle cycle.
                    shreg     <= tx_data;
                    bitcnt    <= 3'd7;
                    dc_hold   <= tx_dc;
                    tx_accept <= 1'b1;
                end else begin
                    active <= 1'b0;
                end
            end else begin
                shreg  <= {shreg[6:0], 1'b0};
                bitcnt <= bitcnt - 1'b1;
            end
        end
    end
endmodule
`default_nettype wire
