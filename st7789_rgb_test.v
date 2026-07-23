`timescale 1ns / 1ps
//======================================================================
//  st7789_rgb_test.v      -- pure-HDL ST7789 240x280 RGB test generator
//
//  Replaces the whole Zynq PS software stack (XSpiPs + XGpioPs +
//  ST7789_Init + framebuffer flush) with a state machine in the PL.
//  Nothing but a clock and a reset is needed; no AXI, no processor.
//
//  What it does, forever:
//      1. hardware reset pulse on RES  (20 ms high / 20 ms low / 120 ms high)
//      2. walks the init ROM, byte for byte the same as ST7789_Init()
//      3. CASET / RASET / RAMWR for the full 240x280 window, including
//         the 20-row RAM offset of the 240x280 glass (Y_SHIFT)
//      4. streams WIDTH*HEIGHT pixels, high byte first, straight from a
//         combinational pattern generator
//      5. repeats from step 3, incrementing the frame counter
//
//  Timing note: 240*280*2 = 134400 bytes per frame.  At SPI_HZ = 10 MHz
//  that is ~107 ms/frame, i.e. ~9 fps - same ballpark as the PS version,
//  because SPI is the bottleneck either way.  The panel is happy up to
//  around 60 MHz if the wiring is short; raise SPI_HZ and check for
//  tearing/garbage before trusting it.
//======================================================================
module st7789_rgb_test #(
    parameter integer CLK_HZ       = 39000000,  // PL clock, e.g. FCLK_CLK0
    parameter integer SPI_HZ       = 9750000,   // matches PRESCALE_16 in the C code
    parameter integer WIDTH        = 240,
    parameter integer HEIGHT       = 280,
    parameter integer X_SHIFT      = 0,          // from ST7789.h, ROTATION 2
    parameter integer Y_SHIFT      = 20,         // 240x320 RAM, 240x280 glass
    parameter [7:0]   MADCTL_VAL   = 8'hC0,      // MX | MY | RGB
    parameter integer FRAME_GAP_MS = 0           // idle time between frames, <= 255
)(
    input  wire       clk,
    input  wire       resetn,          // active low

    input  wire [1:0] pattern_sel,     // see rgb_test_pattern.v
    input  wire       auto_cycle,      // 1 = walk through all four patterns

    // ---- panel pins ----
    output wire       tft_sclk,
    output wire       tft_mosi,
    output wire       tft_cs_n,
    output reg        tft_dc,          // 0 = command, 1 = data
    output reg        tft_resn,
    output reg        tft_bl,          // backlight enable

    // ---- status, wire to LEDs if you like ----
    output reg        init_done,
    output reg        frame_pulse,     // 1-cycle pulse at end of each frame
    output wire [1:0] pattern_active   // pattern currently being drawn
);
    //------------------------------------------------------------------
    // Derived constants
    //------------------------------------------------------------------
    localparam integer HALF_DIV = (CLK_HZ/(2*SPI_HZ) < 1) ? 1 : CLK_HZ/(2*SPI_HZ);
    localparam integer MS_DIV   = (CLK_HZ/1000 < 2)      ? 2 : CLK_HZ/1000;
    localparam integer MSW      = $clog2(MS_DIV);

    // Address window, in controller RAM coordinates
    localparam [15:0] X_START = X_SHIFT;
    localparam [15:0] X_END   = X_SHIFT + WIDTH  - 1;
    localparam [15:0] Y_START = Y_SHIFT;
    localparam [15:0] Y_END   = Y_SHIFT + HEIGHT - 1;

    localparam [1:0] T_CMD = 2'b00, T_DAT = 2'b01, T_DLY = 2'b10, T_END = 2'b11;

    localparam [3:0] S_RST_H0 = 4'd0,   // RES high,  20 ms
                     S_RST_LO = 4'd1,   // RES low,   20 ms
                     S_RST_H1 = 4'd2,   // RES high, 120 ms
                     S_INI_F  = 4'd3,   // fetch init ROM entry
                     S_INI_W  = 4'd4,   // wait for byte to go out
                     S_INI_D  = 4'd5,   // ROM-requested delay
                     S_WIN_F  = 4'd6,   // CASET / RASET / RAMWR
                     S_WIN_W  = 4'd7,
                     S_PIX_PRE= 4'd8,   // allow registered pattern to settle
                     S_PIX_F  = 4'd9,   // pixel stream
                     S_PIX_W  = 4'd10,
                     S_GAP    = 4'd11;

    //------------------------------------------------------------------
    // millisecond tick
    //------------------------------------------------------------------
    reg  [MSW-1:0] ms_div;
    wire           ms_tick = (ms_div == MS_DIV-1);

    always @(posedge clk) begin
        if (!resetn) ms_div <= {MSW{1'b0}};
        else         ms_div <= ms_tick ? {MSW{1'b0}} : ms_div + 1'b1;
    end

    //------------------------------------------------------------------
    // SPI byte engine
    //------------------------------------------------------------------
    reg        tx_start;
    reg  [7:0] tx_byte;
    wire       tx_busy, tx_done;

    spi_master_tx #(.HALF_DIV(HALF_DIV)) u_spi (
        .clk     (clk),
        .resetn  (resetn),
        .start   (tx_start),
        .tx_byte (tx_byte),
        .sclk    (tft_sclk),
        .mosi    (tft_mosi),
        .busy    (tx_busy),
        .done    (tx_done)
    );

    //------------------------------------------------------------------
    // Init sequence ROM
    //------------------------------------------------------------------
    reg  [6:0] rom_addr;
    wire [1:0] rom_type;
    wire [7:0] rom_data;

    st7789_init_rom #(.MADCTL_VAL(MADCTL_VAL)) u_rom (
        .addr  (rom_addr),
        .etype (rom_type),
        .edata (rom_data)
    );

    //------------------------------------------------------------------
    // Address-window sequence, built from the parameters.
    // entry = {dc, byte}
    //------------------------------------------------------------------
    reg  [3:0] win_idx;
    reg  [8:0] win_entry;
    localparam [3:0] WIN_LAST = 4'd10;

    always @(*) begin
        case (win_idx)
            4'd0 : win_entry = {1'b0, 8'h2A};          // CASET
            4'd1 : win_entry = {1'b1, X_START[15:8]};
            4'd2 : win_entry = {1'b1, X_START[7:0]};
            4'd3 : win_entry = {1'b1, X_END  [15:8]};
            4'd4 : win_entry = {1'b1, X_END  [7:0]};
            4'd5 : win_entry = {1'b0, 8'h2B};          // RASET
            4'd6 : win_entry = {1'b1, Y_START[15:8]};
            4'd7 : win_entry = {1'b1, Y_START[7:0]};
            4'd8 : win_entry = {1'b1, Y_END  [15:8]};
            4'd9 : win_entry = {1'b1, Y_END  [7:0]};
            default: win_entry = {1'b0, 8'h2C};        // RAMWR
        endcase
    end

    //------------------------------------------------------------------
    // Pixel source
    //------------------------------------------------------------------
    localparam integer XW = (WIDTH  <= 2) ? 1 : $clog2(WIDTH);
    localparam integer YW = (HEIGHT <= 2) ? 1 : $clog2(HEIGHT);
    reg  [XW-1:0] px;
    reg  [YW-1:0] py;
    reg         hi_byte;
    reg  [7:0]  frame_cnt;
    wire [15:0] pix_color;
    wire [1:0]  mode = auto_cycle ? frame_cnt[7:6] : pattern_sel;

    assign pattern_active = mode;

    rgb_test_pattern #(.WIDTH(WIDTH), .HEIGHT(HEIGHT), .XW(XW), .YW(YW)) u_pat (
        .clk   (clk),
        .x     (px),
        .y     (py),
        .mode  (mode),
        .frame (frame_cnt),
        .color (pix_color)
    );

    //------------------------------------------------------------------
    // Main FSM
    //------------------------------------------------------------------
    reg [3:0] state;
    reg [7:0] dly_ms;

    // CS is held low across a whole burst and released only while idle
    // or waiting - the panel never sees a partial byte.
    assign tft_cs_n = ~(state == S_INI_F || state == S_INI_W ||
                        state == S_WIN_F || state == S_WIN_W ||
                        state == S_PIX_PRE || state == S_PIX_F || state == S_PIX_W);

    always @(posedge clk) begin
        if (!resetn) begin
            state       <= S_RST_H0;
            dly_ms      <= 8'd20;
            tft_resn    <= 1'b1;
            tft_bl      <= 1'b0;
            tft_dc      <= 1'b1;
            tx_start    <= 1'b0;
            tx_byte     <= 8'h00;
            rom_addr    <= 7'd0;
            win_idx     <= 4'd0;
            px          <= {XW{1'b0}};
            py          <= {YW{1'b0}};
            hi_byte     <= 1'b1;
            frame_cnt   <= 8'd0;
            init_done   <= 1'b0;
            frame_pulse <= 1'b0;
        end else begin
            tx_start    <= 1'b0;
            frame_pulse <= 1'b0;

            // global millisecond countdown; any load inside the case
            // below happens later in the block and therefore wins
            if (ms_tick && dly_ms != 8'd0)
                dly_ms <= dly_ms - 1'b1;

            case (state)
            //---------------- hardware reset pulse ---------------------
            S_RST_H0: if (dly_ms == 8'd0) begin
                          tft_resn <= 1'b0;
                          dly_ms   <= 8'd20;
                          state    <= S_RST_LO;
                      end
            S_RST_LO: if (dly_ms == 8'd0) begin
                          tft_resn <= 1'b1;
                          tft_bl   <= 1'b1;          // backlight on
                          dly_ms   <= 8'd120;
                          state    <= S_RST_H1;
                      end
            S_RST_H1: if (dly_ms == 8'd0) begin
                          rom_addr <= 7'd0;
                          state    <= S_INI_F;
                      end

            //---------------- init sequence ---------------------------
            S_INI_F: begin
                case (rom_type)
                    T_CMD: begin
                        tft_dc   <= 1'b0;
                        tx_byte  <= rom_data;
                        tx_start <= 1'b1;
                        state    <= S_INI_W;
                    end
                    T_DAT: begin
                        tft_dc   <= 1'b1;
                        tx_byte  <= rom_data;
                        tx_start <= 1'b1;
                        state    <= S_INI_W;
                    end
                    T_DLY: begin
                        dly_ms   <= rom_data;
                        rom_addr <= rom_addr + 1'b1;
                        state    <= S_INI_D;
                    end
                    default: begin                  // T_END
                        init_done <= 1'b1;
                        win_idx   <= 4'd0;
                        state     <= S_WIN_F;
                    end
                endcase
            end

            S_INI_W: if (tx_done) begin
                         rom_addr <= rom_addr + 1'b1;
                         state    <= S_INI_F;
                     end

            S_INI_D: if (dly_ms == 8'd0)
                         state <= S_INI_F;

            //---------------- CASET / RASET / RAMWR -------------------
            S_WIN_F: begin
                tft_dc   <= win_entry[8];
                tx_byte  <= win_entry[7:0];
                tx_start <= 1'b1;
                state    <= S_WIN_W;
            end

            S_WIN_W: if (tx_done) begin
                         if (win_idx == WIN_LAST) begin
                             px      <= {XW{1'b0}};
                             py      <= {YW{1'b0}};
                             hi_byte <= 1'b1;
                             state   <= S_PIX_PRE;
                         end else begin
                             win_idx <= win_idx + 1'b1;
                             state   <= S_WIN_F;
                         end
                     end

            //---------------- pixel stream ----------------------------
            // rgb_test_pattern registers its output.  This one-cycle
            // preparation state breaks the coordinate/comparator path,
            // which is important for 48 MHz timing on iCE40UP5K.
            S_PIX_PRE: state <= S_PIX_F;

            S_PIX_F: begin
                tft_dc   <= 1'b1;
                tx_byte  <= hi_byte ? pix_color[15:8] : pix_color[7:0];
                tx_start <= 1'b1;
                state    <= S_PIX_W;
            end

            S_PIX_W: if (tx_done) begin
                         if (hi_byte) begin
                             hi_byte <= 1'b0;
                             state   <= S_PIX_F;
                         end else begin
                             hi_byte <= 1'b1;
                             if (px == WIDTH-1) begin
                                 px <= {XW{1'b0}};
                                 if (py == HEIGHT-1) begin
                                     py          <= {YW{1'b0}};
                                     frame_cnt   <= frame_cnt + 1'b1;
                                     frame_pulse <= 1'b1;
                                     dly_ms      <= FRAME_GAP_MS;      // truncated to 8 bits
                                     state       <= S_GAP;
                                 end else begin
                                     py    <= py + 1'b1;
                                     state <= S_PIX_PRE;
                                 end
                             end else begin
                                 px    <= px + 1'b1;
                                 state <= S_PIX_PRE;
                             end
                         end
                     end

            //---------------- next frame ------------------------------
            S_GAP: if (dly_ms == 8'd0) begin
                       win_idx <= 4'd0;
                       state   <= S_WIN_F;
                   end

            default: state <= S_RST_H0;
            endcase
        end
    end
endmodule
