`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// st7789_camera_ctrl.v
//
// ST7789 controller derived from the known-working st7789_rgb_test.v:
//   * identical hardware reset timing
//   * identical st7789_init_rom sequence
//   * identical CASET/RASET/RAMWR command structure
//
// The pixel source is a small FIFO filled by cam_capture.  The panel is used
// in landscape mode (280 x 240).  The panel GRAM is the only framebuffer.
// SCLK may pause while the FIFO is empty; CS stays low and RAMWR remains active.
// ============================================================================
module st7789_camera_ctrl #(
    parameter integer CLK_HZ       = 39000000,
    parameter integer SPI_HZ       = 19500000,
    parameter integer WIDTH        = 280,
    parameter integer HEIGHT       = 240,
    parameter integer X_SHIFT      = 20,
    parameter integer Y_SHIFT      = 0,
    parameter [7:0]   MADCTL_VAL   = 8'hA0
)(
    input  wire        clk,
    input  wire        resetn,

    input  wire        stream_enable,
    input  wire        frame_sync,

    input  wire        fifo_empty,
    input  wire [15:0] fifo_rd_data,
    input  wire        fifo_rd_valid,
    output reg         fifo_rd_en,

    output wire        tft_sclk,
    output wire        tft_mosi,
    output wire        tft_cs_n,
    output wire        tft_dc,
    output reg         tft_resn,
    output reg         tft_bl,

    output reg         init_done,
    output reg         frame_done,
    output reg         sync_error,
    output wire        stream_active
);
    localparam integer HALF_DIV = (CLK_HZ/(2*SPI_HZ) < 1) ?
                                  1 : CLK_HZ/(2*SPI_HZ);
    localparam integer MS_DIV   = (CLK_HZ/1000 < 2) ? 2 : CLK_HZ/1000;
    localparam integer MSW      = $clog2(MS_DIV);
    localparam integer NPIX     = WIDTH * HEIGHT;
    localparam integer PCW      = $clog2(NPIX);

    localparam [15:0] X_START = X_SHIFT;
    localparam [15:0] X_END   = X_SHIFT + WIDTH  - 1;
    localparam [15:0] Y_START = Y_SHIFT;
    localparam [15:0] Y_END   = Y_SHIFT + HEIGHT - 1;

    localparam [1:0] T_CMD = 2'b00,
                     T_DAT = 2'b01,
                     T_DLY = 2'b10,
                     T_END = 2'b11;

    localparam [4:0] S_RST_H0    = 5'd0,
                     S_RST_LO    = 5'd1,
                     S_RST_H1    = 5'd2,
                     S_INI_FETCH = 5'd3,
                     S_INI_SEND  = 5'd4,
                     S_INI_WAIT  = 5'd5,
                     S_INI_DLY   = 5'd6,
                     S_WAIT_FR   = 5'd7,
                     S_WIN_LOAD  = 5'd8,
                     S_WIN_SEND  = 5'd9,
                     S_WIN_WAIT  = 5'd10,
                     S_PIX_NEED  = 5'd11,
                     S_PIX_RD    = 5'd12,
                     S_PIX_HIGH  = 5'd13,
                     S_PIX_LOW   = 5'd14,
                     S_PIX_LAST  = 5'd15;

    reg [4:0] state;
    reg [7:0] dly_ms;

    // ---------------- millisecond tick ----------------
    reg [MSW-1:0] ms_div;
    wire ms_tick = (ms_div == MS_DIV-1);

    always @(posedge clk) begin
        if (!resetn)
            ms_div <= {MSW{1'b0}};
        else
            ms_div <= ms_tick ? {MSW{1'b0}} : ms_div + 1'b1;
    end

    // ---------------- ST7789 init ROM ----------------
    reg [6:0] rom_addr;
    wire [1:0] rom_type;
    wire [7:0] rom_data;

    st7789_init_rom #(.MADCTL_VAL(MADCTL_VAL)) init_rom (
        .addr  (rom_addr),
        .etype (rom_type),
        .edata (rom_data)
    );

    // ---------------- address-window bytes ----------------
    reg [3:0] win_idx;
    reg [8:0] win_entry;
    localparam [3:0] WIN_LAST = 4'd10;

    always @(*) begin
        case (win_idx)
            4'd0 : win_entry = {1'b0, 8'h2A};
            4'd1 : win_entry = {1'b1, X_START[15:8]};
            4'd2 : win_entry = {1'b1, X_START[7:0]};
            4'd3 : win_entry = {1'b1, X_END[15:8]};
            4'd4 : win_entry = {1'b1, X_END[7:0]};
            4'd5 : win_entry = {1'b0, 8'h2B};
            4'd6 : win_entry = {1'b1, Y_START[15:8]};
            4'd7 : win_entry = {1'b1, Y_START[7:0]};
            4'd8 : win_entry = {1'b1, Y_END[15:8]};
            4'd9 : win_entry = {1'b1, Y_END[7:0]};
            default: win_entry = {1'b0, 8'h2C};
        endcase
    end

    // ---------------- gapless SPI engine ----------------
    reg        tx_valid;
    reg [7:0]  tx_data;
    reg        tx_dc_i;
    wire       tx_ready;
    wire       tx_accept;
    wire       tx_done;
    wire       tx_busy;

    spi_stream_tx #(.HALF_DIV(HALF_DIV)) spi (
        .clk       (clk),
        .resetn    (resetn),
        .tx_valid  (tx_valid),
        .tx_data   (tx_data),
        .tx_dc     (tx_dc_i),
        .tx_ready  (tx_ready),
        .tx_accept (tx_accept),
        .tx_done   (tx_done),
        .sclk      (tft_sclk),
        .mosi      (tft_mosi),
        .dc        (tft_dc),
        .busy      (tx_busy)
    );

    // ---------------- pixel streaming ----------------
    reg [15:0] pixel_q;
    reg [PCW-1:0] pixel_count;

    assign stream_active = (state >= S_WIN_LOAD) && (state <= S_PIX_LAST);

    // Keep CS low for each init byte and for the complete window+pixel burst.
    assign tft_cs_n = ~((state == S_INI_SEND) || (state == S_INI_WAIT) ||
                        stream_active);

    always @(posedge clk) begin
        if (!resetn) begin
            state       <= S_RST_H0;
            dly_ms      <= 8'd20;
            rom_addr    <= 7'd0;
            win_idx     <= 4'd0;
            pixel_q     <= 16'h0000;
            pixel_count <= {PCW{1'b0}};
            fifo_rd_en  <= 1'b0;
            tx_valid    <= 1'b0;
            tx_data     <= 8'h00;
            tx_dc_i     <= 1'b1;
            tft_resn    <= 1'b1;
            tft_bl      <= 1'b0;
            init_done   <= 1'b0;
            frame_done  <= 1'b0;
            sync_error  <= 1'b0;
        end else begin
            fifo_rd_en <= 1'b0;
            frame_done <= 1'b0;

            if (ms_tick && dly_ms != 8'd0)
                dly_ms <= dly_ms - 1'b1;

            // A new camera frame while the previous panel transfer is still
            // active means the timing margin has been lost.
            if (frame_sync && init_done && (state != S_WAIT_FR))
                sync_error <= 1'b1;

            case (state)
            // ---------------- hardware reset ----------------
            S_RST_H0: if (dly_ms == 8'd0) begin
                tft_resn <= 1'b0;
                dly_ms   <= 8'd20;
                state    <= S_RST_LO;
            end

            S_RST_LO: if (dly_ms == 8'd0) begin
                tft_resn <= 1'b1;
                dly_ms   <= 8'd120;
                state    <= S_RST_H1;
            end

            S_RST_H1: if (dly_ms == 8'd0) begin
                rom_addr <= 7'd0;
                state    <= S_INI_FETCH;
            end

            // ---------------- panel init ----------------
            S_INI_FETCH: begin
                case (rom_type)
                    T_CMD: begin
                        tx_data  <= rom_data;
                        tx_dc_i  <= 1'b0;
                        tx_valid <= 1'b1;
                        state    <= S_INI_SEND;
                    end
                    T_DAT: begin
                        tx_data  <= rom_data;
                        tx_dc_i  <= 1'b1;
                        tx_valid <= 1'b1;
                        state    <= S_INI_SEND;
                    end
                    T_DLY: begin
                        dly_ms   <= rom_data;
                        rom_addr <= rom_addr + 1'b1;
                        state    <= S_INI_DLY;
                    end
                    default: begin
                        init_done <= 1'b1;
                        tft_bl    <= 1'b1;
                        state     <= S_WAIT_FR;
                    end
                endcase
            end

            S_INI_SEND: if (tx_accept) begin
                tx_valid <= 1'b0;
                state    <= S_INI_WAIT;
            end

            S_INI_WAIT: if (tx_done) begin
                rom_addr <= rom_addr + 1'b1;
                state    <= S_INI_FETCH;
            end

            S_INI_DLY: if (dly_ms == 8'd0)
                state <= S_INI_FETCH;

            // ---------------- frame synchronization ----------------
            S_WAIT_FR: begin
                tx_valid <= 1'b0;
                if (frame_sync && stream_enable) begin
                    win_idx     <= 4'd0;
                    pixel_count <= {PCW{1'b0}};
                    state       <= S_WIN_LOAD;
                end
            end

            // ---------------- CASET / RASET / RAMWR ----------------
            S_WIN_LOAD: begin
                tx_dc_i  <= win_entry[8];
                tx_data  <= win_entry[7:0];
                tx_valid <= 1'b1;
                state    <= S_WIN_SEND;
            end

            S_WIN_SEND: if (tx_accept) begin
                tx_valid <= 1'b0;
                state    <= S_WIN_WAIT;
            end

            S_WIN_WAIT: if (tx_done) begin
                if (win_idx == WIN_LAST) begin
                    state <= S_PIX_NEED;
                end else begin
                    win_idx <= win_idx + 1'b1;
                    state   <= S_WIN_LOAD;
                end
            end

            // ---------------- FIFO to RGB565 stream ----------------
            S_PIX_NEED: begin
                tx_valid <= 1'b0;
                if (!fifo_empty) begin
                    fifo_rd_en <= 1'b1;
                    state      <= S_PIX_RD;
                end
            end

            S_PIX_RD: if (fifo_rd_valid) begin
                pixel_q  <= fifo_rd_data;
                tx_data  <= fifo_rd_data[15:8];
                tx_dc_i  <= 1'b1;
                tx_valid <= 1'b1;
                state    <= S_PIX_HIGH;
            end

            // High byte accepted; offer the low byte while the high byte is
            // still shifting.  It will be taken on the boundary with no gap.
            S_PIX_HIGH: if (tx_accept) begin
                tx_data  <= pixel_q[7:0];
                tx_dc_i  <= 1'b1;
                tx_valid <= 1'b1;
                state    <= S_PIX_LOW;
            end

            // Low byte accepted; prefetch the next pixel while it shifts.
            S_PIX_LOW: if (tx_accept) begin
                tx_valid <= 1'b0;
                if (pixel_count == NPIX-1) begin
                    state <= S_PIX_LAST;
                end else begin
                    pixel_count <= pixel_count + 1'b1;
                    state       <= S_PIX_NEED;
                end
            end

            // Wait until the final low byte has actually reached the panel.
            S_PIX_LAST: if (tx_done) begin
                frame_done <= 1'b1;
                state      <= S_WAIT_FR;
            end

            default: state <= S_RST_H0;
            endcase
        end
    end
endmodule
`default_nettype wire
