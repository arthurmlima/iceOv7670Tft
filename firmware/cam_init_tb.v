/*
 * Programmable cam_init regression.
 *
 * Verifies that the SCCB engine consumes a synchronous external table,
 * transmits packed {register,value} entries in order, gives a COM7 reset its
 * long delay based on entry contents (not table position), and can be applied
 * again without a global reset.
 */
`timescale 1 ns / 1 ps
`default_nettype none

module testbench;
    reg clk = 1'b0;
    always #5 clk = !clk;

    reg rst = 1'b1;
    reg start = 1'b0;
    reg [8:0] entry_count = 9'd0;
    wire [7:0] entry_addr;
    reg [15:0] entry_data;
    wire busy;
    wire done;
    wire [8:0] entry_index;
    wire sioc;
    wire siod_low;

    reg [15:0] config_mem [0:255];

    // Model the synchronous read port of the inferred iCE40 EBR.
    always @(posedge clk)
        entry_data <= config_mem[entry_addr];

    cam_init #(
        .TICK_DIV   (2),
        .BOOT_TICKS (3),
        .GAP_TICKS  (2),
        .RST_TICKS  (5)
    ) dut (
        .clk         (clk),
        .rst         (rst),
        .start       (start),
        .entry_count (entry_count),
        .entry_addr  (entry_addr),
        .entry_data  (entry_data),
        .busy        (busy),
        .done        (done),
        .entry_index (entry_index),
        .sioc        (sioc),
        .siod_low    (siod_low)
    );

    integer transfer_count = 0;
    integer bit_count = 0;
    reg in_transfer = 1'b0;
    reg [26:0] received_bits = 27'd0;
    reg [26:0] completed_bits;
    reg [15:0] expected_entry;
    time first_start_time;
    time second_start_time;
    time third_start_time;

    function [15:0] expected_for_transfer;
        input integer which;
        integer table_index;
        begin
            case (which)
                0: expected_for_transfer = 16'h1214;
                1: expected_for_transfer = 16'h1280;
                2: expected_for_transfer = 16'h1101;
                3: expected_for_transfer = 16'h40D0;
                4: expected_for_transfer = 16'h8C00;
                default: begin
                    if ((which >= 5) && (which < 261)) begin
                        table_index = which - 5;
                        expected_for_transfer = {
                            table_index[7:0],
                            table_index[7:0] ^ 8'hA5
                        };
                    end else begin
                        expected_for_transfer = 16'hxxxx;
                    end
                end
            endcase
        end
    endfunction

    // START is the only SIOD falling transition (siod_low rising) while SIOC
    // is high. Data-zero and STOP transitions happen while SIOC is low.
    always @(posedge siod_low) begin
        if (sioc && busy) begin
            in_transfer  = 1'b1;
            bit_count    = 0;
            received_bits = 27'd0;

            case (transfer_count)
                0: first_start_time  = $time;
                1: second_start_time = $time;
                2: third_start_time  = $time;
                default: begin end
            endcase
        end
    end

    always @(posedge sioc) begin
        if (in_transfer) begin
            completed_bits = {received_bits[25:0], ~siod_low};
            received_bits  = completed_bits;

            if (bit_count == 26) begin
                expected_entry = expected_for_transfer(transfer_count);
                if (completed_bits !==
                    {8'h42, 1'b1, expected_entry[15:8], 1'b1,
                     expected_entry[7:0], 1'b1})
                    $fatal(1,
                           "FAIL: transfer %0d got %07x expected entry %04x",
                           transfer_count, completed_bits, expected_entry);

                transfer_count = transfer_count + 1;
                in_transfer = 1'b0;
            end else begin
                bit_count = bit_count + 1;
            end
        end
    end

    task pulse_start;
        input [8:0] count;
        begin
            @(negedge clk);
            entry_count = count;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    integer init_index;

    initial begin
        config_mem[0] = 16'h1214;
        config_mem[1] = 16'h1280; // reset deliberately not at index zero
        config_mem[2] = 16'h1101;

        repeat (3) @(posedge clk);
        rst = 1'b0;

        pulse_start(9'd3);
        wait (busy === 1'b1);
        if (done !== 1'b0)
            $fatal(1, "FAIL: done did not clear on first APPLY");
        wait (done === 1'b1);

        if (transfer_count != 3 || entry_index != 9'd3)
            $fatal(1, "FAIL: first APPLY sent %0d entries, index=%0d",
                   transfer_count, entry_index);

        if ((third_start_time - second_start_time) <=
            (second_start_time - first_start_time))
            $fatal(1, "FAIL: COM7 reset did not receive the longer gap");

        config_mem[0] = 16'h40D0;
        config_mem[1] = 16'h8C00;

        pulse_start(9'd2);
        wait (busy === 1'b1);
        if (done !== 1'b0)
            $fatal(1, "FAIL: done did not clear on repeated APPLY");
        wait (done === 1'b1);

        if (transfer_count != 5 || entry_index != 9'd2)
            $fatal(1, "FAIL: repeated APPLY sent %0d total entries, index=%0d",
                   transfer_count, entry_index);

        // Exercise the 9-bit count boundary: 9'h100 means all 256 slots,
        // with no address-zero retransmission at the terminal comparison.
        for (init_index = 0; init_index < 256;
             init_index = init_index + 1)
            config_mem[init_index] = {
                init_index[7:0],
                init_index[7:0] ^ 8'hA5
            };

        pulse_start(9'd256);
        wait (busy === 1'b1);
        wait (done === 1'b1);

        if (transfer_count != 261 || entry_index != 9'd256)
            $fatal(1, "FAIL: 256-entry APPLY ended at transfers=%0d index=%0d",
                   transfer_count, entry_index);

        // Invalid 257..511 counts fail closed as an empty transaction rather
        // than wrapping the 8-bit EBR address and retransmitting slot zero.
        pulse_start(9'd257);
        wait (busy === 1'b1);
        wait (done === 1'b1);

        if (transfer_count != 261 || entry_index != 9'd0)
            $fatal(1, "FAIL: invalid count transmitted wrapped entries");

        $display("PASS: programmable cam_init table, re-apply, and count bounds");
        $finish;
    end

    initial begin
        repeat (200000) @(posedge clk);
        $fatal(1, "FAIL: programmable cam_init simulation timeout");
    end
endmodule

`default_nettype wire
