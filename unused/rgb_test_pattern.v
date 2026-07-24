`timescale 1ns / 1ps
// Registered RGB565 test-pattern generator for iCE40 timing closure.
module rgb_test_pattern #(
    parameter integer WIDTH  = 240,
    parameter integer HEIGHT = 280,
    parameter integer XW     = 8,
    parameter integer YW     = 9
)(
    input  wire          clk,
    input  wire [XW-1:0] x,
    input  wire [YW-1:0] y,
    input  wire [1:0]    mode,
    input  wire [7:0]    frame,
    output reg  [15:0]   color
);
    localparam [15:0] C_BLACK   = 16'h0000;
    localparam [15:0] C_BLUE    = 16'h001F;
    localparam [15:0] C_GREEN   = 16'h07E0;
    localparam [15:0] C_CYAN    = 16'h07FF;
    localparam [15:0] C_RED     = 16'hF800;
    localparam [15:0] C_MAGENTA = 16'hF81F;
    localparam [15:0] C_YELLOW  = 16'hFFE0;
    localparam [15:0] C_WHITE   = 16'hFFFF;
    localparam [15:0] C_DGRAY   = 16'h4208;

    localparam integer B1 = WIDTH/8;
    localparam integer B2 = 2*WIDTH/8;
    localparam integer B3 = 3*WIDTH/8;
    localparam integer B4 = 4*WIDTH/8;
    localparam integer B5 = 5*WIDTH/8;
    localparam integer B6 = 6*WIDTH/8;
    localparam integer B7 = 7*WIDTH/8;
    localparam integer H1 = HEIGHT/3;
    localparam integer H2 = 2*HEIGHT/3;

    wire [15:0] x16 = {{(16-XW){1'b0}}, x};
    wire [15:0] y16 = {{(16-YW){1'b0}}, y};
    reg [15:0] next_color;
    reg [15:0] solid;

    always @(*) begin
        case (frame[5:3])
            3'd0: solid = C_RED;
            3'd1: solid = C_GREEN;
            3'd2: solid = C_BLUE;
            3'd3: solid = C_WHITE;
            3'd4: solid = C_BLACK;
            3'd5: solid = C_YELLOW;
            3'd6: solid = C_CYAN;
            default: solid = C_MAGENTA;
        endcase
    end

    always @(*) begin
        next_color = C_BLACK;
        case (mode)
            2'd0: begin
                if      (x16 < B1) next_color = C_WHITE;
                else if (x16 < B2) next_color = C_YELLOW;
                else if (x16 < B3) next_color = C_CYAN;
                else if (x16 < B4) next_color = C_GREEN;
                else if (x16 < B5) next_color = C_MAGENTA;
                else if (x16 < B6) next_color = C_RED;
                else if (x16 < B7) next_color = C_BLUE;
                else               next_color = C_BLACK;
            end
            2'd1: next_color = solid;
            2'd2: begin
                if      (y16 < H1) next_color = {x16[7:3], 6'd0, 5'd0};
                else if (y16 < H2) next_color = {5'd0, x16[7:2], 5'd0};
                else               next_color = {5'd0, 6'd0, x16[7:3]};
            end
            default: begin
                if (x16 < 8 && y16 < 8)
                    next_color = C_RED;
                else if (x16 == 0 || y16 == 0 ||
                         x16 == WIDTH-1 || y16 == HEIGHT-1)
                    next_color = C_WHITE;
                else if (x16[3:0] == 0 || y16[3:0] == 0)
                    next_color = C_DGRAY;
                else
                    next_color = C_BLACK;
            end
        endcase
    end

    always @(posedge clk)
        color <= next_color;
endmodule
