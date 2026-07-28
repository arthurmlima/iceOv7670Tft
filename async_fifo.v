`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// async_fifo.v
//
// Textbook dual-clock FIFO with Gray-coded pointers, used for exactly one
// thing here: carrying captured pixels out of the camera's PCLK domain into
// clk_sys.
//
// It is deliberately tiny.  The camera produces one pixel per two PCLK cycles
// (6 M/s at PCLK = 12 MHz) and the read side pops one entry every clk_sys
// cycle it is not empty (40 M/s), so the occupancy is 0 or 1 in steady state.
// The depth exists to cover synchroniser latency and bursts, not to buffer --
// the *surplus* buffering is pixel_fifo's job, downstream and single-clock.
//
// Splitting the two jobs is what keeps this change small: frame_stream_gate,
// pixel_xor_stage and pixel_fifo all stay exactly as they were, in clk_sys,
// including pixel_fifo's flush-on-frame-boundary which cannot be done safely
// across clock domains.
//
// Standard construction, and standard reasons:
//   * pointers are one bit wider than the address so full and empty are
//     distinguishable;
//   * they cross as Gray code so a pointer sampled mid-update can only ever be
//     read as its old or new value, never a mixture;
//   * each crossing goes through two flops in the destination domain;
//   * the full and empty flags are *registered*, not combinational -- besides
//     keeping them off the critical path, a combinational `full` would close a
//     loop through `do_wr` back into the pointer that produces it.
// The synchronisers are conservative in the safe direction: full may clear
// late and empty may clear late, so the FIFO can look fuller or emptier than
// it really is, never the other way round.
// ============================================================================
module async_fifo #(
    parameter integer WIDTH = 17,
    parameter integer AW    = 4        // depth = 2^AW
)(
    input  wire             wr_clk,
    input  wire             wr_rst,
    input  wire             wr_en,
    input  wire [WIDTH-1:0] wr_data,
    output wire             wr_full,

    input  wire             rd_clk,
    input  wire             rd_rst,
    input  wire             rd_en,
    output wire [WIDTH-1:0] rd_data,
    output wire             rd_empty
);
    localparam integer DEPTH = 1 << AW;

    // GW5A-25A (device version A) has no distributed LUT RAM, so this small
    // array has to become flops plus a read mux.  Saying so explicitly stops
    // the tool trying to map an asynchronous-read memory onto BSRAM, which it
    // physically cannot do.
    (* syn_ramstyle = "registers" *)
    reg [WIDTH-1:0] mem [0:DEPTH-1];

    reg [AW:0] wr_bin  = {(AW+1){1'b0}};
    reg [AW:0] wr_gray = {(AW+1){1'b0}};
    reg [AW:0] rd_bin  = {(AW+1){1'b0}};
    reg [AW:0] rd_gray = {(AW+1){1'b0}};

    (* ASYNC_REG = "TRUE" *) reg [AW:0] rd_gray_meta = {(AW+1){1'b0}};
    (* ASYNC_REG = "TRUE" *) reg [AW:0] rd_gray_sync = {(AW+1){1'b0}};
    (* ASYNC_REG = "TRUE" *) reg [AW:0] wr_gray_meta = {(AW+1){1'b0}};
    (* ASYNC_REG = "TRUE" *) reg [AW:0] wr_gray_sync = {(AW+1){1'b0}};

    reg wr_full_r  = 1'b0;
    reg rd_empty_r = 1'b1;

    wire do_wr = wr_en && !wr_full_r;
    wire do_rd = rd_en && !rd_empty_r;

    wire [AW:0] wr_bin_next  = wr_bin + do_wr;
    wire [AW:0] wr_gray_next = wr_bin_next ^ (wr_bin_next >> 1);
    wire [AW:0] rd_bin_next  = rd_bin + do_rd;
    wire [AW:0] rd_gray_next = rd_bin_next ^ (rd_bin_next >> 1);

    // Full when the next write pointer would reach the read pointer one lap
    // behind: in Gray code that is the read pointer with its top two bits
    // inverted.
    wire wr_full_next  = (wr_gray_next ==
                          {~rd_gray_sync[AW:AW-1], rd_gray_sync[AW-2:0]});
    wire rd_empty_next = (rd_gray_next == wr_gray_sync);

    // ---------------- write domain ----------------
    always @(posedge wr_clk) begin
        if (wr_rst) begin
            wr_bin  <= {(AW+1){1'b0}};
            wr_gray <= {(AW+1){1'b0}};
        end else begin
            if (do_wr)
                mem[wr_bin[AW-1:0]] <= wr_data;
            wr_bin  <= wr_bin_next;
            wr_gray <= wr_gray_next;
        end
    end

    always @(posedge wr_clk) begin
        if (wr_rst) wr_full_r <= 1'b0;
        else        wr_full_r <= wr_full_next;
    end

    always @(posedge wr_clk) begin
        if (wr_rst) begin
            rd_gray_meta <= {(AW+1){1'b0}};
            rd_gray_sync <= {(AW+1){1'b0}};
        end else begin
            rd_gray_meta <= rd_gray;
            rd_gray_sync <= rd_gray_meta;
        end
    end

    // ---------------- read domain ----------------
    always @(posedge rd_clk) begin
        if (rd_rst) begin
            rd_bin  <= {(AW+1){1'b0}};
            rd_gray <= {(AW+1){1'b0}};
        end else begin
            rd_bin  <= rd_bin_next;
            rd_gray <= rd_gray_next;
        end
    end

    always @(posedge rd_clk) begin
        if (rd_rst) rd_empty_r <= 1'b1;
        else        rd_empty_r <= rd_empty_next;
    end

    always @(posedge rd_clk) begin
        if (rd_rst) begin
            wr_gray_meta <= {(AW+1){1'b0}};
            wr_gray_sync <= {(AW+1){1'b0}};
        end else begin
            wr_gray_meta <= wr_gray;
            wr_gray_sync <= wr_gray_meta;
        end
    end

    assign wr_full  = wr_full_r;
    assign rd_empty = rd_empty_r;
    assign rd_data  = mem[rd_bin[AW-1:0]];
endmodule
`default_nettype wire
