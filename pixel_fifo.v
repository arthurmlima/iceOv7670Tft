// ============================================================================
// pixel_fifo.v - 256 x 16 synchronous FIFO. Maps to exactly one SB_RAM40_4K.
//
// This is the ONLY image memory in the whole design (4 kbit = 0.4% of a
// framebuffer). It absorbs the per-line rate mismatch between the camera
// burst (2.0 Mpx/s while HREF is high) and the SPI drain (1.5 Mpx/s
// continuous). Worst-case occupancy is ~70 pixels; 256 gives 3.5x margin.
//
// 'clear' resets both pointers (used at every camera VSYNC so a frame always
// starts from an empty, aligned FIFO). 'overflow' is a sticky debug flag:
// it should never assert if the clock plan is right.
//
// Read side has one cycle of latency (BRAM output register); rdata holds its
// value until the next read.
// ============================================================================

module pixel_fifo (
    input  wire        clk,
    input  wire        rst,
    input  wire        clear,

    input  wire        wr,
    input  wire [15:0] wdata,
    output wire        full,

    input  wire        rd,
    output reg  [15:0] rdata,
    output wire        empty,

    output reg         overflow
);

    reg [15:0] mem [0:255];
    reg [8:0]  wp, rp;                 // extra MSB distinguishes full/empty

    assign empty = (wp == rp);
    assign full  = (wp[8] != rp[8]) && (wp[7:0] == rp[7:0]);

    // Memory write port
    always @(posedge clk) begin
        if (wr && !full && !clear && !rst)
            mem[wp[7:0]] <= wdata;
    end

    // Memory read port (registered output -> 1 cycle latency)
    always @(posedge clk) begin
        if (rd && !empty)
            rdata <= mem[rp[7:0]];
    end

    // Pointers
    always @(posedge clk) begin
        if (rst || clear) begin
            wp <= 9'd0;
            rp <= 9'd0;
        end else begin
            if (wr && !full)  wp <= wp + 9'd1;
            if (rd && !empty) rp <= rp + 9'd1;
        end
    end

    // Sticky overflow (cleared only by reset / button)
    always @(posedge clk) begin
        if (rst)
            overflow <= 1'b0;
        else if (wr && full)
            overflow <= 1'b1;
    end

endmodule
