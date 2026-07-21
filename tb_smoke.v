// ============================================================================
// tb_smoke.v - end-to-end smoke test with shrunk time constants.
//
// Scaling tricks (all via parameters, no RTL edits):
//   * cam_init: TICK_DIV=6 -> SCCB runs ~2 MHz instead of 100 kHz
//   * st7789_ctrl: CLK_HZ=48_000 -> one "millisecond" = 48 clocks
//   * PIX_TOTAL=840 -> a "frame" is 3 lines of 280 pixels
//
// The fake camera keeps the real shape: PCLK = clk/12 (as on hardware),
// 640 data bytes per HREF line (values = byte index), 3 lines per frame,
// VSYNC pulse between frames.
//
// Checks:
//   1. first SPI byte is SWRESET (0x01), first data byte is COLMOD's 0x55
//   2. a RAMWR (0x2C, DC=0) appears after init
//   3. first two pixel bytes after RAMWR are 0x28,0x29 (camera bytes for
//      column 20 - proves the 320->280 crop and byte pairing)
//   4. FIFO never overflows
//   5. a second RAMWR appears (frame restart path works)
// ============================================================================

`timescale 1ns/1ps

module tb_smoke;

    reg clk = 0;
    always #10 clk = ~clk;          // "48 MHz"

    reg rst = 1;

    // ---------------- camera model ----------------
    reg        pclk = 0;
    reg        vsync = 0;
    reg        href = 0;
    reg [7:0]  d = 0;

    // PCLK = clk/12, data changes on PCLK falling edge (like the OV7670)
    integer pdiv = 0;
    always @(posedge clk) begin
        pdiv = (pdiv == 5) ? 0 : pdiv + 1;
        if (pdiv == 0) pclk <= ~pclk;
    end

    task send_line;                 // 640 bytes = 320 pixels
        integer i;
        begin
            @(negedge pclk);
            href <= 1;
            for (i = 0; i < 640; i = i + 1) begin
                d <= i[7:0];
                @(negedge pclk);
            end
            href <= 0;
            d <= 0;
            // inter-line blanking: 144 PCLK periods (like the real sensor,
            // this is where the FIFO drains)
            repeat (144) @(negedge pclk);
        end
    endtask

    task send_frame;
        begin
            @(negedge pclk);
            vsync <= 1;
            repeat (20) @(negedge pclk);
            vsync <= 0;
            repeat (40) @(negedge pclk);
            send_line;
            send_line;
            send_line;
        end
    endtask

    // ---------------- DUT ----------------
    wire        sioc, siod_low, sccb_done;
    wire [15:0] pix_data, fifo_rdata;
    wire        pix_wr, frame_sync;
    wire        fifo_rd, fifo_clear, fifo_full, fifo_empty, fifo_ovf;
    wire        lcd_sck, lcd_mosi, lcd_dc, lcd_res_n, lcd_cs_n, lcd_bl;
    wire        init_done;
    wire        cap_en = sccb_done & init_done;

    cam_init #(
        .TICK_DIV(6), .BOOT_TICKS(8), .GAP_TICKS(4), .RST_TICKS(8)
    ) u_ci (
        .clk(clk), .rst(rst),
        .sioc(sioc), .siod_low(siod_low), .done(sccb_done)
    );

    cam_capture u_cap (
        .clk(clk), .rst(rst), .enable(cap_en),
        .pclk_i(pclk), .vsync_i(vsync), .href_i(href), .d_i(d),
        .pix_data(pix_data), .pix_wr(pix_wr), .frame_sync(frame_sync)
    );

    pixel_fifo u_fifo (
        .clk(clk), .rst(rst), .clear(fifo_clear),
        .wr(pix_wr), .wdata(pix_data), .full(fifo_full),
        .rd(fifo_rd), .rdata(fifo_rdata), .empty(fifo_empty),
        .overflow(fifo_ovf)
    );

    st7789_ctrl #(
        .CLK_HZ(48_000),            // 1 "ms" = 48 clocks
        .PIX_TOTAL(17'd840)         // 3 lines x 280
    ) u_lcd (
        .clk(clk), .rst(rst), .frame_sync(frame_sync),
        .fifo_rdata(fifo_rdata), .fifo_empty(fifo_empty),
        .fifo_rd(fifo_rd), .fifo_clear(fifo_clear),
        .lcd_sck(lcd_sck), .lcd_mosi(lcd_mosi), .lcd_dc(lcd_dc),
        .lcd_res_n(lcd_res_n), .lcd_cs_n(lcd_cs_n), .lcd_bl(lcd_bl),
        .init_done(init_done)
    );

    // ---------------- SPI monitor ----------------
    // A run of DC=1 bytes that immediately follows RAMWR is a pixel burst;
    // any DC=0 (command) byte closes the current run. Runs are attributed
    // to the RAMWR that opened them, so window data bytes of the *next*
    // frame can never be miscounted as pixels.
    reg [7:0]  mon_shift = 0;
    integer    mon_bits = 0;
    integer    n_bytes = 0;
    integer    n_ramwr = 0;
    integer    run = 0;
    reg        in_pix_run = 0;
    integer    frame1_bytes = 0;
    integer    frame2_bytes = 0;
    reg [7:0]  first_byte = 0;
    reg [7:0]  first_data = 0;
    reg        got_first_data = 0;
    reg [7:0]  pixb0 = 0, pixb1 = 0;
    integer    errors = 0;

    task close_run;
        begin
            if (in_pix_run) begin
                if (n_ramwr == 1) frame1_bytes = run;
                if (n_ramwr == 2) frame2_bytes = run;
            end
            in_pix_run = 0;
            run = 0;
        end
    endtask

    always @(posedge lcd_sck) begin
        mon_shift = {mon_shift[6:0], lcd_mosi};
        mon_bits = mon_bits + 1;
        if (mon_bits == 8) begin
            mon_bits = 0;
            if (n_bytes == 0) first_byte = mon_shift;
            if (lcd_dc && !got_first_data) begin
                first_data = mon_shift;
                got_first_data = 1;
            end
            if (!lcd_dc) begin
                close_run;
                if (mon_shift == 8'h2C) begin
                    n_ramwr = n_ramwr + 1;
                    in_pix_run = 1;
                end
            end else if (in_pix_run) begin
                run = run + 1;
                if (n_ramwr == 1 && run == 1) pixb0 = mon_shift;
                if (n_ramwr == 1 && run == 2) pixb1 = mon_shift;
            end
            n_bytes = n_bytes + 1;
        end
    end

    // ---------------- run ----------------
    initial begin
        repeat (10) @(posedge clk);
        rst = 0;

        wait (sccb_done);
        $display("[%0t] SCCB done", $time);
        wait (init_done);
        $display("[%0t] ST7789 init done, BL=%b", $time, lcd_bl);

        if (first_byte !== 8'h01) begin
            $display("FAIL: first SPI byte %02x, expected 01 (SWRESET)", first_byte);
            errors = errors + 1;
        end
        if (first_data !== 8'h55) begin
            $display("FAIL: first data byte %02x, expected 55 (COLMOD)", first_data);
            errors = errors + 1;
        end

        send_frame;
        // let the tail of the frame drain
        repeat (40000) @(posedge clk);

        if (n_ramwr < 1) begin
            $display("FAIL: no RAMWR seen after first frame");
            errors = errors + 1;
        end
        if (pixb0 !== 8'h28 || pixb1 !== 8'h29) begin
            $display("FAIL: first pixel bytes %02x %02x, expected 28 29 (col 20)",
                     pixb0, pixb1);
            errors = errors + 1;
        end

        send_frame;
        repeat (40000) @(posedge clk);

        if (n_ramwr < 2) begin
            $display("FAIL: no RAMWR for second frame (restart path broken)");
            errors = errors + 1;
        end
        close_run;   // frame 2's burst has no trailing command; close it here
        if (frame1_bytes !== 1680 || frame2_bytes !== 1680) begin
            $display("FAIL: pixel bytes per frame %0d / %0d, expected 1680 / 1680",
                     frame1_bytes, frame2_bytes);
            errors = errors + 1;
        end
        // 62 init bytes + 2 frames x (11 window + 1680 pixel)
        if (n_bytes !== 62 + 2*(11 + 1680)) begin
            $display("FAIL: total bytes %0d, expected %0d", n_bytes, 62 + 2*(11+1680));
            errors = errors + 1;
        end
        if (fifo_ovf) begin
            $display("FAIL: FIFO overflowed");
            errors = errors + 1;
        end

        $display("bytes=%0d ramwr=%0d pix_bytes_frame1=%0d pix_bytes_frame2=%0d",
                 n_bytes, n_ramwr, frame1_bytes, frame2_bytes);
        if (errors == 0) $display("SMOKE TEST PASS");
        else             $display("SMOKE TEST FAIL (%0d errors)", errors);
        $finish;
    end

    // safety timeout
    initial begin
        #80_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
