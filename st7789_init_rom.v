`timescale 1ns / 1ps
//======================================================================
//  st7789_init_rom.v
//
//  Panel initialisation sequence for a 240x280 ST7789 IPS module,
//  transcribed byte-for-byte from ST7789_Init() in the Zynq PS
//  bare-metal driver (helloworld.c).  The hardware RES pulse is NOT in
//  here - the top level FSM drives that directly.
//
//  Entry format:  {etype[1:0], edata[7:0]}
//      T_CMD : send edata with DC = 0   (command)
//      T_DAT : send edata with DC = 1   (parameter)
//      T_DLY : do not send anything, wait edata milliseconds (max 255)
//      T_END : sequence finished
//
//  Pure combinational ROM - infers as LUT ROM in Vivado.
//======================================================================
module st7789_init_rom #(
    parameter [7:0] MADCTL_VAL = 8'hC0      // 0xC0 = MX | MY | RGB  (ROTATION 2)
)(
    input  wire [6:0] addr,
    output wire [1:0] etype,
    output wire [7:0] edata
);
    localparam [1:0] T_CMD = 2'b00,
                     T_DAT = 2'b01,
                     T_DLY = 2'b10,
                     T_END = 2'b11;

    localparam integer N_ENTRIES = 66;

    reg [9:0] entry;

    assign etype = entry[9:8];
    assign edata = entry[7:0];

    always @(*) begin
        case (addr)
            7'd0  : entry = {T_CMD, 8'h01};                // SWRESET
            7'd1  : entry = {T_DLY, 8'd150};               // wait 150 ms
            7'd2  : entry = {T_CMD, 8'h11};                // SLPOUT
            7'd3  : entry = {T_DLY, 8'd120};               // wait 120 ms
            7'd4  : entry = {T_CMD, 8'h3A};                // COLMOD
            7'd5  : entry = {T_DAT, 8'h55};                // RGB565 (16 bpp)
            7'd6  : entry = {T_CMD, 8'hB2};                // PORCTRL
            7'd7  : entry = {T_DAT, 8'h0C};                // porch control
            7'd8  : entry = {T_DAT, 8'h0C};
            7'd9  : entry = {T_DAT, 8'h00};
            7'd10 : entry = {T_DAT, 8'h33};
            7'd11 : entry = {T_DAT, 8'h33};
            7'd12 : entry = {T_CMD, 8'h36};                // MADCTL
            7'd13 : entry = {T_DAT, MADCTL_VAL};           // rotation 2 = MX|MY|RGB = 0xC0
            7'd14 : entry = {T_CMD, 8'hB7};                // GCTRL
            7'd15 : entry = {T_DAT, 8'h35};                // gate control
            7'd16 : entry = {T_CMD, 8'hBB};                // VCOMS
            7'd17 : entry = {T_DAT, 8'h19};                // VCOM setting
            7'd18 : entry = {T_CMD, 8'hC0};                // LCMCTRL
            7'd19 : entry = {T_DAT, 8'h2C};
            7'd20 : entry = {T_CMD, 8'hC2};                // VDVVRHEN
            7'd21 : entry = {T_DAT, 8'h01};
            7'd22 : entry = {T_CMD, 8'hC3};                // VRHS
            7'd23 : entry = {T_DAT, 8'h12};
            7'd24 : entry = {T_CMD, 8'hC4};                // VDVS
            7'd25 : entry = {T_DAT, 8'h20};
            7'd26 : entry = {T_CMD, 8'hC6};                // FRCTRL2
            7'd27 : entry = {T_DAT, 8'h0F};                // 60 Hz frame rate
            7'd28 : entry = {T_CMD, 8'hD0};                // PWCTRL1
            7'd29 : entry = {T_DAT, 8'hA4};
            7'd30 : entry = {T_DAT, 8'hA1};
            7'd31 : entry = {T_CMD, 8'hE0};                // PVGAMCTRL
            7'd32 : entry = {T_DAT, 8'hD0};                // positive gamma
            7'd33 : entry = {T_DAT, 8'h04};
            7'd34 : entry = {T_DAT, 8'h0D};
            7'd35 : entry = {T_DAT, 8'h11};
            7'd36 : entry = {T_DAT, 8'h13};
            7'd37 : entry = {T_DAT, 8'h2B};
            7'd38 : entry = {T_DAT, 8'h3F};
            7'd39 : entry = {T_DAT, 8'h54};
            7'd40 : entry = {T_DAT, 8'h4C};
            7'd41 : entry = {T_DAT, 8'h18};
            7'd42 : entry = {T_DAT, 8'h0D};
            7'd43 : entry = {T_DAT, 8'h0B};
            7'd44 : entry = {T_DAT, 8'h1F};
            7'd45 : entry = {T_DAT, 8'h23};
            7'd46 : entry = {T_CMD, 8'hE1};                // NVGAMCTRL
            7'd47 : entry = {T_DAT, 8'hD0};                // negative gamma
            7'd48 : entry = {T_DAT, 8'h04};
            7'd49 : entry = {T_DAT, 8'h0C};
            7'd50 : entry = {T_DAT, 8'h11};
            7'd51 : entry = {T_DAT, 8'h13};
            7'd52 : entry = {T_DAT, 8'h2C};
            7'd53 : entry = {T_DAT, 8'h3F};
            7'd54 : entry = {T_DAT, 8'h44};
            7'd55 : entry = {T_DAT, 8'h51};
            7'd56 : entry = {T_DAT, 8'h2F};
            7'd57 : entry = {T_DAT, 8'h1F};
            7'd58 : entry = {T_DAT, 8'h1F};
            7'd59 : entry = {T_DAT, 8'h20};
            7'd60 : entry = {T_DAT, 8'h23};
            7'd61 : entry = {T_CMD, 8'h21};                // INVON  - IPS panel needs inversion ON
            7'd62 : entry = {T_CMD, 8'h13};                // NORON
            7'd63 : entry = {T_CMD, 8'h29};                // DISPON
            7'd64 : entry = {T_DLY, 8'd100};               // wait 100 ms
            7'd65 : entry = {T_END, 8'h00};                // end of sequence
            default: entry = {T_END, 8'h00};
        endcase
    end
endmodule
