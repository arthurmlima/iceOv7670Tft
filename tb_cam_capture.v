`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// tb_cam_capture.v
//
// End-to-end test of the camera front end at its new rates: a synthetic OV7670
// drives PCLK/HREF/VSYNC/D[7:0] with real QVGA timing, cam_capture oversamples
// it on the 100 MHz clk_cap, async_fifo carries the result into the 40 MHz
// clk_sys domain, and the checker verifies that exactly the right pixels come
// out in the right order.
//
// This is the part of path C that had to be got right: two new clock domains,
// a crossing between them, and a receiver whose sampling margin changed.  The
// data is (row, column) encoded rather than a fixed pattern, so a lost,
// duplicated or reordered pixel shows up as a specific coordinate mismatch
// instead of just a wrong count -- a shear on the panel is exactly what a
// silently dropped pixel per line looks like.
//
//   make sim-camera
// ============================================================================
module tb_cam_capture #(
    // Overridden by the negative-control variants.  PCLK is described by its
    // high and low times separately rather than a half period, because the
    // thing that actually breaks an oversampling receiver is duty-cycle
    // distortion, not frequency: a phase shorter than one sampling period can
    // fall entirely between two samples and be missed.
    parameter real PCLK_HI = 41.6667,      // 12 MHz, 50% duty
    parameter real PCLK_LO = 41.6667,
    parameter real CAP_HALF = 5.0          // clk_cap 100 MHz
)();
    localparam real SYS_HALF  = 12.5;      // 40 MHz

    localparam integer COLS       = 320;   // QVGA columns the sensor emits
    localparam integer ROWS       = 240;
    localparam integer COL_FIRST  = 20;    // must match cam_capture
    localparam integer COL_LAST   = 299;
    localparam integer KEEP       = COL_LAST - COL_FIRST + 1;   // 280
    localparam integer HBLANK     = 288;   // PCLK cycles of horizontal blanking

    reg pclk = 1'b0;
    initial forever begin
        pclk = 1'b1; #PCLK_HI;
        pclk = 1'b0; #PCLK_LO;
    end

    reg clk_cap = 1'b0;  always #CAP_HALF clk_cap = ~clk_cap;
    reg clk_sys = 1'b0;  always #SYS_HALF clk_sys = ~clk_sys;

    reg rst = 1'b1;

    GSR GSR (.GSRI(1'b1));

    // ---------------- synthetic OV7670 ----------------
    reg        vsync = 1'b0;
    reg        href  = 1'b0;
    reg [7:0]  dout  = 8'h00;

    // Each pixel is encoded as {row, col[7:0]} so the checker knows exactly
    // which coordinate every received word should be.
    task send_frame;
        integer r, c;
        begin
            @(negedge pclk); vsync <= 1'b1;   // sensor drives on the falling edge
            repeat (4) @(negedge pclk);
            vsync <= 1'b0;
            repeat (20) @(negedge pclk);

            for (r = 0; r < ROWS; r = r + 1) begin
                @(negedge pclk); href <= 1'b1;
                for (c = 0; c < COLS; c = c + 1) begin
                    dout <= r[7:0];              // high byte
                    @(negedge pclk);
                    dout <= c[7:0];              // low byte
                    @(negedge pclk);
                end
                href <= 1'b0;
                repeat (HBLANK) @(negedge pclk);
            end
        end
    endtask

    // ---------------- device under test ----------------
    wire [15:0] cap_src_pixel;
    wire        cap_src_wr;
    wire        cap_src_frame_sync;

    (* ASYNC_REG = "TRUE" *) reg [1:0] cap_rst_sync = 2'b11;
    always @(posedge clk_cap) cap_rst_sync <= {cap_rst_sync[0], rst};
    wire cap_rst = cap_rst_sync[1];

    cam_capture capture (
        .clk        (clk_cap),
        .rst        (cap_rst),
        .enable     (1'b1),
        .pclk_i     (pclk),
        .vsync_i    (vsync),
        .href_i     (href),
        .d_i        (dout),
        .pix_data   (cap_src_pixel),
        .pix_wr     (cap_src_wr),
        .frame_sync (cap_src_frame_sync)
    );

    wire        cdc_full, cdc_empty;
    wire [16:0] cdc_rd_data;

    async_fifo #(.WIDTH(17), .AW(3)) cdc (
        .wr_clk  (clk_cap),
        .wr_rst  (cap_rst),
        .wr_en   (cap_src_wr || cap_src_frame_sync),
        .wr_data ({cap_src_frame_sync, cap_src_pixel}),
        .wr_full (cdc_full),

        .rd_clk  (clk_sys),
        .rd_rst  (rst),
        .rd_en   (1'b1),
        .rd_data (cdc_rd_data),
        .rd_empty(cdc_empty)
    );

    // Mirrors the read logic in tangprimer25k_st7789_top's g_camera branch.
    reg [15:0] cap_pixel      = 16'h0000;
    reg        cap_wr         = 1'b0;
    reg        cap_frame_sync = 1'b0;

    always @(posedge clk_sys) begin
        if (rst) begin
            cap_wr         <= 1'b0;
            cap_frame_sync <= 1'b0;
        end else begin
            cap_wr         <= 1'b0;
            cap_frame_sync <= 1'b0;
            if (!cdc_empty) begin
                if (cdc_rd_data[16]) cap_frame_sync <= 1'b1;
                else begin
                    cap_pixel <= cdc_rd_data[15:0];
                    cap_wr    <= 1'b1;
                end
            end
        end
    end

    // ---------------- checker ----------------
    integer errors      = 0;
    integer got         = 0;
    integer frame_syncs = 0;
    integer overflows   = 0;
    integer exp_r, exp_c;
    reg [15:0] expected;

    always @(posedge clk_sys) begin
        if (!rst) begin
            if (cap_frame_sync) frame_syncs = frame_syncs + 1;
            if (cap_wr) begin
                exp_r = got / KEEP;
                exp_c = COL_FIRST + (got % KEEP);
                expected = {exp_r[7:0], exp_c[7:0]};
                if (cap_pixel !== expected && errors < 10) begin
                    $display("FAIL @%0t: pixel %0d (row %0d col %0d) = %04h, expected %04h",
                             $time, got, exp_r, exp_c, cap_pixel, expected);
                    errors = errors + 1;
                end
                got = got + 1;
            end
        end
    end

    always @(posedge clk_cap) if (!cap_rst && cdc_full) overflows = overflows + 1;

    initial begin
        repeat (20) @(posedge clk_sys);
        rst <= 1'b0;
        repeat (20) @(posedge clk_sys);

        send_frame;
        repeat (200) @(posedge clk_sys);   // drain

        if (got != KEEP*ROWS) begin
            $display("FAIL: got %0d pixels, expected %0d", got, KEEP*ROWS);
            errors = errors + 1;
        end
        if (frame_syncs != 1) begin
            $display("FAIL: %0d frame_sync pulses, expected 1", frame_syncs);
            errors = errors + 1;
        end
        if (overflows != 0) begin
            $display("FAIL: CDC FIFO reported full %0d times", overflows);
            errors = errors + 1;
        end

        $display("----------------------------------------------------------");
        $display("PCLK high/low    : %0.2f / %0.2f ns   clk_cap period %0.1f ns",
                 PCLK_HI, PCLK_LO, 2*CAP_HALF);
        $display("samples per PCLK : %0.2f  (high phase gets %0.2f)",
                 (PCLK_HI+PCLK_LO)/(2*CAP_HALF), PCLK_HI/(2*CAP_HALF));
        $display("pixels delivered : %0d (expected %0d)", got, KEEP*ROWS);
        $display("frame syncs      : %0d", frame_syncs);
        $display("CDC overflows    : %0d", overflows);
        $display("errors           : %0d", errors);
        if (errors == 0) $display("tb_cam_capture: PASS");
        else             $display("tb_cam_capture: FAIL");
        $display("----------------------------------------------------------");
        if (errors != 0) $fatal(1);
        $finish;
    end

    initial begin
        #40_000_000;
        $display("FAIL: simulation timeout");
        $fatal(1);
    end
endmodule
`default_nettype wire
