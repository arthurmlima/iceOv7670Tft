`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// spi_stream_tx.v
//
// Gapless transmit-only SPI mode-0 byte engine.
//
// The source presents tx_valid/tx_data/tx_dc.  tx_accept pulses whenever a
// byte is taken.  During a continuous stream, tx_ready is asserted on the
// final falling edge of the current byte, so the next byte starts without an
// extra idle SCLK period.  DC is latched with each byte and therefore changes
// only at byte boundaries.
//
// SCLK = CLK_HZ / (2 * HALF_DIV).  With CLK_HZ=39.00 MHz and HALF_DIV=2,
// SCLK is exactly 9.750 MHz.
// ============================================================================
module spi_stream_tx #(
    parameter integer HALF_DIV = 2
)(
    input  wire       clk,
    input  wire       resetn,

    input  wire       tx_valid,
    input  wire [7:0] tx_data,
    input  wire       tx_dc,
    output wire       tx_ready,
    output reg        tx_accept,
    output reg        tx_done,

    output reg        sclk,
    output reg        mosi,
    output reg        dc,
    output reg        busy
);
    localparam integer HD = (HALF_DIV < 1) ? 1 : HALF_DIV;
    localparam integer DW = (HD < 2) ? 1 : $clog2(HD);

    localparam [1:0] S_IDLE = 2'd0,
                     S_LOW  = 2'd1,
                     S_HIGH = 2'd2;

    reg [1:0] state;
    reg [7:0] shreg;
    reg [2:0] bitcnt;
    reg [DW-1:0] div;

    // The source may hand over a replacement byte on the final falling edge.
    assign tx_ready = (state == S_IDLE) ||
                      ((state == S_HIGH) && (div == {DW{1'b0}}) &&
                       (bitcnt == 3'd0));

    always @(posedge clk) begin
        if (!resetn) begin
            state     <= S_IDLE;
            shreg     <= 8'h00;
            bitcnt    <= 3'd0;
            div       <= {DW{1'b0}};
            sclk      <= 1'b0;
            mosi      <= 1'b0;
            dc        <= 1'b1;
            busy      <= 1'b0;
            tx_accept <= 1'b0;
            tx_done   <= 1'b0;
        end else begin
            tx_accept <= 1'b0;
            tx_done   <= 1'b0;

            case (state)
            S_IDLE: begin
                sclk <= 1'b0;
                busy <= 1'b0;
                if (tx_valid) begin
                    shreg     <= tx_data;
                    bitcnt    <= 3'd7;
                    div       <= HD - 1;
                    mosi      <= tx_data[7];
                    dc        <= tx_dc;
                    busy      <= 1'b1;
                    tx_accept <= 1'b1;
                    state     <= S_LOW;
                end
            end

            S_LOW: begin
                if (div == {DW{1'b0}}) begin
                    sclk  <= 1'b1;       // slave samples on rising edge
                    div   <= HD - 1;
                    state <= S_HIGH;
                end else begin
                    div <= div - 1'b1;
                end
            end

            S_HIGH: begin
                if (div == {DW{1'b0}}) begin
                    sclk <= 1'b0;        // change data on falling edge
                    div  <= HD - 1;

                    if (bitcnt == 3'd0) begin
                        tx_done <= 1'b1;
                        if (tx_valid) begin
                            // Immediate next byte: no extra SCLK-low gap.
                            shreg     <= tx_data;
                            bitcnt    <= 3'd7;
                            mosi      <= tx_data[7];
                            dc        <= tx_dc;
                            busy      <= 1'b1;
                            tx_accept <= 1'b1;
                            state     <= S_LOW;
                        end else begin
                            busy  <= 1'b0;
                            mosi  <= 1'b0;
                            state <= S_IDLE;
                        end
                    end else begin
                        bitcnt <= bitcnt - 1'b1;
                        shreg  <= {shreg[6:0], 1'b0};
                        mosi   <= shreg[6];
                        state  <= S_LOW;
                    end
                end else begin
                    div <= div - 1'b1;
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
