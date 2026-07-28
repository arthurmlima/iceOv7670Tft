`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// status_led.v
//
// The dock has exactly two usable LEDs, which is not enough to say "on" or
// "off" and expect that to localise a fault.  This turns them into two
// distinguishable signals instead:
//
//   READY LED (E8)
//     short pulse every 1.5 s - alive, but SCCB config and/or panel init not
//                         done.  Deliberately slow and asymmetric so it cannot
//                         be mistaken for the per-frame flicker below.
//     rapid flicker     - frames are completing (it toggles once per frame,
//                         so ~6 Hz at 12.5 fps)
//     steady on or off  - initialisation finished but frames are NOT
//                         completing; the panel stream is stalled
//
//   DONE LED (D7)
//     off               - no fault latched
//     N blinks, pause   - the first fault that latched, by index:
//                           1  FIFO overflow    (camera outran the panel)
//                           2  FIFO underflow   (panel read an empty FIFO)
//                           3  frame starved    (pixels stopped mid-frame)
//                           4  LCD sync error   (VSYNC during a transfer)
//                           5  frame dropped    (panel still busy at VSYNC)
//
// Only the *first* fault is reported, and the indices are ordered so that root
// causes blink fewer times than their consequences: a starved or overrunning
// camera (1-3) will also produce sync errors and dropped frames (4-5), so
// seeing 4 or 5 on its own means something different from seeing them after 1.
// ============================================================================
module status_led #(
    parameter integer CLK_HZ    = 40000000,
    parameter integer N_FAULTS  = 5,
    parameter integer BLINK_MS  = 160,   // on/off time of one code blink
    parameter integer GAP_MS    = 900    // quiet time between code repeats
)(
    input  wire                clk,
    input  wire                rst,

    input  wire                ready,        // both initialisers finished
    input  wire                frame_done,   // one pulse per completed frame
    input  wire [N_FAULTS-1:0] faults,       // sticky, bit 0 = highest priority

    output reg                 led_ready,
    output reg                 led_fault
);
    localparam integer MS_DIV = (CLK_HZ/1000 < 2) ? 2 : CLK_HZ/1000;
    localparam integer MSW    = $clog2(MS_DIV);

    reg [MSW-1:0] ms_div = {MSW{1'b0}};
    wire ms_tick = (ms_div == MS_DIV-1);

    always @(posedge clk) begin
        if (rst) ms_div <= {MSW{1'b0}};
        else     ms_div <= ms_tick ? {MSW{1'b0}} : ms_div + 1'b1;
    end

    // ---------------- READY: heartbeat or per-frame toggle ----------------
    // A 50% square wave here would be ambiguous: at low frame rates the
    // per-frame toggle is only a few Hz and looks similar.  A short pulse on a
    // long period is unmistakable at a glance.
    localparam integer HB_PERIOD_MS = 1500;
    localparam integer HB_ON_MS     = 200;
    localparam integer HBW          = $clog2(HB_PERIOD_MS);

    reg [HBW-1:0] heartbeat = {HBW{1'b0}};

    always @(posedge clk) begin
        if (rst) begin
            heartbeat <= {HBW{1'b0}};
            led_ready <= 1'b0;
        end else if (!ready) begin
            if (ms_tick)
                heartbeat <= (heartbeat >= HB_PERIOD_MS-1) ? {HBW{1'b0}}
                                                           : heartbeat + 1'b1;
            led_ready <= (heartbeat < HB_ON_MS);
        end else begin
            heartbeat <= {HBW{1'b0}};
            if (frame_done)
                led_ready <= ~led_ready;
        end
    end

    // ---------------- FAULT: blink the first latched fault index ----------
    localparam integer CODEW = $clog2(N_FAULTS+1);

    reg [CODEW-1:0] code = {CODEW{1'b0}};   // 0 = none, else 1..N_FAULTS
    integer i;

    always @(posedge clk) begin
        if (rst) begin
            code <= {CODEW{1'b0}};
        end else if (code == {CODEW{1'b0}}) begin
            // Priority encoder, lowest set bit wins, captured once.
            for (i = N_FAULTS-1; i >= 0; i = i - 1)
                if (faults[i]) code <= i[CODEW-1:0] + 1'b1;
        end
    end

    localparam integer PHASEW = $clog2((GAP_MS > BLINK_MS ? GAP_MS : BLINK_MS)+1);

    reg [PHASEW-1:0] phase_ms = {PHASEW{1'b0}};
    reg [CODEW-1:0]  blinks_left = {CODEW{1'b0}};
    reg              in_gap = 1'b1;

    always @(posedge clk) begin
        if (rst) begin
            phase_ms    <= {PHASEW{1'b0}};
            blinks_left <= {CODEW{1'b0}};
            in_gap      <= 1'b1;
            led_fault   <= 1'b0;
        end else if (code == {CODEW{1'b0}}) begin
            led_fault <= 1'b0;
            in_gap    <= 1'b1;
            phase_ms  <= {PHASEW{1'b0}};
        end else if (ms_tick) begin
            if (in_gap) begin
                if (phase_ms >= GAP_MS-1) begin
                    phase_ms    <= {PHASEW{1'b0}};
                    in_gap      <= 1'b0;
                    blinks_left <= code;
                    led_fault   <= 1'b1;
                end else begin
                    phase_ms <= phase_ms + 1'b1;
                end
            end else if (phase_ms >= BLINK_MS-1) begin
                phase_ms <= {PHASEW{1'b0}};
                if (led_fault) begin
                    // End of an "on" blink.
                    led_fault   <= 1'b0;
                    blinks_left <= blinks_left - 1'b1;
                    if (blinks_left <= 1)
                        in_gap <= 1'b1;
                end else begin
                    led_fault <= 1'b1;
                end
            end else begin
                phase_ms <= phase_ms + 1'b1;
            end
        end
    end
endmodule
`default_nettype wire
