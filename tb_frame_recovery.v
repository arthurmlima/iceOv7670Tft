`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// tb_frame_recovery.v
//
// Reproduces the pipeline deadlock and proves the watchdog clears it.
//
// The wedge is a loop between three modules, which is why it is permanent
// rather than a one-frame glitch:
//
//   st7789_camera_ctrl waits in S_PIX_NEED for pixels that never arrive
//     -> stream_active stays high
//        -> frame_stream_gate sees frame_ready_i low at the next VSYNC
//           -> it suppresses every pixel of that frame and sets drop_error
//              -> the FIFO stays empty, so the FSM keeps waiting
//
// Once entered, only a reset gets out, which is exactly the reported symptom:
// a frozen picture that never updates. This testbench instantiates the real
// three modules in that loop, delivers a deliberately short frame, and checks
// that the design recovers on its own and resumes completing frames.
//
//   make sim-recovery
// ============================================================================
module tb_frame_recovery;

    localparam integer W = 8, H = 2;
    localparam integer NPIX = W*H;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg resetn = 1'b0;
    wire rst = ~resetn;

    GSR GSR (.GSRI(1'b1));

    // ---------------- stimulus: a camera we can make misbehave ----------
    reg        cam_frame_sync = 1'b0;
    reg        cam_pix_wr     = 1'b0;
    reg [15:0] cam_pix_data   = 16'h1234;

    // ---------------- the three modules that form the wedge -------------
    wire        init_done, frame_done, sync_error, starve_error, stream_active;
    wire        acc_frame_sync, acc_pix_wr, drop_error;
    wire        lcd_frame_ready = init_done && !stream_active;

    frame_stream_gate gate (
        .clk           (clk),
        .rst           (rst),
        .frame_sync_i  (cam_frame_sync),
        .frame_ready_i (lcd_frame_ready),
        .pixel_valid_i (cam_pix_wr),
        .frame_sync_o  (acc_frame_sync),
        .pixel_valid_o (acc_pix_wr),
        .drop_error    (drop_error)
    );

    wire        fifo_empty, fifo_full, fifo_rd_valid, fifo_rd_en;
    wire [15:0] fifo_rd_data;
    wire        fifo_overflow, fifo_underflow;
    wire [8:0]  fifo_level;

    pixel_fifo fifo (
        .clk       (clk),
        .rst       (rst),
        .flush     (acc_frame_sync),
        .wr_en     (acc_pix_wr),
        .wr_data   (cam_pix_data),
        .full      (fifo_full),
        .rd_en     (fifo_rd_en),
        .rd_data   (fifo_rd_data),
        .rd_valid  (fifo_rd_valid),
        .empty     (fifo_empty),
        .overflow  (fifo_overflow),
        .underflow (fifo_underflow),
        .level     (fifo_level)
    );

    // CLK_HZ=2000 makes one "ms" two clocks, so STARVE_MS=20 is 40 clocks.
    st7789_camera_ctrl #(
        .CLK_HZ    (2000),
        .SPI_HZ    (2000),
        .WIDTH     (W),
        .HEIGHT    (H),
        .X_SHIFT   (0),
        .Y_SHIFT   (0),
        .STARVE_MS (20)
    ) dut (
        .clk           (clk),
        .resetn        (resetn),
        .stream_enable (1'b1),
        .frame_sync    (acc_frame_sync),
        .fifo_empty    (fifo_empty),
        .fifo_rd_data  (fifo_rd_data),
        .fifo_rd_valid (fifo_rd_valid),
        .fifo_rd_en    (fifo_rd_en),
        .tft_sclk_d0   (), .tft_sclk_d1 (), .tft_mosi_bit (),
        .tft_cs_n      (), .tft_dc_bit  (), .tft_resn     (), .tft_bl (),
        .init_done     (init_done),
        .frame_done    (frame_done),
        .sync_error    (sync_error),
        .starve_error  (starve_error),
        .stream_active (stream_active)
    );

    // ---------------- helpers ----------------
    integer errors = 0;
    integer frames_completed = 0;
    integer i, guard;

    always @(posedge clk) if (frame_done) frames_completed = frames_completed + 1;

    task send_frame(input integer npix);
        begin
            @(posedge clk); cam_frame_sync <= 1'b1;
            @(posedge clk); cam_frame_sync <= 1'b0;
            for (i = 0; i < npix; i = i + 1) begin
                // Feed only as fast as the panel drains, as the real camera does.
                while (fifo_full) @(posedge clk);
                @(posedge clk); cam_pix_wr <= 1'b1; cam_pix_data <= 16'h1000 + i[15:0];
                @(posedge clk); cam_pix_wr <= 1'b0;
                repeat (14) @(posedge clk);
            end
        end
    endtask

    task check(input cond, input [255:0] msg);
        begin
            if (!cond) begin
                $display("FAIL @%0t: %0s", $time, msg);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        repeat (10) @(posedge clk);
        resetn <= 1'b1;

        guard = 0;
        while (!init_done && guard < 2_000_000) begin @(posedge clk); guard = guard + 1; end
        check(init_done, "panel init never completed");

        // ---- 1. a healthy frame completes ----
        send_frame(NPIX);
        guard = 0;
        while (stream_active && guard < 2_000) begin @(posedge clk); guard = guard + 1; end
        check(frames_completed == 1, "first full frame did not complete");
        check(!starve_error, "watchdog fired on a healthy frame");
        $display("full frame        -> completed=%0d starve=%b", frames_completed, starve_error);

        // ---- 2. a short frame: the camera stops half way ----
        send_frame(NPIX/2);
        // Without the watchdog the FSM sits in S_PIX_NEED forever from here.
        guard = 0;
        while (stream_active && guard < 2_000) begin @(posedge clk); guard = guard + 1; end
        check(!stream_active, "STILL WEDGED: FSM never left the pixel phase");
        check(starve_error,   "watchdog did not latch starve_error");
        check(frames_completed == 1, "short frame should not have completed");
        $display("starved frame     -> recovered=%b starve=%b", !stream_active, starve_error);

        // ---- 3. the stream resumes by itself, no reset ----
        send_frame(NPIX);
        guard = 0;
        while (stream_active && guard < 2_000) begin @(posedge clk); guard = guard + 1; end
        check(frames_completed == 2, "pipeline did not resume after a starved frame");
        $display("next frame        -> completed=%0d", frames_completed);

        // ---- 4. and keeps going ----
        send_frame(NPIX);
        guard = 0;
        while (stream_active && guard < 2_000) begin @(posedge clk); guard = guard + 1; end
        check(frames_completed == 3, "pipeline stopped again after recovery");

        $display("----------------------------------------------------------");
        $display("frames completed : %0d (expected 3)", frames_completed);
        $display("starve_error     : %b (expected 1, latched by the short frame)", starve_error);
        $display("errors           : %0d", errors);
        if (errors == 0) $display("tb_frame_recovery: PASS");
        else             $display("tb_frame_recovery: FAIL");
        $display("----------------------------------------------------------");
        if (errors != 0) $fatal(1);
        $finish;
    end

    initial begin
        #100_000_000;
        $display("FAIL: simulation timeout (this is what the deadlock looks like)");
        $fatal(1);
    end
endmodule
`default_nettype wire
