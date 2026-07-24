`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// cam_init.v - SCCB (I2C-like, write-only) master for the OV7670
//
// Register/value pairs are supplied by an external synchronous memory. The
// PicoRV32 owns that memory's write port; this sequencer owns its read port.
// A table is transmitted only after start is asserted, so firmware can stage
// and apply different camera configurations without rebuilding the FPGA.
//
// Each entry is packed as {register[7:0], value[7:0]}. A 3-phase SCCB write
// is {0x42, register, value} with a released ninth/ACK bit after each byte.
// ACK is deliberately not sampled, matching the original proven sequencer.
//
// SIOC is push-pull (allowed by SCCB: the master always drives the clock).
// SIOD is open-drain: this module only says "pull low" (siod_low=1); the top
// level ties that to an SB_IO output-enable with the pin's pull-up on.
//
// At clk=39 MHz and TICK_DIV=98, a quarter tick is ~2.51 us and SIOC is
// ~99.5 kHz. BOOT_TICKS/GAP_TICKS/RST_TICKS retain the original ~10 ms,
// ~2 ms, and ~10 ms delays. Any COM7 write with reset bit 7 set receives the
// long delay, regardless of its position in a firmware-defined table.
// ============================================================================

module cam_init #(
    parameter TICK_DIV   = 98,
    parameter BOOT_TICKS = 4000,
    parameter GAP_TICKS  = 800,
    parameter RST_TICKS  = 4000
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    input  wire [8:0]  entry_count, // valid range: 1..256
    output wire [7:0]  entry_addr,
    input  wire [15:0] entry_data,

    output reg         busy,
    output reg         done,
    output wire [8:0]  entry_index,
    output reg         sioc,
    output reg         siod_low
);
    // ---------------- quarter-bit tick (~400 kHz) ----------------
    reg [$clog2(TICK_DIV)-1:0] div;
    reg tick;

    always @(posedge clk) begin
        if (rst) begin
            div  <= 0;
            tick <= 1'b0;
        end else begin
            tick <= (div == TICK_DIV - 1);
            div  <= (div == TICK_DIV - 1) ? {$clog2(TICK_DIV){1'b0}}
                                          : div + 1'b1;
        end
    end

    // ---------------- engine ----------------
    localparam ST_IDLE  = 3'd0,
               ST_BOOT  = 3'd1,
               ST_FETCH = 3'd2,
               ST_LOAD  = 3'd3,
               ST_START = 3'd4,
               ST_BITS  = 3'd5,
               ST_STOP  = 3'd6,
               ST_GAP   = 3'd7;

    reg [2:0]  state;
    reg [8:0]  idx;
    reg [8:0]  count_q;
    reg [15:0] entry_q;
    reg [26:0] sh;
    reg [4:0]  bitn;
    reg [1:0]  ph;
    reg [15:0] gap;
    reg        long_gap;

    assign entry_addr  = idx[7:0];
    assign entry_index = idx;
    wire entry_count_valid =
        (entry_count != 9'd0) &&
        (!entry_count[8] || (entry_count[7:0] == 8'd0));

    always @(posedge clk) begin
        if (rst) begin
            state     <= ST_IDLE;
            idx       <= 9'd0;
            count_q   <= 9'd0;
            entry_q   <= 16'd0;
            bitn      <= 5'd0;
            ph        <= 2'd0;
            gap       <= 16'd0;
            long_gap  <= 1'b0;
            busy      <= 1'b0;
            done      <= 1'b0;
            sioc      <= 1'b1;
            siod_low  <= 1'b0;
        end else begin
            case (state)
            ST_IDLE: begin
                sioc     <= 1'b1;
                siod_low <= 1'b0;

                if (start) begin
                    idx      <= 9'd0;
                    count_q  <= entry_count_valid ? entry_count : 9'd0;
                    gap      <= entry_count_valid ? BOOT_TICKS[15:0] :
                                                    16'd1;
                    busy     <= 1'b1;
                    done     <= 1'b0;
                    state    <= ST_BOOT;
                end
            end

            ST_BOOT: if (tick) begin
                if (gap == 16'd1)
                    state <= ST_FETCH;
                else
                    gap <= gap - 16'd1;
            end

            // The external EBR read port is synchronous. The address has
            // already been stable throughout BOOT/GAP; this extra register
            // retains the original timing-relief stage before the shifter.
            ST_FETCH: begin
                entry_q <= entry_data;
                state   <= ST_LOAD;
            end

            ST_LOAD: begin
                if (idx == count_q) begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= ST_IDLE;
                end else begin
                    long_gap <= (entry_q[15:8] == 8'h12) && entry_q[7];
                    bitn     <= 5'd26;
                    ph       <= 2'd0;
                    state    <= ST_START;
                end
            end

            // START: SIOD falls while SIOC is high, then SIOC falls.
            ST_START: if (tick) begin
                case (ph)
                    2'd0: begin
                        siod_low <= 1'b1;
                        ph       <= 2'd1;
                    end
                    default: begin
                        sioc  <= 1'b0;
                        ph    <= 2'd0;
                        state <= ST_BITS;
                    end
                endcase
            end

            // Each bit: set SIOD while SIOC low, raise SIOC, hold, drop SIOC.
            ST_BITS: if (tick) begin
                case (ph)
                    2'd0: begin
                        siod_low <= ~sh[26];
                        ph       <= 2'd1;
                    end
                    2'd1: begin
                        sioc <= 1'b1;
                        ph   <= 2'd2;
                    end
                    2'd2: ph <= 2'd3;
                    default: begin
                        sioc <= 1'b0;
                        ph   <= 2'd0;
                        if (bitn == 5'd0)
                            state <= ST_STOP;
                        else
                            bitn <= bitn - 5'd1;
                    end
                endcase
            end

            // STOP: SIOD low with SIOC low, SIOC rises, SIOD releases.
            ST_STOP: if (tick) begin
                case (ph)
                    2'd0: begin
                        siod_low <= 1'b1;
                        ph       <= 2'd1;
                    end
                    2'd1: begin
                        sioc <= 1'b1;
                        ph   <= 2'd2;
                    end
                    default: begin
                        siod_low <= 1'b0;
                        ph       <= 2'd0;
                        gap      <= long_gap ? RST_TICKS[15:0]
                                             : GAP_TICKS[15:0];
                        idx      <= idx + 9'd1;
                        state    <= ST_GAP;
                    end
                endcase
            end

            ST_GAP: if (tick) begin
                if (gap == 16'd1)
                    state <= ST_FETCH;
                else
                    gap <= gap - 16'd1;
            end

            default: begin
                state    <= ST_IDLE;
                busy     <= 1'b0;
                sioc     <= 1'b1;
                siod_low <= 1'b0;
            end
            endcase
        end
    end

    // ------------- 27-bit shift register (own always block) -------------
    // sh has exactly two enables: a shallow state decode for load and a
    // registered shift strobe. This preserves the timing structure of the
    // original implementation.
    reg sh_shift_q;

    always @(posedge clk) begin
        if (rst)
            sh_shift_q <= 1'b0;
        else
            sh_shift_q <= (state == ST_BITS) && (ph == 2'd3) &&
                          (div == TICK_DIV - 1);
    end

    always @(posedge clk) begin
        if (rst)
            sh <= 27'd0;
        else if ((state == ST_LOAD) && (idx != count_q))
            sh <= {8'h42, 1'b1, entry_q[15:8], 1'b1,
                   entry_q[7:0], 1'b1};
        else if (sh_shift_q)
            sh <= sh << 1;
    end
endmodule
`default_nettype wire
