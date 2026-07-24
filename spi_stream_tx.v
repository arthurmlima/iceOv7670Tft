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
// SCLK is generated through an SB_IO DDR output cell (instantiated in the
// top module) fed with sclk_d0 = "sending a bit this cycle" and sclk_d1 tied
// to 0, giving a discrete high-then-low pulse each active cycle instead of
// one long pulse across a multi-bit burst.
//
// MOSI/DC are driven through SB_IO cells with NEG_TRIGGER=1 (registered on
// clk_sys's falling edge). Because mosi_bit/dc_bit are plain clk_sys-domain
// signals, the NEG_TRIGGER cell re-times them to be stable from the middle
// of the previous cycle onward -- a half clk_sys-cycle of setup margin
// before the SCLK rising edge that samples them, mirroring how the older
// 2-cycle/bit engine changed data on SCLK's falling edge a full cycle early.
// This relationship (and the lack of merged/missing SCLK pulses) was
// verified in simulation against the real SB_IO behavioral model, not just
// derived on paper -- getting the DDR phase relationship wrong here would
// silently corrupt every byte.
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

    output wire        sclk_d0,   // -> SB_IO DDR D_OUT_0 (rising-edge phase)
    output wire        sclk_d1,   // -> SB_IO DDR D_OUT_1 (tie low at instantiation)
    output wire        mosi_bit,  // -> SB_IO NEG_TRIGGER OUTPUT_REGISTERED D_OUT_0
    output wire        dc_bit,    // -> SB_IO NEG_TRIGGER OUTPUT_REGISTERED D_OUT_0
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
