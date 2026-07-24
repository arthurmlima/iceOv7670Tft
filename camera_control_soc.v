`timescale 1ns / 1ps
`default_nettype none
// Use the same external register-file hook as upstream PicoSoC.  On iCE40
// this maps the two read ports into EBRs instead of building a large FF/mux
// register file.  camera_control_soc.v must therefore be read before
// third_party/picorv32/picorv32.v.
`ifndef PICORV32_REGS
`define PICORV32_REGS camera_control_regs
`endif
// ============================================================================
// camera_control_soc.v
//
// A timing- and area-trimmed PicoSoC-style control processor for the camera
// pipeline.  The memory map and bus structure follow YosysHQ/picorv32's
// picosoc example, while the CPU feature set is reduced for the iCE40UP5K and
// the camera controls are decoded locally.
//
// Upstream reference:
//   https://github.com/YosysHQ/picorv32
//   commit 87c89acc18994c8cf9a2311e871818e87d304568
//
// Portions of the bus structure and register-file wrapper are adapted from
// PicoSoC:
//
//   Copyright (C) 2017 Claire Xenia Wolf <claire@yosyshq.com>
//
//   Permission to use, copy, modify, and/or distribute this software for any
//   purpose with or without fee is hereby granted, provided that the above
//   copyright notice and this permission notice appear in all copies.
//
//   THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
//   WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
//   MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
//   ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//   WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
//   ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
//   OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//
// Memory map:
//   0x0000_0000 .. 0x0000_000F  safe boot ROM (default boot mode only)
//   0x0000_0000 .. 0x0001_FFFF  128 KiB UP5K SPRAM
//   0x0002_0000 .. 0x00FF_FFFF  onboard flash low alias (RAM overlays start)
//   0x0100_0000 .. 0x01FF_FFFF  complete 16 MiB onboard flash alias
//   0x0200_0000                 SPI flash configuration
//   0x0200_0004                 UART clock divider
//   0x0200_0008                 UART data
//   0x0300_0000                 camera control (RW)
//       bit 0: requested encryption mode (0=bypass, 1=encrypt)
//   0x0300_0004                 camera status (RO)
//       bit 0: encryption active for the current accepted frame
//       bit 1: camera and display initialization complete
//       bit 2: display is streaming a frame
//       bit 3: sticky stream/FIFO fault
//       bit 4: PicoRV32 trapped
//   0x0300_0008                 camera configuration command (RW)
//       bits 8:0: table entry count (1..256)
//       bit 30: clear rejected-command flag (write one)
//       bit 31: apply the staged table (write one)
//   0x0300_000C                 camera configuration status (RO)
//       bit 0: table locked / apply pending or active
//       bit 1: current/last apply completed and idle
//       bit 2: rejected command or write
//       bits 16:8: current table index
//   0x0300_1000 .. 0x0300_13FF  camera configuration table (WO)
//       256 32-bit slots; low 16 bits are {register, value}
//
// Until firmware is deliberately enabled, the CPU starts in a four-word boot
// ROM that writes ENCRYPTION_DEFAULT to the control register and loops.  With
// BOOT_FROM_FLASH=1 it starts at 0x0010_0000, matching upstream PicoSoC.  The
// FPGA hardware build therefore has no dependency on a C compiler or firmware
// image and cannot accidentally execute stale flash contents.
// ============================================================================
module camera_control_soc #(
    parameter integer ENCRYPTION_DEFAULT = 0,
    parameter integer BOOT_FROM_FLASH    = 0,
    parameter integer UART_DEFAULT_DIV   = 85,
    parameter [31:0]  STACKADDR          = 32'h0002_0000
) (
    input  wire        clk,
    input  wire        resetn,

    // Camera-configuration port. The table RAM has a CPU-clocked write port
    // and a camera-clocked synchronous read port.
    input  wire        camera_cfg_clk,
    input  wire        camera_cfg_resetn,
    input  wire        camera_cfg_safe,
    output reg         camera_cfg_start,
    output reg  [8:0]  camera_cfg_count,
    output reg  [15:0] camera_cfg_data,
    input  wire [7:0]  camera_cfg_addr,
    input  wire        camera_cfg_busy,
    input  wire        camera_cfg_done,
    input  wire [8:0]  camera_cfg_index,
    output wire        camera_cfg_pending,

    input  wire        encryption_active,
    input  wire        stream_ready,
    input  wire        stream_active,
    input  wire        stream_fault,
    output reg         encrypt_requested,
    output wire        cpu_trap,

    output wire        uart_tx,
    input  wire        uart_rx,

    output wire        flash_csb,
    output wire        flash_clk,
    output wire [3:0]  flash_io_oe,
    output wire [3:0]  flash_io_do,
    input  wire [3:0]  flash_io_di
);
    // The UP5K wrapper always instantiates all four SPRAM blocks.
    localparam integer MEM_WORDS   = 32768;
    localparam [31:0] RAM_BYTES    = 4 * MEM_WORDS;
    localparam [31:0] CONTROL_ADDR = 32'h0300_0000;
    localparam [31:0] STATUS_ADDR  = 32'h0300_0004;
    localparam [31:0] CFG_COMMAND_ADDR = 32'h0300_0008;
    localparam [31:0] CFG_STATUS_ADDR  = 32'h0300_000C;
    localparam [31:0] CFG_TABLE_BASE   = 32'h0300_1000;
    localparam [31:0] CFG_TABLE_END    = 32'h0300_1400;
    localparam [31:0] CPU_RESET_ADDR =
        (BOOT_FROM_FLASH != 0) ? 32'h0010_0000 : 32'h0000_0000;

    // Status arrives from the 39 MHz video domain.  It is telemetry only, so
    // independent two-flop level synchronizers are sufficient.
    (* ASYNC_REG = "TRUE" *) reg [3:0] status_meta;
    (* ASYNC_REG = "TRUE" *) reg [3:0] status_sync;

    always @(posedge clk) begin
        if (!resetn) begin
            status_meta <= 4'b0000;
            status_sync <= 4'b0000;
        end else begin
            status_meta <= {
                stream_fault,
                stream_active,
                stream_ready,
                encryption_active
            };
            status_sync <= status_meta;
        end
    end

    // ---------------- programmable camera-configuration table ----------------
    // One 4-Kbit EBR holds 256 packed {register,value} entries. The CPU port
    // is write-only so the second hardware port remains available to cam_init
    // on camera_cfg_clk.
    (* ram_style = "block" *) reg [15:0] camera_config_mem [0:255];

    always @(posedge camera_cfg_clk)
        camera_cfg_data <= camera_config_mem[camera_cfg_addr];

    // APPLY uses a request/acknowledge toggle. The count is held unchanged
    // from request until acknowledgement and crosses beside the toggle through
    // two registers. This avoids a pulse crossing and prevents firmware from
    // changing the table while cam_init is reading it.
    reg [8:0] camera_cfg_count_hold;
    reg       camera_cfg_request_toggle;
    reg       camera_cfg_rejected;

    (* ASYNC_REG = "TRUE" *) reg       camera_cfg_req_meta;
    (* ASYNC_REG = "TRUE" *) reg       camera_cfg_req_sync;
    (* ASYNC_REG = "TRUE" *) reg [8:0] camera_cfg_count_meta;
    (* ASYNC_REG = "TRUE" *) reg [8:0] camera_cfg_count_sync;

    reg camera_cfg_ack_toggle;
    reg camera_cfg_active;
    reg camera_cfg_active_toggle;
    reg camera_cfg_seen_busy;
    reg camera_cfg_request_settling;

    assign camera_cfg_pending =
        (camera_cfg_req_sync != camera_cfg_ack_toggle) ||
        camera_cfg_active;

    always @(posedge camera_cfg_clk) begin
        if (!camera_cfg_resetn) begin
            camera_cfg_req_meta      <= 1'b0;
            camera_cfg_req_sync      <= 1'b0;
            camera_cfg_count_meta    <= 9'd0;
            camera_cfg_count_sync    <= 9'd0;
            camera_cfg_ack_toggle    <= 1'b0;
            camera_cfg_active        <= 1'b0;
            camera_cfg_active_toggle <= 1'b0;
            camera_cfg_seen_busy     <= 1'b0;
            camera_cfg_request_settling <= 1'b0;
            camera_cfg_start         <= 1'b0;
            camera_cfg_count         <= 9'd0;
        end else begin
            camera_cfg_req_meta   <= camera_cfg_request_toggle;
            camera_cfg_req_sync   <= camera_cfg_req_meta;
            camera_cfg_count_meta <= camera_cfg_count_hold;
            camera_cfg_count_sync <= camera_cfg_count_meta;
            camera_cfg_start      <= 1'b0;

            if (!camera_cfg_active) begin
                camera_cfg_seen_busy <= 1'b0;

                if (camera_cfg_req_sync == camera_cfg_ack_toggle) begin
                    camera_cfg_request_settling <= 1'b0;
                end else if (!camera_cfg_request_settling) begin
                    // The request toggle and held count are a bundled CDC.
                    // Wait one full destination cycle after seeing the
                    // request so every count bit has settled before use.
                    camera_cfg_request_settling <= 1'b1;
                end else if (camera_cfg_safe && !camera_cfg_busy) begin
                    // camera_cfg_safe is asserted only after capture and the
                    // LCD have completed the previous frame. The pending level
                    // has already inhibited the next frame by this point.
                    camera_cfg_count         <= camera_cfg_count_sync;
                    camera_cfg_active_toggle <= camera_cfg_req_sync;
                    camera_cfg_start         <= 1'b1;
                    camera_cfg_active        <= 1'b1;
                    camera_cfg_request_settling <= 1'b0;
                end
            end else begin
                if (camera_cfg_busy)
                    camera_cfg_seen_busy <= 1'b1;

                // Require busy to have been observed. Otherwise the sticky
                // done level from a previous run could acknowledge a new
                // request before cam_init sees its start pulse.
                if (camera_cfg_seen_busy && !camera_cfg_busy &&
                    camera_cfg_done) begin
                    camera_cfg_ack_toggle <= camera_cfg_active_toggle;
                    camera_cfg_active     <= 1'b0;
                    camera_cfg_seen_busy  <= 1'b0;
                end
            end
        end
    end

    // Return acknowledgement and camera progress/status to the CPU domain.
    (* ASYNC_REG = "TRUE" *) reg       camera_cfg_ack_meta;
    (* ASYNC_REG = "TRUE" *) reg       camera_cfg_ack_sync;
    (* ASYNC_REG = "TRUE" *) reg       camera_cfg_busy_meta;
    (* ASYNC_REG = "TRUE" *) reg       camera_cfg_busy_sync;
    (* ASYNC_REG = "TRUE" *) reg       camera_cfg_done_meta;
    (* ASYNC_REG = "TRUE" *) reg       camera_cfg_done_sync;
    (* ASYNC_REG = "TRUE" *) reg [8:0] camera_cfg_index_meta;
    (* ASYNC_REG = "TRUE" *) reg [8:0] camera_cfg_index_sync;

    always @(posedge clk) begin
        if (!resetn) begin
            camera_cfg_ack_meta   <= 1'b0;
            camera_cfg_ack_sync   <= 1'b0;
            camera_cfg_busy_meta  <= 1'b0;
            camera_cfg_busy_sync  <= 1'b0;
            camera_cfg_done_meta  <= 1'b0;
            camera_cfg_done_sync  <= 1'b0;
            camera_cfg_index_meta <= 9'd0;
            camera_cfg_index_sync <= 9'd0;
        end else begin
            camera_cfg_ack_meta   <= camera_cfg_ack_toggle;
            camera_cfg_ack_sync   <= camera_cfg_ack_meta;
            camera_cfg_busy_meta  <= camera_cfg_busy;
            camera_cfg_busy_sync  <= camera_cfg_busy_meta;
            camera_cfg_done_meta  <= camera_cfg_done;
            camera_cfg_done_sync  <= camera_cfg_done_meta;
            camera_cfg_index_meta <= camera_cfg_index;
            camera_cfg_index_sync <= camera_cfg_index_meta;
        end
    end

    wire camera_cfg_locked =
        (camera_cfg_request_toggle != camera_cfg_ack_sync) ||
        camera_cfg_busy_sync;
    wire camera_cfg_completed = camera_cfg_done_sync &&
                                !camera_cfg_locked;

    // ---------------- PicoRV32 native memory bus ----------------
    wire        mem_valid;
    wire        mem_instr;
    wire        mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    wire [31:0] mem_rdata;

    // The camera datapath already needs 39 MHz.  The two-cycle ALU/compare
    // options relax the CPU's longest paths while omitted M/C/IRQ features
    // and 32-bit-only counters keep the auxiliary controller compact.
    picorv32 #(
        // The upstream PicoSoC firmware uses rdcycle/rdinstret for its UART
        // prompt and benchmark commands. Low 32-bit counters are sufficient.
        .ENABLE_COUNTERS      (1),
        .ENABLE_COUNTERS64    (0),
        .ENABLE_REGS_16_31    (1),
        .ENABLE_REGS_DUALPORT (1),
        .LATCHED_MEM_RDATA    (0),
        .TWO_STAGE_SHIFT      (0),
        .BARREL_SHIFTER       (0),
        .TWO_CYCLE_COMPARE    (1),
        .TWO_CYCLE_ALU        (1),
        .COMPRESSED_ISA       (0),
        .CATCH_MISALIGN       (1),
        .CATCH_ILLINSN        (1),
        .ENABLE_PCPI          (0),
        .ENABLE_MUL           (0),
        .ENABLE_FAST_MUL      (0),
        .ENABLE_DIV           (0),
        .ENABLE_IRQ           (0),
        .ENABLE_TRACE         (0),
        .PROGADDR_RESET       (CPU_RESET_ADDR),
        .STACKADDR            (STACKADDR)
    ) cpu (
        .clk        (clk),
        .resetn     (resetn),
        .trap       (cpu_trap),
        .mem_valid  (mem_valid),
        .mem_instr  (mem_instr),
        .mem_ready  (mem_ready),
        .mem_addr   (mem_addr),
        .mem_wdata  (mem_wdata),
        .mem_wstrb  (mem_wstrb),
        .mem_rdata  (mem_rdata),
        .pcpi_wr    (1'b0),
        .pcpi_rd    (32'd0),
        .pcpi_wait  (1'b0),
        .pcpi_ready (1'b0),
        .irq        (32'd0)
    );

    // ---------------- internal SPRAM ----------------
    // ---------------- hardware-only safe boot ROM ----------------
    //   lui  x1, 0x03000        ; camera MMIO base
    //   addi x2, x0, default    ; requested mode
    //   sw   x2, 0(x1)
    //   jal  x0, 0             ; wait for real firmware
    wire boot_rom_sel =
        (BOOT_FROM_FLASH == 0) && mem_valid && (mem_addr < 32'd16);
    reg [31:0] boot_rom_rdata;

    always @(*) begin
        case (mem_addr[3:2])
            2'd0: boot_rom_rdata = 32'h0300_00B7;
            2'd1: boot_rom_rdata =
                (ENCRYPTION_DEFAULT != 0) ? 32'h0010_0113 :
                                            32'h0000_0113;
            2'd2: boot_rom_rdata = 32'h0020_A023;
            default: boot_rom_rdata = 32'h0000_006F;
        endcase
    end

    // ---------------- internal SPRAM ----------------
    wire ram_sel =
        mem_valid && (mem_addr < RAM_BYTES) && !boot_rom_sel;
    reg  ram_ready;
    wire [31:0] ram_rdata;

    always @(posedge clk) begin
        if (!resetn)
            ram_ready <= 1'b0;
        else
            ram_ready <= ram_sel && !mem_ready;
    end

    ice40up5k_spram #(
        .WORDS (MEM_WORDS)
    ) memory (
        .clk   (clk),
        .wen   ((ram_sel && !mem_ready) ? mem_wstrb : 4'b0000),
        .addr  (mem_addr[23:2]),
        .wdata (mem_wdata),
        .rdata (ram_rdata)
    );

    // ---------------- memory-mapped onboard SPI flash ----------------
    wire spimem_ready;
    wire [31:0] spimem_rdata;
    wire spimemio_cfgreg_sel =
        mem_valid && (mem_addr == 32'h0200_0000);
    wire [31:0] spimemio_cfgreg_do;

    spimemio flash (
        .clk          (clk),
        .resetn       (resetn),
        .valid        (mem_valid && (mem_addr >= RAM_BYTES) &&
                       (mem_addr < 32'h0200_0000)),
        .ready        (spimem_ready),
        .addr         (mem_addr[23:0]),
        .rdata        (spimem_rdata),
        .flash_csb    (flash_csb),
        .flash_clk    (flash_clk),
        .flash_io0_oe (flash_io_oe[0]),
        .flash_io1_oe (flash_io_oe[1]),
        .flash_io2_oe (flash_io_oe[2]),
        .flash_io3_oe (flash_io_oe[3]),
        .flash_io0_do (flash_io_do[0]),
        .flash_io1_do (flash_io_do[1]),
        .flash_io2_do (flash_io_do[2]),
        .flash_io3_do (flash_io_do[3]),
        .flash_io0_di (flash_io_di[0]),
        .flash_io1_di (flash_io_di[1]),
        .flash_io2_di (flash_io_di[2]),
        .flash_io3_di (flash_io_di[3]),
        .cfgreg_we    (spimemio_cfgreg_sel ? mem_wstrb : 4'b0000),
        .cfgreg_di    (mem_wdata),
        .cfgreg_do    (spimemio_cfgreg_do)
    );

    // ---------------- PicoSoC-compatible UART ----------------
    wire simpleuart_reg_div_sel =
        mem_valid && (mem_addr == 32'h0200_0004);
    wire [31:0] simpleuart_reg_div_do;
    wire simpleuart_reg_dat_sel =
        mem_valid && (mem_addr == 32'h0200_0008);
    wire [31:0] simpleuart_reg_dat_do;
    wire simpleuart_reg_dat_wait;

    simpleuart #(
        .DEFAULT_DIV (UART_DEFAULT_DIV)
    ) uart (
        .clk          (clk),
        .resetn       (resetn),
        .ser_tx       (uart_tx),
        .ser_rx       (uart_rx),
        .reg_div_we   (simpleuart_reg_div_sel ? mem_wstrb : 4'b0000),
        .reg_div_di   (mem_wdata),
        .reg_div_do   (simpleuart_reg_div_do),
        .reg_dat_we   (simpleuart_reg_dat_sel ? mem_wstrb[0] : 1'b0),
        .reg_dat_re   (simpleuart_reg_dat_sel && !mem_wstrb),
        .reg_dat_di   (mem_wdata),
        .reg_dat_do   (simpleuart_reg_dat_do),
        .reg_dat_wait (simpleuart_reg_dat_wait)
    );

    // ---------------- camera control/configuration MMIO ----------------
    wire control_sel =
        mem_valid && (mem_addr == CONTROL_ADDR);
    wire status_sel =
        mem_valid && (mem_addr == STATUS_ADDR);
    wire camera_cfg_command_sel =
        mem_valid && (mem_addr == CFG_COMMAND_ADDR);
    wire camera_cfg_status_sel =
        mem_valid && (mem_addr == CFG_STATUS_ADDR);
    wire camera_cfg_table_sel =
        mem_valid && (mem_addr >= CFG_TABLE_BASE) &&
        (mem_addr < CFG_TABLE_END);

    reg        mmio_ready;
    reg [31:0] mmio_rdata;

    wire [8:0] camera_cfg_command_count = {
        mem_wstrb[1] ? mem_wdata[8]   : camera_cfg_count_hold[8],
        mem_wstrb[0] ? mem_wdata[7:0] : camera_cfg_count_hold[7:0]
    };
    wire camera_cfg_command_count_valid =
        (camera_cfg_command_count != 9'd0) &&
        (!camera_cfg_command_count[8] ||
         (camera_cfg_command_count[7:0] == 8'd0));

    wire camera_cfg_table_write =
        camera_cfg_table_sel && !mmio_ready && !camera_cfg_locked &&
        (|mem_wstrb[1:0]);

    // Byte enables are retained for the low 16-bit packed entry. The upper
    // half of each naturally aligned RV32 table slot is intentionally unused.
    always @(posedge clk) begin
        if (camera_cfg_table_write) begin
            if (mem_wstrb[0])
                camera_config_mem[mem_addr[9:2]][7:0] <= mem_wdata[7:0];
            if (mem_wstrb[1])
                camera_config_mem[mem_addr[9:2]][15:8] <= mem_wdata[15:8];
        end
    end

    always @(posedge clk) begin
        if (!resetn) begin
            mmio_ready               <= 1'b0;
            mmio_rdata               <= 32'd0;
            encrypt_requested        <= (ENCRYPTION_DEFAULT != 0);
            camera_cfg_count_hold    <= 9'd0;
            camera_cfg_request_toggle <= 1'b0;
            camera_cfg_rejected      <= 1'b0;
        end else begin
            mmio_ready <= 1'b0;

            if (!mmio_ready &&
                (control_sel || status_sel ||
                 camera_cfg_command_sel || camera_cfg_status_sel ||
                 camera_cfg_table_sel)) begin
                mmio_ready <= 1'b1;

                if (control_sel) begin
                    mmio_rdata <= {31'd0, encrypt_requested};
                    if (mem_wstrb[0])
                        encrypt_requested <= mem_wdata[0];
                end else if (status_sel) begin
                    mmio_rdata <= {
                        27'd0,
                        cpu_trap,
                        status_sync
                    };
                end else if (camera_cfg_command_sel) begin
                    mmio_rdata <= {23'd0, camera_cfg_count_hold};

                    if (mem_wstrb[3] && mem_wdata[30])
                        camera_cfg_rejected <= 1'b0;

                    if (mem_wstrb[3] && mem_wdata[31]) begin
                        if (camera_cfg_locked ||
                            !camera_cfg_command_count_valid) begin
                            camera_cfg_rejected <= 1'b1;
                        end else begin
                            camera_cfg_count_hold <=
                                camera_cfg_command_count;
                            camera_cfg_request_toggle <=
                                ~camera_cfg_request_toggle;
                        end
                    end else if ((|mem_wstrb[1:0]) &&
                                 !(mem_wstrb[3] && mem_wdata[30])) begin
                        if (camera_cfg_locked ||
                            !camera_cfg_command_count_valid)
                            camera_cfg_rejected <= 1'b1;
                        else
                            camera_cfg_count_hold <=
                                camera_cfg_command_count;
                    end
                end else if (camera_cfg_status_sel) begin
                    mmio_rdata <= {
                        15'd0,
                        camera_cfg_index_sync,
                        5'd0,
                        camera_cfg_rejected,
                        camera_cfg_completed,
                        camera_cfg_locked
                    };
                end else begin
                    // Configuration-table reads deliberately return zero:
                    // readback would require a third EBR port.
                    mmio_rdata <= 32'd0;
                    if ((|mem_wstrb[1:0]) && camera_cfg_locked)
                        camera_cfg_rejected <= 1'b1;
                end
            end
        end
    end

    // ---------------- bus response mux ----------------
    assign mem_ready =
        boot_rom_sel ||
        mmio_ready ||
        spimem_ready ||
        ram_ready ||
        spimemio_cfgreg_sel ||
        simpleuart_reg_div_sel ||
        (simpleuart_reg_dat_sel && !simpleuart_reg_dat_wait);

    assign mem_rdata =
        boot_rom_sel             ? boot_rom_rdata :
        mmio_ready               ? mmio_rdata :
        spimem_ready             ? spimem_rdata :
        ram_ready                ? ram_rdata :
        spimemio_cfgreg_sel      ? spimemio_cfgreg_do :
        simpleuart_reg_div_sel   ? simpleuart_reg_div_do :
        simpleuart_reg_dat_sel   ? simpleuart_reg_dat_do :
                                   32'd0;

    wire _unused_ok = &{1'b0, mem_instr};
endmodule

// PicoRV32 external register file.  This is functionally identical to the
// picosoc_regs module shipped by upstream PicoSoC.
module camera_control_regs (
    input  wire        clk,
    input  wire        wen,
    input  wire [5:0]  waddr,
    input  wire [5:0]  raddr1,
    input  wire [5:0]  raddr2,
    input  wire [31:0] wdata,
    output wire [31:0] rdata1,
    output wire [31:0] rdata2
);
    reg [31:0] regs [0:31];

    always @(posedge clk)
        if (wen)
            regs[waddr[4:0]] <= wdata;

    assign rdata1 = regs[raddr1[4:0]];
    assign rdata2 = regs[raddr2[4:0]];
endmodule
`default_nettype wire
