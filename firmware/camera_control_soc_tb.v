/*
 * Firmware boot/MMIO smoke test for the camera-control PicoSoC.
 *
 * This follows the upstream PicoSoC iCEBreaker simulation style, but tests
 * this project's camera_control_soc directly. The firmware is fetched from
 * the SPI flash model at 0x0010_0000, stages and applies the default camera
 * table, receives ENTER, V, and E over the UART, applies the vivid colour
 * patch through the complete MMIO/CDC path, and must set camera control bit 0
 * without trapping.
 */
`timescale 1 ns / 1 ps
`default_nettype none

module testbench;
    reg clk = 1'b0;
    always #5 clk = !clk;

    // Use a phase-walking clock distinct from the CPU clock so the bundled
    // count/request CDC is not tested only with coincident edges.
    reg camera_cfg_clk = 1'b0;
    always #7 camera_cfg_clk = !camera_cfg_clk;

    reg resetn = 1'b0;
    reg uart_rx = 1'b1;

    wire uart_tx;
    wire cpu_trap;
    wire encrypt_requested;

    wire        camera_cfg_start;
    wire [8:0]  camera_cfg_count;
    wire [15:0] camera_cfg_data;
    reg  [7:0]  camera_cfg_addr = 8'd0;
    reg         camera_cfg_busy = 1'b0;
    reg         camera_cfg_done = 1'b0;
    reg  [8:0]  camera_cfg_index = 9'd0;
    wire        camera_cfg_pending;
    reg         camera_cfg_safe = 1'b0;

    wire       flash_csb;
    wire       flash_clk;
    wire [3:0] flash_io_oe;
    wire [3:0] flash_io_do;
    wire [3:0] flash_io_di;
    wire [3:0] flash_io;

    assign flash_io[0] = flash_io_oe[0] ? flash_io_do[0] : 1'bz;
    assign flash_io[1] = flash_io_oe[1] ? flash_io_do[1] : 1'bz;
    assign flash_io[2] = flash_io_oe[2] ? flash_io_do[2] : 1'bz;
    assign flash_io[3] = flash_io_oe[3] ? flash_io_do[3] : 1'bz;
    assign flash_io_di = flash_io;

