`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// frame_stream_gate.v
//
// Accept a camera frame only when the display is ready to start it.
//
// If a camera frame arrives while the display is still draining the previous
// one, preserve the FIFO contents needed to finish that transfer and suppress
// every pixel from the newly rejected frame.  The next frame arriving after
// the display becomes ready is accepted atomically: frame_sync_o flushes the
// stale FIFO contents, restarts the display window, and enables its pixels.
// ============================================================================
module frame_stream_gate (
    input  wire clk,
    input  wire rst,

    input  wire frame_sync_i,
    input  wire frame_ready_i,
    input  wire pixel_valid_i,

    output reg  frame_sync_o,
    output wire pixel_valid_o,
    output reg  drop_error
);
    reg frame_active;

    // Suppress defensive boundary-cycle pixels as well.  Normal OV7670 timing
    // keeps HREF low during VSYNC, but this makes the boundary unambiguous.
    assign pixel_valid_o = pixel_valid_i && frame_active &&
                           !frame_sync_i && !frame_sync_o;

    always @(posedge clk) begin
        if (rst) begin
            frame_sync_o <= 1'b0;
            frame_active <= 1'b0;
            drop_error   <= 1'b0;
        end else begin
            // Register the accepted boundary.  Besides making acceptance
            // atomic, this keeps the display state out of the seed/FIFO
            // control timing paths.
            frame_sync_o <= frame_sync_i && frame_ready_i;

            if (frame_sync_i) begin
                frame_active <= frame_ready_i;
                if (!frame_ready_i)
                    drop_error <= 1'b1;
            end
        end
    end
endmodule
`default_nettype wire
