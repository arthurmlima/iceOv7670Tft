`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// xormap_32.v
//
// Iterative 32-bit XOR map supplied for the camera encryption stage.
//
// The original generated form expressed every next-state bit as an XOR of
// pairwise terms.  The equations below are the exact GF(2)-reduced form of
// that network: duplicate terms cancel, while the state transition, load/en
// priority, output fold, and busy behavior remain unchanged.
// ============================================================================
module xormap_32 (
    input  wire        clk,
    input  wire        rst,
    input  wire        load,
    input  wire        en,
    input  wire [31:0] a,
    output wire [15:0] y,
    output wire        busy
);
    reg  [31:0] x_reg  = 32'h0000_0000;
    reg         seeded = 1'b0;
    wire [31:0] x_next;

    assign x_next[0]  =  ^x_reg[31:16];
    assign x_next[1]  = (^x_reg[31:15]) ^ x_reg[23];
    assign x_next[2]  =  ^x_reg[31:14];
    assign x_next[3]  = (^x_reg[31:13]) ^ x_reg[22];
    assign x_next[4]  =  ^x_reg[31:12];
    assign x_next[5]  = (^x_reg[31:11]) ^ x_reg[21];
    assign x_next[6]  =  ^x_reg[31:10];
    assign x_next[7]  = (^x_reg[31:9])  ^ x_reg[20];
    assign x_next[8]  =  ^x_reg[31:8];
    assign x_next[9]  = (^x_reg[31:7])  ^ x_reg[19];
    assign x_next[10] =  ^x_reg[31:6];
    assign x_next[11] = (^x_reg[31:5])  ^ x_reg[18];
    assign x_next[12] =  ^x_reg[31:4];
    assign x_next[13] = (^x_reg[31:3])  ^ x_reg[17];
    assign x_next[14] =  ^x_reg[31:2];
    assign x_next[15] = (^x_reg[31:1])  ^ x_reg[16];
    assign x_next[16] =  ^x_reg[31:0];
    assign x_next[17] = (^x_reg[30:0])  ^ x_reg[15];
    assign x_next[18] =  ^x_reg[29:0];
    assign x_next[19] = (^x_reg[28:0])  ^ x_reg[14];
    assign x_next[20] =  ^x_reg[27:0];
    assign x_next[21] = (^x_reg[26:0])  ^ x_reg[13];
    assign x_next[22] =  ^x_reg[25:0];
    assign x_next[23] = (^x_reg[24:0])  ^ x_reg[12];
    assign x_next[24] =  ^x_reg[23:0];
    assign x_next[25] = (^x_reg[22:0])  ^ x_reg[11];
    assign x_next[26] =  ^x_reg[21:0];
    assign x_next[27] = (^x_reg[20:0])  ^ x_reg[10];
    assign x_next[28] =  ^x_reg[19:0];
    assign x_next[29] = (^x_reg[18:0])  ^ x_reg[9];
    assign x_next[30] =  ^x_reg[17:0];
    assign x_next[31] = (^x_reg[16:0])  ^ x_reg[8];

    always @(posedge clk) begin
        if (rst) begin
            x_reg  <= 32'h0000_0000;
            seeded <= 1'b0;
        end else if (load) begin
            x_reg  <= a;
            seeded <= 1'b1;
        end else if (en && seeded) begin
            x_reg <= x_next;
        end
    end

    assign y    = x_reg[15:0] ^ x_reg[31:16];
    assign busy = seeded;
endmodule
`default_nettype wire
