`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// pixel_fifo.v
//
// Single-clock 256 x 16 RGB565 FIFO.  The storage is exactly 4096 bits and is
// written in an inference-friendly synchronous style so it maps to one block
// RAM: an iCE40UP5K EBR under yosys, one GW5A BSRAM under GowinSynthesis.
// Both vendors' block-RAM hints are attached; each tool ignores the other's.
//
// "flush" is asserted at each accepted camera frame boundary.  Overflow and
// underflow are sticky until reset so they can be shown on an LED.
// ============================================================================
// DEPTH need not be a power of two: the pointers wrap explicitly rather than
// relying on natural rollover, so the buffer can be sized to the actual
// surplus instead of the next power of two above it.  On this device that
// matters -- 65536 pixels would not fit in BSRAM at all.
module pixel_fifo #(
    parameter integer DEPTH = 256,
    parameter integer AW    = 8
)(
    input  wire          clk,
    input  wire          rst,
    input  wire          flush,

    input  wire          wr_en,
    input  wire [15:0]   wr_data,
    output wire          full,

    input  wire          rd_en,
    output reg  [15:0]   rd_data,
    output reg           rd_valid,
    output wire          empty,

    output reg           overflow,
    output reg           underflow,
    output reg  [AW:0]   level
);
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    reg [15:0] mem [0:DEPTH-1];
    reg [AW-1:0] wr_ptr;
    reg [AW-1:0] rd_ptr;

    wire do_wr = wr_en && !full;
    wire do_rd = rd_en && !empty;

    assign empty = (level == {(AW+1){1'b0}});
    assign full  = (level == DEPTH);

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr    <= {AW{1'b0}};
            rd_ptr    <= {AW{1'b0}};
            rd_data   <= 16'h0000;
            rd_valid  <= 1'b0;
            level     <= {(AW+1){1'b0}};
            overflow  <= 1'b0;
            underflow <= 1'b0;
        end else begin
            rd_valid <= 1'b0;

            if (flush) begin
                wr_ptr   <= {AW{1'b0}};
                rd_ptr   <= {AW{1'b0}};
                level    <= {(AW+1){1'b0}};
                rd_valid <= 1'b0;
            end else begin
                if (do_wr) begin
                    mem[wr_ptr] <= wr_data;
                    wr_ptr      <= (wr_ptr == DEPTH-1) ? {AW{1'b0}}
                                                       : wr_ptr + 1'b1;
                end

                if (do_rd) begin
                    rd_data  <= mem[rd_ptr];
                    rd_ptr   <= (rd_ptr == DEPTH-1) ? {AW{1'b0}}
                                                    : rd_ptr + 1'b1;
                    rd_valid <= 1'b1;
                end

                case ({do_wr, do_rd})
                    2'b10: level <= level + 1'b1;
                    2'b01: level <= level - 1'b1;
                    default: level <= level;
                endcase
            end

            if (wr_en && full)
                overflow <= 1'b1;
            if (rd_en && empty)
                underflow <= 1'b1;
        end
    end
endmodule
`default_nettype wire