`ifdef SYNTHESIS_NETLIST
    camera_control_soc dut (
`else
    camera_control_soc #(
        .BOOT_FROM_FLASH (1),
        // Limit startup's full-RAM clear in RTL simulation. The hardware
        // build retains its normal 128 KiB stack address.
        .STACKADDR       (32'h0000_0400)
    ) dut (
`endif
        .clk               (clk),
        .resetn            (resetn),
        .camera_cfg_clk    (camera_cfg_clk),
        .camera_cfg_resetn (resetn),
        .camera_cfg_safe   (camera_cfg_safe),
        .camera_cfg_start  (camera_cfg_start),
        .camera_cfg_count  (camera_cfg_count),
        .camera_cfg_data   (camera_cfg_data),
        .camera_cfg_addr   (camera_cfg_addr),
        .camera_cfg_busy   (camera_cfg_busy),
        .camera_cfg_done   (camera_cfg_done),
        .camera_cfg_index  (camera_cfg_index),
        .camera_cfg_pending (camera_cfg_pending),
        .encryption_active (1'b0),
        .stream_ready      (1'b1),
        .stream_active     (1'b0),
        .stream_fault      (1'b0),
        .encrypt_requested (encrypt_requested),
        .cpu_trap          (cpu_trap),
        .uart_tx           (uart_tx),
        .uart_rx           (uart_rx),
        .flash_csb         (flash_csb),
        .flash_clk         (flash_clk),
        .flash_io_oe       (flash_io_oe),
        .flash_io_do       (flash_io_do),
        .flash_io_di       (flash_io_di)
    );

    spiflash flash_model (
        .csb (flash_csb),
        .clk (flash_clk),
        .io0 (flash_io[0]),
        .io1 (flash_io[1]),
        .io2 (flash_io[2]),
        .io3 (flash_io[3])
    );

    // Consume the table through the same synchronous read port used by
    // cam_init. Selected entries span every firmware table block; this also
    // gives the request/acknowledge CDC bridge a realistic busy/done cycle.
    reg [8:0] camera_cfg_read_index = 9'd0;
    reg       camera_cfg_sample_ready = 1'b0;
    reg       camera_cfg_table_verified = 1'b0;
    reg       camera_cfg_is_color_patch = 1'b0;
    integer   camera_cfg_apply_count = 0;

    task verify_camera_config_entry;
        input [8:0] which;
        input [15:0] value;
        begin
            if (camera_cfg_is_color_patch) begin
                case (which)
                    9'd0: if (value !== 16'h3DC0)
                              $fatal(1, "FAIL: vivid[0]=%04x", value);
                    9'd1: if (value !== 16'h4138)
                              $fatal(1, "FAIL: vivid[1]=%04x", value);
                    9'd2: if (value !== 16'h4FFF)
                              $fatal(1, "FAIL: vivid[2]=%04x", value);
                    9'd3: if (value !== 16'h50FF)
                              $fatal(1, "FAIL: vivid[3]=%04x", value);
                    9'd4: if (value !== 16'h5100)
                              $fatal(1, "FAIL: vivid[4]=%04x", value);
                    9'd5: if (value !== 16'h525C)
                              $fatal(1, "FAIL: vivid[5]=%04x", value);
                    9'd6: if (value !== 16'h53FB)
                              $fatal(1, "FAIL: vivid[6]=%04x", value);
                    9'd7: if (value !== 16'h54FF)
                              $fatal(1, "FAIL: vivid[7]=%04x", value);
                    9'd8: if (value !== 16'h589E)
                              $fatal(1, "FAIL: vivid[8]=%04x", value);
                    default:
                        $fatal(1, "FAIL: unexpected vivid index %0d", which);
                endcase
            end else begin
                case (which)
                    9'd0:   if (value !== 16'h1280)
                                $fatal(1, "FAIL: config[0]=%04x", value);
                    9'd1:   if (value !== 16'h1280)
                                $fatal(1, "FAIL: config[1]=%04x", value);
                    9'd2:   if (value !== 16'h1214)
                                $fatal(1, "FAIL: config[2]=%04x", value);
                    9'd60:  if (value !== 16'hA202)
                                $fatal(1, "FAIL: config[60]=%04x", value);
                    9'd61:  if (value !== 16'h2495)
                                $fatal(1, "FAIL: config[61]=%04x", value);
                    9'd117: if (value !== 16'h89E8)
                                $fatal(1, "FAIL: config[117]=%04x", value);
                    default: begin end
                endcase
            end
        end
    endtask

    always @(posedge camera_cfg_clk) begin
        if (!resetn) begin
            camera_cfg_addr           <= 8'd0;
            camera_cfg_busy           <= 1'b0;
            camera_cfg_done           <= 1'b0;
            camera_cfg_index          <= 9'd0;
            camera_cfg_read_index     <= 9'd0;
            camera_cfg_sample_ready   <= 1'b0;
            camera_cfg_table_verified <= 1'b0;
            camera_cfg_is_color_patch <= 1'b0;
            camera_cfg_apply_count    <= 0;
        end else if (camera_cfg_start) begin
            if (camera_cfg_busy)
                $fatal(1, "FAIL: camera configuration restarted while busy");

            case (camera_cfg_apply_count)
                0: if (camera_cfg_count !== 9'd118)
                       $fatal(1, "FAIL: default requested %0d entries",
                              camera_cfg_count);
                1: if (camera_cfg_count !== 9'd9)
                       $fatal(1, "FAIL: vivid requested %0d entries",
                              camera_cfg_count);
                default:
                    $fatal(1, "FAIL: unexpected camera APPLY %0d",
                           camera_cfg_apply_count + 1);
            endcase

            camera_cfg_addr         <= 8'd0;
            camera_cfg_busy         <= 1'b1;
            camera_cfg_done         <= 1'b0;
            camera_cfg_index        <= 9'd0;
            camera_cfg_read_index   <= 9'd0;
            camera_cfg_sample_ready <= 1'b0;
            camera_cfg_table_verified <= 1'b0;
            camera_cfg_is_color_patch <= (camera_cfg_apply_count == 1);
            camera_cfg_apply_count  <= camera_cfg_apply_count + 1;
        end else if (camera_cfg_busy) begin
            if (!camera_cfg_sample_ready) begin
                camera_cfg_sample_ready <= 1'b1;
            end else begin
                verify_camera_config_entry(camera_cfg_read_index,
                                           camera_cfg_data);

                if (camera_cfg_read_index + 9'd1 ==
                    camera_cfg_count) begin
                    camera_cfg_busy           <= 1'b0;
                    camera_cfg_done           <= 1'b1;
                    camera_cfg_index          <= camera_cfg_count;
                    camera_cfg_table_verified <= 1'b1;
                end else begin
                    camera_cfg_read_index <= camera_cfg_read_index + 9'd1;
                    camera_cfg_index      <= camera_cfg_read_index + 9'd1;
                    camera_cfg_addr       <= camera_cfg_read_index[7:0] + 8'd1;
                    camera_cfg_sample_ready <= 1'b0;
                end
            end
        end
    end

    // Hold the video-side quiesce input low after APPLY crosses domains.
    // The bridge must retain the request without starting cam_init early.
    initial begin
        wait (resetn === 1'b1);
        wait (camera_cfg_pending === 1'b1);
        repeat (8) begin
            @(negedge camera_cfg_clk);
            if (camera_cfg_start)
                $fatal(1, "FAIL: camera configuration started before safe");
        end
        camera_cfg_safe = 1'b1;
    end

    // The simulation firmware is compiled with UART_CLKDIV=2, giving four
    // testbench clock cycles per serial bit. Physical firmware still uses 85.
    localparam integer UART_HALF_CYCLES = 2;
    reg [7:0] uart_byte;
    reg enter_prompt_started = 1'b0;
    reg command_prompt_seen = 1'b0;

    task uart_send;
        input [7:0] value;
        integer tx_bit;
        begin
            uart_rx = 1'b0;
            repeat (2*UART_HALF_CYCLES) @(posedge clk);
            for (tx_bit = 0; tx_bit < 8; tx_bit = tx_bit + 1) begin
                uart_rx = value[tx_bit];
                repeat (2*UART_HALF_CYCLES) @(posedge clk);
            end
            uart_rx = 1'b1;
            repeat (2*UART_HALF_CYCLES) @(posedge clk);
        end
    endtask

    // Decode firmware UART output using the same sampling strategy as the
    // upstream PicoSoC iCEBreaker testbench.
    initial begin
        integer rx_bit;
        forever begin
            @(negedge uart_tx);
            repeat (UART_HALF_CYCLES) @(posedge clk);
            for (rx_bit = 0; rx_bit < 8; rx_bit = rx_bit + 1) begin
                repeat (UART_HALF_CYCLES) @(posedge clk);
                repeat (UART_HALF_CYCLES) @(posedge clk);
                uart_byte = {uart_tx, uart_byte[7:1]};
            end
            repeat (2*UART_HALF_CYCLES) @(posedge clk);

            if (uart_byte == "P")
                enter_prompt_started = 1'b1;
            if (uart_byte == ">")
                command_prompt_seen = 1'b1;
        end
    end

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("build/firmware_tb.vcd");
            $dumpvars(0, testbench);
        end

        repeat (20) @(posedge clk);
        resetn = 1'b1;

`ifdef FIRMWARE_SMOKE_TEST
        wait ((encrypt_requested === 1'b1) &&
              (camera_cfg_table_verified === 1'b1));
        $display("PASS: synthesized firmware staged/applied camera config and set encryption");
        $finish;
`else
        // Queue ENTER while the first prompt is still being transmitted.
        wait (enter_prompt_started);
        uart_send(8'h0d);

        // Apply the vivid colour patch through firmware, MMIO, and the
        // asynchronous request/acknowledge bridge before changing video mode.
        wait (command_prompt_seen);
        uart_send("V");
        wait ((camera_cfg_apply_count >= 2) &&
              (camera_cfg_table_verified === 1'b1));

        uart_send("E");

        wait ((encrypt_requested === 1'b1) &&
              (camera_cfg_table_verified === 1'b1) &&
              (camera_cfg_apply_count >= 2));
        $display("PASS: firmware applied vivid colour preset and set encryption");
        $finish;
`endif
    end

    always @(posedge clk) begin
        if (resetn && cpu_trap)
            $fatal(1, "FAIL: PicoRV32 trapped while running firmware");
    end

    initial begin
        repeat (20_000_000) @(posedge clk);
        $fatal(1, "FAIL: firmware/MMIO simulation timeout");
    end
endmodule

`default_nettype wire
