`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// tb_spi_gowin_io.v
//
// Pad-level check of the Gowin ODDR SPI output cells against Gowin's own
// behavioural ODDR model (simlib/gw5a/prim_sim.v).  The iCE40 build did the
// same thing against SB_IO in cells_sim.v: the DDR phase relationship is the
// one part of this design that would fail silently and corrupt every byte if
// it were wrong, so it is not something to trust from inspection.
//
// The device under test is the real st7789_camera_ctrl driving the same four
// ODDR instantiations the top level uses, shrunk to an 8x2 window and a 2000
// Hz "CLK_HZ" so a full reset -> init -> window -> pixels -> idle cycle
// completes in a short simulation.
//
// Checked at the pads, with no knowledge of what the byte stream should
// contain -- only that the panel receives exactly what the engine sent:
//
//   * every byte reconstructed by clocking MOSI on SCLK rising edges equals
//     the byte spi_stream_tx accepted, in order, with the same DC level;
//   * MOSI and DC are stable for at least a third of a clk period either side
//     of every sampling edge (the design intent is half a period);
//   * CS is low at every SCLK rising edge -- i.e. CS never truncates the last
//     byte of a burst, which is exactly what the deeper ODDR pipeline would
//     have caused had CS not been routed through a matching cell;
//   * SCLK pulses are discrete: one rising edge per bit, never merged.
//
//   make sim
// ============================================================================
module tb_spi_gowin_io;

    localparam integer CLK_HALF = 5;   // 100 MHz sim clock; only ratios matter

    reg clk = 1'b0;
    always #CLK_HALF clk = ~clk;

    reg resetn = 1'b0;

    // Gowin's primitives reference a top-level GSR instance by name.
    GSR GSR (.GSRI(1'b1));

    // ---------------- FIFO stub: always ready, incrementing pixels ----------
    reg  [15:0] fifo_rd_data = 16'h0000;
    reg         fifo_rd_valid = 1'b0;
    wire        fifo_rd_en;
    reg  [15:0] next_pixel = 16'hA53C;

    always @(posedge clk) begin
        fifo_rd_valid <= 1'b0;
        if (fifo_rd_en) begin
            fifo_rd_data  <= next_pixel;
            fifo_rd_valid <= 1'b1;
            next_pixel    <= next_pixel + 16'h0137;
        end
    end

    // ---------------- device under test ----------------
    reg  stream_enable = 1'b0;
    reg  frame_sync    = 1'b0;

    wire tft_sclk_d0, tft_sclk_d1, tft_mosi_bit, tft_dc_bit, tft_cs_n;
    wire tft_resn, tft_bl;
    wire init_done, frame_done, sync_error, stream_active;

    st7789_camera_ctrl #(
        .CLK_HZ  (2000),      // makes the init ROM's millisecond delays short
        .SPI_HZ  (2000),
        .WIDTH   (8),
        .HEIGHT  (2),
        .X_SHIFT (0),
        .Y_SHIFT (0)
    ) dut (
        .clk           (clk),
        .resetn        (resetn),
        .stream_enable (stream_enable),
        .frame_sync    (frame_sync),
        .fifo_empty    (1'b0),
        .fifo_rd_data  (fifo_rd_data),
        .fifo_rd_valid (fifo_rd_valid),
        .fifo_rd_en    (fifo_rd_en),
        .tft_sclk_d0   (tft_sclk_d0),
        .tft_sclk_d1   (tft_sclk_d1),
        .tft_mosi_bit  (tft_mosi_bit),
        .tft_cs_n      (tft_cs_n),
        .tft_dc_bit    (tft_dc_bit),
        .tft_resn      (tft_resn),
        .tft_bl        (tft_bl),
        .init_done     (init_done),
        .frame_done    (frame_done),
        .sync_error    (sync_error),
        .stream_active (stream_active)
    );

    // ---------------- pad cells, identical to the top level ----------------
    reg sclk_d0_q = 1'b0;
    reg mosi_q    = 1'b0;
    reg dc_q      = 1'b1;
    reg cs_n_q    = 1'b1;

    always @(posedge clk) begin
        sclk_d0_q <= tft_sclk_d0;
        mosi_q    <= tft_mosi_bit;
        dc_q      <= tft_dc_bit;
        cs_n_q    <= tft_cs_n;
    end

    wire pad_scl, pad_sda, pad_dc, pad_cs;

    ODDR pad_sclk_io (.Q0(pad_scl), .Q1(), .D0(sclk_d0_q), .D1(tft_sclk_d1),
                      .TX(1'b0), .CLK(clk));
    ODDR pad_mosi_io (.Q0(pad_sda), .Q1(), .D0(mosi_q),    .D1(tft_mosi_bit),
                      .TX(1'b0), .CLK(clk));
    ODDR pad_dc_io   (.Q0(pad_dc),  .Q1(), .D0(dc_q),      .D1(tft_dc_bit),
                      .TX(1'b0), .CLK(clk));
    ODDR pad_cs_io   (.Q0(pad_cs),  .Q1(), .D0(cs_n_q),    .D1(tft_cs_n),
                      .TX(1'b0), .CLK(clk));

    // ---------------- what the engine intended to send ----------------
    // Every byte spi_stream_tx accepts, in order, tagged with its DC level.
    reg [8:0] expect_q [0:65535];
    integer   exp_wr = 0;
    integer   exp_rd = 0;

    // Real silicon starts from GSR, so every flop has a defined value before
    // the first edge.  Plain Verilog regs start as X instead, and those X's
    // reach the pads through the ODDR pipeline, so checking only begins once
    // reset has flushed them out.
    reg monitor_en = 1'b0;

    always @(posedge clk) begin
        if (monitor_en && dut.tx_accept) begin
            expect_q[exp_wr] = {dut.tx_dc_i, dut.tx_data};
            exp_wr = exp_wr + 1;
        end
    end

    // ---------------- pad-side receiver ----------------
    real mosi_change_t = 0.0;
    real dc_change_t   = 0.0;
    real edge_t        = 0.0;

    always @(pad_sda) mosi_change_t = $realtime;
    always @(pad_dc)  dc_change_t   = $realtime;

    integer bit_i     = 0;
    integer bits_seen = 0;
    integer errors    = 0;
    reg [7:0] rx_byte = 8'h00;
    reg       rx_dc   = 1'b0;
    reg [8:0] expected;

    // A third of a clk period on each side; the design intends a full half.
    localparam real MARGIN = (2.0*CLK_HALF)/3.0;
    localparam real SETTLE = 0.001;

    always @(posedge pad_scl) if (monitor_en) begin
        edge_t = $realtime;
        // The pads are behavioural muxes off the same clock edge, so a pad
        // that changes *at* the sampling edge updates in the same simulation
        // instant.  Settle first, then judge against edge_t -- otherwise a
        // zero-setup design would pass or fail purely on scheduling order.
        #(SETTLE);

        if (pad_cs !== 1'b0) begin
            $display("FAIL @%0t: SCLK rising edge with CS high (bit %0d)",
                     $time, bits_seen);
            errors = errors + 1;
        end

        if ((edge_t - mosi_change_t) < MARGIN) begin
            $display("FAIL @%0t: MOSI setup only %0.2f ns (need %0.2f)",
                     $time, edge_t - mosi_change_t, MARGIN);
            errors = errors + 1;
        end
        if ((edge_t - dc_change_t) < MARGIN) begin
            $display("FAIL @%0t: DC setup only %0.2f ns (need %0.2f)",
                     $time, edge_t - dc_change_t, MARGIN);
            errors = errors + 1;
        end

        if (bit_i == 0) rx_dc = pad_dc;
        rx_byte = {rx_byte[6:0], pad_sda};
        bit_i   = bit_i + 1;
        bits_seen = bits_seen + 1;

        if (bit_i == 8) begin
            bit_i = 0;
            if (exp_rd >= exp_wr) begin
                $display("FAIL @%0t: pad produced byte %02h with nothing sent",
                         $time, rx_byte);
                errors = errors + 1;
            end else begin
                expected = expect_q[exp_rd];
                if (expected[7:0] !== rx_byte || expected[8] !== rx_dc) begin
                    $display("FAIL @%0t: byte %0d pad={dc=%b,%02h} engine={dc=%b,%02h}",
                             $time, exp_rd, rx_dc, rx_byte,
                             expected[8], expected[7:0]);
                    errors = errors + 1;
                end
                exp_rd = exp_rd + 1;
            end
        end

        // Hold check: MOSI/DC must not move for MARGIN after the edge.
        fork
            begin : hold_check
                #(MARGIN - SETTLE);
                if (mosi_change_t > edge_t) begin
                    $display("FAIL @%0t: MOSI moved %0.2f ns after its edge",
                             $time, mosi_change_t - edge_t);
                    errors = errors + 1;
                end
                if (dc_change_t > edge_t) begin
                    $display("FAIL @%0t: DC moved %0.2f ns after its edge",
                             $time, dc_change_t - edge_t);
                    errors = errors + 1;
                end
            end
        join_none
    end

    // Discrete pulses: a high SCLK must fall again within one clk period.
    always @(posedge pad_scl) if (monitor_en) begin : pulse_width
        fork
            begin
                #(2*CLK_HALF - SETTLE);
                if (pad_scl === 1'b1) begin
                    $display("FAIL @%0t: SCLK pulse merged (still high after one clk)",
                             $time);
                    errors = errors + 1;
                end
            end
        join_none
    end

    // ---------------- stimulus ----------------
    integer wait_cycles;

    initial begin
        repeat (10) @(posedge clk);
        resetn <= 1'b1;
        repeat (10) @(posedge clk);
        monitor_en <= 1'b1;

        // Let the reset + init-ROM sequence finish.
        wait_cycles = 0;
        while (!init_done && wait_cycles < 2_000_000) begin
            @(posedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (!init_done) begin
            $display("FAIL: panel init never completed");
            errors = errors + 1;
        end else begin
            $display("init done after %0d cycles, %0d bytes sent",
                     wait_cycles, exp_wr);
        end

        // One full frame: address window + 8x2 pixels.
        stream_enable <= 1'b1;
        @(posedge clk);
        frame_sync <= 1'b1;
        @(posedge clk);
        frame_sync <= 1'b0;

        wait_cycles = 0;
        while (!frame_done && wait_cycles < 2_000_000) begin
            @(posedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (!frame_done) begin
            $display("FAIL: frame never completed");
            errors = errors + 1;
        end

        // Drain the last byte's pad pipeline before judging.
        repeat (20) @(posedge clk);

        if (sync_error) begin
            $display("FAIL: controller reported sync_error");
            errors = errors + 1;
        end
        if (exp_rd != exp_wr) begin
            $display("FAIL: engine sent %0d bytes, pads delivered %0d",
                     exp_wr, exp_rd);
            errors = errors + 1;
        end
        if (bits_seen != 8*exp_wr) begin
            $display("FAIL: %0d SCLK pulses for %0d bytes (expected %0d)",
                     bits_seen, exp_wr, 8*exp_wr);
            errors = errors + 1;
        end
        if (pad_cs !== 1'b1) begin
            $display("FAIL: CS still asserted after the frame");
            errors = errors + 1;
        end

        $display("----------------------------------------------------------");
        $display("bytes checked at the pads : %0d", exp_rd);
        $display("SCLK pulses               : %0d", bits_seen);
        $display("errors                    : %0d", errors);
        if (errors == 0)
            $display("tb_spi_gowin_io: PASS");
        else
            $display("tb_spi_gowin_io: FAIL");
        $display("----------------------------------------------------------");

        if (errors != 0) $fatal(1);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("FAIL: simulation timeout");
        $fatal(1);
    end
endmodule
`default_nettype wire
