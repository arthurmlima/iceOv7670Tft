// ============================================================================
// spi8.v - SPI mode 0 byte transmitter, MSB first, write-only (no MISO).
//
// SCK = clk/2 (one bit every 2 system clocks). CS is handled by the caller.
// DC (data/command) is registered per byte and only changes between bytes.
//
// The engine has a one-byte skid buffer (pend_*). While byte N is shifting,
// byte N+1 can already be accepted; when bit 0 of byte N finishes, byte N+1
// starts on the very next cycle. This makes back-to-back transmission
// GAPLESS: exactly 16 clk cycles per byte, which the pixel-rate budget
// (33.6 cycles/pixel per camera line) depends on.
//
// Handshake: valid/ready. A byte transfers on the clk edge where
// in_valid && in_ready are both high.
// ============================================================================

module spi8 (
    input  wire       clk,
    input  wire       rst,

    input  wire       in_valid,
    input  wire       in_dc,      // 0 = command, 1 = data
    input  wire [7:0] in_data,
    output wire       in_ready,

    output reg        sck,        // idles low (CPOL = 0)
    output reg        mosi,
    output reg        dc,
    output wire       idle        // nothing shifting, nothing pending
);

    reg [7:0] shift;
    reg [2:0] bitcnt;
    reg       phase;      // 0 = setup (SCK low), 1 = sample (SCK high)
    reg       running;

    reg [7:0] pend_data;
    reg       pend_dc;
    reg       pend_valid;

    assign in_ready = ~pend_valid;
    assign idle     = ~running & ~pend_valid;

    always @(posedge clk) begin
        if (rst) begin
            sck        <= 1'b0;
            mosi       <= 1'b0;
            dc         <= 1'b0;
            shift      <= 8'd0;
            bitcnt     <= 3'd0;
            phase      <= 1'b0;
            running    <= 1'b0;
            pend_data  <= 8'd0;
            pend_dc    <= 1'b0;
            pend_valid <= 1'b0;
        end else begin
            // Accept a new byte into the skid buffer.
            // (Cannot collide with the consume below: consuming requires
            //  pend_valid==1, in which case in_ready==0 and no transfer
            //  happens this cycle.)
            if (in_valid && !pend_valid) begin
                pend_data  <= in_data;
                pend_dc    <= in_dc;
                pend_valid <= 1'b1;
            end

            if (!running) begin
                sck <= 1'b0;
                if (pend_valid) begin
                    // Launch: this cycle is phase A of bit 7.
                    shift      <= pend_data;
                    dc         <= pend_dc;
                    mosi       <= pend_data[7];
                    bitcnt     <= 3'd7;
                    phase      <= 1'b1;
                    running    <= 1'b1;
                    pend_valid <= 1'b0;
                end
            end else begin
                if (phase) begin
                    // Phase B: rising edge, the panel samples MOSI here.
                    sck   <= 1'b1;
                    phase <= 1'b0;
                end else begin
                    if (bitcnt != 3'd0) begin
                        // Phase A of the next bit.
                        sck    <= 1'b0;
                        shift  <= shift << 1;
                        mosi   <= shift[6];
                        bitcnt <= bitcnt - 3'd1;
                        phase  <= 1'b1;
                    end else begin
                        // Bit 0 done. Chain the pending byte with no gap,
                        // or fall back to idle.
                        if (pend_valid) begin
                            sck        <= 1'b0;
                            shift      <= pend_data;
                            dc         <= pend_dc;
                            mosi       <= pend_data[7];
                            bitcnt     <= 3'd7;
                            phase      <= 1'b1;
                            pend_valid <= 1'b0;
                        end else begin
                            sck     <= 1'b0;
                            running <= 1'b0;
                        end
                    end
                end
            end
        end
    end

endmodule
