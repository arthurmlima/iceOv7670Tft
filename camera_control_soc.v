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

    // ---------------- camera control/status MMIO ----------------
    wire control_sel = mem_valid && (mem_addr == CONTROL_ADDR);
    wire status_sel  = mem_valid && (mem_addr == STATUS_ADDR);
    reg        mmio_ready;
    reg [31:0] mmio_rdata;

    always @(posedge clk) begin
        if (!resetn) begin
            mmio_ready        <= 1'b0;
            mmio_rdata        <= 32'd0;
            encrypt_requested <= (ENCRYPTION_DEFAULT != 0);
        end else begin
            mmio_ready <= 1'b0;

            if (!mmio_ready && (control_sel || status_sel)) begin
                mmio_ready <= 1'b1;

                if (control_sel) begin
                    mmio_rdata <= {31'd0, encrypt_requested};
                    if (mem_wstrb[0])
                        encrypt_requested <= mem_wdata[0];
                end else begin
                    mmio_rdata <= {
                        27'd0,
                        cpu_trap,
                        status_sync
                    };
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
