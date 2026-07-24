`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// pixel_xor_stage.v
//
// Frame-seeded, one-word-per-pixel XOR stage for the camera stream.
//
// An accepted encrypted-frame boundary loads the current 32-bit pseudo-random
// seed into xormap_32 and advances the seed generator for the following frame.
// Each valid RGB565 pixel is XORed with the fold of the current map state;
// xormap_32 advances after that pixel is sampled.  The mode request is latched
// only at an accepted frame boundary, so a button press cannot produce a
// partly encrypted frame.
// ============================================================================
module pixel_xor_stage #(
    parameter integer ENABLE_XORMAP      = 1,
    parameter integer ENCRYPTION_DEFAULT = 0,
    parameter [31:0]  INITIAL_SEED       = 32'h1ACE_B00C
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_sync,
    input  wire        enable_i,
    input  wire [15:0] pixel_i,
    input  wire        pixel_valid_i,

    output wire [15:0] pixel_o,
    output wire        pixel_valid_o,
    output wire        encrypt_active
);
    assign pixel_valid_o = pixel_valid_i;

    generate
        if (ENABLE_XORMAP != 0) begin : g_xormap
            localparam [31:0] SEED_RESET =
                (INITIAL_SEED == 32'h0000_0000)
                    ? 32'h0000_0001 : INITIAL_SEED;

            reg  [31:0] seed_state;
            reg         encrypt_frame;
            wire        seed_feedback;
            wire [15:0] xor_mask;
            wire        map_busy;
            wire        map_load;
            wire        map_step;

            // x^32 + x^22 + x^2 + x + 1, once per accepted frame.
            assign seed_feedback = seed_state[31] ^ seed_state[21] ^
                                   seed_state[1]  ^ seed_state[0];

            always @(posedge clk) begin
                if (rst) begin
                    seed_state   <= SEED_RESET;
                    encrypt_frame <= (ENCRYPTION_DEFAULT != 0);
                end else if (frame_sync) begin
                    // xormap_32 sees the pre-update seed_state on this edge.
                    seed_state <= {seed_state[30:0], seed_feedback};
                    encrypt_frame <= enable_i;
                end
            end

            xormap_32 map (
                .clk  (clk),
                .rst  (rst),
                .load (map_load),
                .en   (map_step),
                .a    (seed_state),
                .y    (xor_mask),
                .busy (map_busy)
            );

            assign encrypt_active = encrypt_frame && map_busy;
            assign map_load = frame_sync && enable_i;
            assign map_step = pixel_valid_i && encrypt_frame;
            assign pixel_o = encrypt_active
                           ? (pixel_i ^ xor_mask)
                           : pixel_i;
        end else begin : g_bypass
            assign encrypt_active = 1'b0;
            assign pixel_o        = pixel_i;
        end
    endgenerate
endmodule
`default_nettype wire
