/*
 * Firmware boot/MMIO smoke test for the camera-control PicoSoC.
 *
 * This follows the upstream PicoSoC iCEBreaker simulation style, but tests
 * this project's camera_control_soc directly. The firmware is fetched from
 * the SPI flash model at 0x0010_0000, receives ENTER and E over the UART, and
 * must set camera control bit 0 without trapping.
 */
`timescale 1 ns / 1 ps
`default_nettype none

module testbench;
    reg clk = 1'b0;
    always #5 clk = !clk;

    reg resetn = 1'b0;
    reg uart_rx = 1'b1;

    wire uart_tx;
    wire cpu_trap;
    wire encrypt_requested;

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
        wait (encrypt_requested === 1'b1);
        $display("PASS: synthesized flash firmware set camera encryption over MMIO");
        $finish;
`else
        // Queue ENTER while the first prompt is still being transmitted.
        wait (enter_prompt_started);
        uart_send(8'h0d);

        // Select the appended camera command once the menu is ready.
        wait (command_prompt_seen);
        uart_send("E");

        wait (encrypt_requested === 1'b1);
        $display("PASS: flash firmware set camera encryption over MMIO");
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
