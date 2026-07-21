// ============================================================================
// st7789_ctrl.v - complete hardware replacement for ST7789_Init() +
// the per-frame draw path. The panel's own GRAM is the framebuffer; this
// module only (1) initializes the controller, (2) opens the address window
// once per camera frame, (3) shovels pixels from the line FIFO into RAMWR.
//
// Init sequence = the proven driver, byte for byte: SWRESET, SLPOUT,
// COLMOD 16bpp, the 0xB2 porch set, MADCTL, VCOM/power regs, both gamma
// curves, INVON (this panel inverts), NORON, DISPON - with the same delays.
//
// MADCTL = 0xA0 (MY|MV): the panel runs LANDSCAPE 280x240. This is not
// cosmetic - streaming with no framebuffer requires the panel autoincrement
// axis to match the camera scan axis. Window: CASET 20..299 (the 280-glass
// sits at RAM rows 20..299), RASET 0..239. Camera QVGA lines are cropped
// 320->280 upstream, so the mapping is exactly 1:1.
// If the picture is mirrored/flipped on your unit, change ROM index 13
// to 0x4160 (MADCTL 0x60 = MX|MV, the other landscape).
//
// Frame FSM: every VSYNC (frame_sync) it clears the FIFO, re-sends
// CASET/RASET/RAMWR (11 bytes, ~4 us - vertical blanking is ~4 ms), then
// streams 280x240 = 67200 pixels. A frame_sync arriving mid-stream aborts
// and restarts, so any glitch self-heals within one frame.
//
// Rate budget (the reason spi8 must be gapless): one camera line period is
// 1568 internal-clock cycles = 9408 sys cycles, and one display line is
// 280 px x 32 cycles = 8960 sys cycles. 448 cycles/line of slack (~5%).
// The pixel feeder below (POP -> LOAD -> HI -> LO) refills the SPI skid
// buffer within 4 cycles of each 16-cycle byte slot, so the sustained rate
// is exactly 32 cycles/pixel.
//
// CS_N is tied low. Backlight stays off until init completes.
// ============================================================================

