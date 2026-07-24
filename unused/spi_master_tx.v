`timescale 1ns / 1ps
//======================================================================
//  spi_master_tx.v
//
//  Minimal transmit-only SPI master, 8 bits, MSB first, SPI mode 0
//  (CPOL = 0, CPHA = 0) - exactly what XSpiPs gives you with only
//  XSPIPS_MASTER_OPTION | XSPIPS_FORCE_SSELECT_OPTION set.
//
//      SCLK idles low.
//      MOSI changes on the falling edge.
//      The ST7789 samples MOSI on the rising edge.
//
//  There is no MISO path: the panel is write-only in this design.
//  Chip select is owned by the caller (the ST7789 FSM), because CS has
//  to stay low across a whole command+parameter burst.
//======================================================================
module spi_master_tx #(
    parameter integer HALF_DIV = 5          // sysclk cycles per half SCLK period
)(
    input  wire       clk,
    input  wire       resetn,

    input  wire       start,                // 1-cycle pulse, ignored while busy
    input  wire [7:0] tx_byte,

    output reg        sclk,
    output reg        mosi,
    output reg        busy,
    output reg        done                  // 1-cycle pulse, last bit clocked out
);
    localparam integer HD  = (HALF_DIV < 1) ? 1 : HALF_DIV;
    localparam integer DW  = (HD < 2) ? 1 : $clog2(HD);

    localparam [1:0] S_IDLE = 2'd0,
                     S_LOW  = 2'd1,         // SCLK low, data settled
                     S_HIGH = 2'd2;         // SCLK high, slave samples here

    reg [1:0]    state;
    reg [7:0]    shreg;
    reg [2:0]    bitcnt;
    reg [DW-1:0] div;

    always @(posedge clk) begin
        if (!resetn) begin
            state  <= S_IDLE;
            sclk   <= 1'b0;
            mosi   <= 1'b0;
            busy   <= 1'b0;
            done   <= 1'b0;
            shreg  <= 8'h00;
            bitcnt <= 3'd0;
            div    <= {DW{1'b0}};
        end else begin
            done <= 1'b0;

            case (state)
            //--------------------------------------------------------------
            S_IDLE: begin
                sclk <= 1'b0;
                if (start) begin
                    shreg  <= tx_byte;
                    mosi   <= tx_byte[7];       // MSB first
                    bitcnt <= 3'd7;
                    div    <= HD - 1;
                    busy   <= 1'b1;
                    state  <= S_LOW;
                end
            end
            //--------------------------------------------------------------
            S_LOW: begin                        // setup time before rising edge
                if (div == 0) begin
                    sclk  <= 1'b1;
                    div   <= HD - 1;
                    state <= S_HIGH;
                end else begin
                    div <= div - 1'b1;
                end
            end
            //--------------------------------------------------------------
            S_HIGH: begin
                if (div == 0) begin
                    sclk <= 1'b0;               // falling edge: shift new bit out
                    div  <= HD - 1;
                    if (bitcnt == 3'd0) begin
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        bitcnt <= bitcnt - 1'b1;
                        mosi   <= shreg[6];
                        shreg  <= {shreg[6:0], 1'b0};
                        state  <= S_LOW;
                    end
                end else begin
                    div <= div - 1'b1;
                end
            end
            //--------------------------------------------------------------
            default: state <= S_IDLE;
            endcase
        end
    end
endmodule