module st7789_ctrl #(
    parameter        CLK_HZ    = 48_000_000,
    parameter [16:0] PIX_TOTAL = 17'd67200     // 280 x 240
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        frame_sync,      // pulse at camera VSYNC

    // pixel FIFO (read side)
    input  wire [15:0] fifo_rdata,
    input  wire        fifo_empty,
    output reg         fifo_rd,
    output reg         fifo_clear,

    // panel
    output wire        lcd_sck,
    output wire        lcd_mosi,
    output wire        lcd_dc,
    output reg         lcd_res_n,
    output wire        lcd_cs_n,
    output reg         lcd_bl,

    output reg         init_done
);

    assign lcd_cs_n = 1'b0;

    // ---------------- SPI byte engine ----------------
    reg        tx_valid;
    reg        tx_dc;
    reg  [7:0] tx_data;
    wire       tx_ready;
    wire       spi_idle;
    wire       tx_fire = tx_valid & tx_ready;

    spi8 u_spi (
        .clk      (clk),
        .rst      (rst),
        .in_valid (tx_valid),
        .in_dc    (tx_dc),
        .in_data  (tx_data),
        .in_ready (tx_ready),
        .sck      (lcd_sck),
        .mosi     (lcd_mosi),
        .dc       (lcd_dc),
        .idle     (spi_idle)
    );

    // ---------------- millisecond tick ----------------
    localparam MS_DIV = CLK_HZ / 1000;
    reg [$clog2(MS_DIV)-1:0] ms_cnt;
    wire ms_tick = (ms_cnt == MS_DIV - 1);
    always @(posedge clk) begin
        if (rst)          ms_cnt <= 0;
        else if (ms_tick) ms_cnt <= 0;
        else              ms_cnt <= ms_cnt + 1'b1;
    end

    // ---------------- init ROM ----------------
    // entry[15:14]: 00 = command byte, 01 = data byte,
    //               10 = delay (entry[13:0] ms), 11 = end
    function [15:0] init_rom;
        input [6:0] i;
        begin
            case (i)
                7'd0 :  init_rom = 16'h0001;  // SWRESET
                7'd1 :  init_rom = 16'h8096;  // delay 150 ms
                7'd2 :  init_rom = 16'h0011;  // SLPOUT
                7'd3 :  init_rom = 16'h8078;  // delay 120 ms
                7'd4 :  init_rom = 16'h003A;  // COLMOD
                7'd5 :  init_rom = 16'h4155;  //   16 bpp
                7'd6 :  init_rom = 16'h00B2;  // PORCTRL
                7'd7 :  init_rom = 16'h410C;
                7'd8 :  init_rom = 16'h410C;
                7'd9 :  init_rom = 16'h4100;
                7'd10:  init_rom = 16'h4133;
                7'd11:  init_rom = 16'h4133;
                7'd12:  init_rom = 16'h0036;  // MADCTL
                7'd13:  init_rom = 16'h41A0;  //   0xA0 = MY|MV landscape (0x60 if mirrored)
                7'd14:  init_rom = 16'h00B7;  // GCTRL
                7'd15:  init_rom = 16'h4135;
                7'd16:  init_rom = 16'h00BB;  // VCOMS
                7'd17:  init_rom = 16'h4119;
                7'd18:  init_rom = 16'h00C0;  // LCMCTRL
                7'd19:  init_rom = 16'h412C;
                7'd20:  init_rom = 16'h00C2;  // VDVVRHEN
                7'd21:  init_rom = 16'h4101;
                7'd22:  init_rom = 16'h00C3;  // VRHS
                7'd23:  init_rom = 16'h4112;
                7'd24:  init_rom = 16'h00C4;  // VDVS
                7'd25:  init_rom = 16'h4120;
                7'd26:  init_rom = 16'h00C6;  // FRCTRL2
                7'd27:  init_rom = 16'h410F;
                7'd28:  init_rom = 16'h00D0;  // PWCTRL1
                7'd29:  init_rom = 16'h41A4;
                7'd30:  init_rom = 16'h41A1;
                7'd31:  init_rom = 16'h00E0;  // PVGAMCTRL
                7'd32:  init_rom = 16'h41D0;
                7'd33:  init_rom = 16'h4104;
                7'd34:  init_rom = 16'h410D;
                7'd35:  init_rom = 16'h4111;
                7'd36:  init_rom = 16'h4113;
                7'd37:  init_rom = 16'h412B;
                7'd38:  init_rom = 16'h413F;
                7'd39:  init_rom = 16'h4154;
                7'd40:  init_rom = 16'h414C;
                7'd41:  init_rom = 16'h4118;
                7'd42:  init_rom = 16'h410D;
                7'd43:  init_rom = 16'h410B;
                7'd44:  init_rom = 16'h411F;
                7'd45:  init_rom = 16'h4123;
                7'd46:  init_rom = 16'h00E1;  // NVGAMCTRL
                7'd47:  init_rom = 16'h41D0;
                7'd48:  init_rom = 16'h4104;
                7'd49:  init_rom = 16'h410C;
                7'd50:  init_rom = 16'h4111;
                7'd51:  init_rom = 16'h4113;
                7'd52:  init_rom = 16'h412C;
                7'd53:  init_rom = 16'h413F;
                7'd54:  init_rom = 16'h4144;
                7'd55:  init_rom = 16'h4151;
                7'd56:  init_rom = 16'h412F;
                7'd57:  init_rom = 16'h411F;
                7'd58:  init_rom = 16'h411F;
                7'd59:  init_rom = 16'h4120;
                7'd60:  init_rom = 16'h4123;
                7'd61:  init_rom = 16'h0021;  // INVON (panel is inverted)
                7'd62:  init_rom = 16'h0013;  // NORON
                7'd63:  init_rom = 16'h0029;  // DISPON
                7'd64:  init_rom = 16'h8064;  // delay 100 ms
                default: init_rom = 16'hC000; // end
            endcase
        end
    endfunction

    // ---------------- per-frame window bytes ----------------
    // bit 8 = DC (0 = command). CASET 20..299, RASET 0..239, RAMWR.
    function [8:0] win_byte;
        input [3:0] i;
        begin
            case (i)
                4'd0 :  win_byte = {1'b0, 8'h2A};  // CASET
                4'd1 :  win_byte = {1'b1, 8'h00};
                4'd2 :  win_byte = {1'b1, 8'h14};  //   20
                4'd3 :  win_byte = {1'b1, 8'h01};
                4'd4 :  win_byte = {1'b1, 8'h2B};  //   299
                4'd5 :  win_byte = {1'b0, 8'h2B};  // RASET
                4'd6 :  win_byte = {1'b1, 8'h00};
                4'd7 :  win_byte = {1'b1, 8'h00};  //   0
                4'd8 :  win_byte = {1'b1, 8'h00};
                4'd9 :  win_byte = {1'b1, 8'hEF};  //   239
                default: win_byte = {1'b0, 8'h2C}; // RAMWR
            endcase
        end
    endfunction

    // ---------------- FSM ----------------
    localparam S_RES_LOW  = 4'd0,   // hardware reset asserted, 20 ms
               S_RES_HIGH = 4'd1,   // released, 120 ms settle
               S_FETCH    = 4'd2,
               S_EXEC     = 4'd3,
               S_SEND     = 4'd4,
               S_DELAY    = 4'd5,
               S_WAIT     = 4'd6,   // idle between frames, wait for VSYNC
               S_DRAIN    = 4'd7,   // let SPI finish in-flight bytes
               S_WIN      = 4'd8,   // 11 window bytes
               S_POP      = 4'd9,
               S_LOAD     = 4'd10,  // FIFO read latency
               S_HI       = 4'd11,
               S_LO       = 4'd12;

    reg [3:0]  state;
    reg [6:0]  rom_idx;
    reg [15:0] rom_q;
    reg [13:0] delay_ms;
    reg [3:0]  win_idx;
    reg [16:0] pixcnt;

    wire [8:0] wb = win_byte(win_idx);

    // Combinational handshake outputs to the SPI engine (payloads come from
    // registered sources: rom_q, win_idx, and the FIFO's output register).
    always @* begin
        tx_valid = 1'b0;
        tx_dc    = 1'b1;
        tx_data  = 8'h00;
        case (state)
            S_SEND: begin
                tx_valid = 1'b1;
                tx_dc    = rom_q[14];         // 00=cmd -> DC 0, 01=data -> DC 1
                tx_data  = rom_q[7:0];
            end
            S_WIN: begin
                tx_valid = 1'b1;
                tx_dc    = wb[8] ? 1'b1 : 1'b0;
                tx_data  = wb[7:0];
            end
            S_HI: begin
                tx_valid = 1'b1;
                tx_dc    = 1'b1;
                tx_data  = fifo_rdata[15:8];
            end
            S_LO: begin
                tx_valid = 1'b1;
                tx_dc    = 1'b1;
                tx_data  = fifo_rdata[7:0];
            end
            default: ;
        endcase
    end

    // Restart decision is REGISTERED: frame_sync arrives at the start of
    // vertical blanking (~4 ms before pixel data), so taking it one cycle
    // late is free - and it keeps the state comparator out of the enable
    // cone of every register in the FSM (this was the critical path).
    wire in_frame_states = (state >= S_WAIT);
    reg  restart_q;
    always @(posedge clk) begin
        if (rst) restart_q <= 1'b0;
        else     restart_q <= in_frame_states & frame_sync;
    end

    always @(posedge clk) begin
        if (rst) begin
            state      <= S_RES_LOW;
            rom_idx    <= 7'd0;
            rom_q      <= 16'd0;
            delay_ms   <= 14'd20;
            win_idx    <= 4'd0;
            pixcnt     <= 17'd0;
            fifo_rd    <= 1'b0;
            fifo_clear <= 1'b0;
            lcd_res_n  <= 1'b0;
            lcd_bl     <= 1'b0;
            init_done  <= 1'b0;
        end else begin
            fifo_rd    <= 1'b0;
            fifo_clear <= 1'b0;

            // A new camera frame restarts the draw from the window commands,
            // whatever we were doing. FIFO is cleared so pixel 0 of the frame
            // lands at CASET/RASET origin - guaranteed alignment every frame.
            if (restart_q) begin
                fifo_clear <= 1'b1;
                win_idx    <= 4'd0;
                pixcnt     <= 17'd0;
                state      <= S_DRAIN;
            end else begin
                case (state)

                S_RES_LOW: begin
                    lcd_res_n <= 1'b0;
                    if (ms_tick) begin
                        if (delay_ms == 14'd1) begin
                            lcd_res_n <= 1'b1;
                            delay_ms  <= 14'd120;
                            state     <= S_RES_HIGH;
                        end else
                            delay_ms <= delay_ms - 14'd1;
                    end
                end

                S_RES_HIGH: if (ms_tick) begin
                    if (delay_ms == 14'd1) state <= S_FETCH;
                    else                   delay_ms <= delay_ms - 14'd1;
                end

                S_FETCH: begin
                    rom_q <= init_rom(rom_idx);
                    state <= S_EXEC;
                end

                S_EXEC: begin
                    case (rom_q[15:14])
                        2'b10: begin
                            delay_ms <= rom_q[13:0];
                            state    <= S_DELAY;
                        end
                        2'b11: begin
                            init_done <= 1'b1;
                            lcd_bl    <= 1'b1;
                            state     <= S_WAIT;
                        end
                        default: state <= S_SEND;
                    endcase
                end

                S_SEND: if (tx_fire) begin
                    rom_idx <= rom_idx + 7'd1;
                    state   <= S_FETCH;
                end

                S_DELAY: if (ms_tick) begin
                    if (delay_ms == 14'd1) begin
                        rom_idx <= rom_idx + 7'd1;
                        state   <= S_FETCH;
                    end else
                        delay_ms <= delay_ms - 14'd1;
                end

                S_WAIT: ;   // frame_sync handled above

                // Wait until the engine (including its skid buffer) is empty
                // so a stale byte can never leak into the command sequence.
                S_DRAIN: if (spi_idle) state <= S_WIN;

                S_WIN: if (tx_fire) begin
                    if (win_idx == 4'd10) begin
                        pixcnt <= 17'd0;
                        state  <= S_POP;
                    end else
                        win_idx <= win_idx + 4'd1;
                end

                S_POP: begin
                    if (pixcnt == PIX_TOTAL)
                        state <= S_WAIT;
                    else if (!fifo_empty) begin
                        fifo_rd <= 1'b1;        // high during S_LOAD cycle
                        state   <= S_LOAD;
                    end
                end

                S_LOAD: state <= S_HI;          // fifo_rdata valid at S_HI

                S_HI: if (tx_fire) state <= S_LO;

                S_LO: if (tx_fire) begin
                    pixcnt <= pixcnt + 17'd1;
                    state  <= S_POP;
                end

                default: state <= S_WAIT;
                endcase
            end
        end
    end

endmodule
