/*
 *  PicoSoC - A simple example SoC using PicoRV32
 *
 *  Copyright (C) 2017  Claire Xenia Wolf <claire@yosyshq.com>
 *
 *  Permission to use, copy, modify, and/or distribute this software for any
 *  purpose with or without fee is hereby granted, provided that the above
 *  copyright notice and this permission notice appear in all copies.
 *
 *  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 *  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 *  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 *  ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 *  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 *  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 *  OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 */

/*
 * Adapted for the iCEBreaker OV7670/ST7789 camera design. The upstream
 * PicoSoC LED register at 0x03000000 is replaced by explicit camera control
 * and status registers, and the UART timing is derived from clk_cpu=9.75 MHz.
 */

#include <stdint.h>
#include <stdbool.h>

#ifdef ICEBREAKER
#  define MEM_TOTAL 0x20000 /* 128 KB */
#elif HX8KDEMO
#  define MEM_TOTAL 0x200 /* 2 KB */
#else
#  error "Set -DICEBREAKER or -DHX8KDEMO when compiling firmware.c"
#endif

// a pointer to this is a null pointer, but the compiler does not
// know that because "sram" is a linker symbol from sections.lds.
extern uint32_t sram;

#define reg_spictrl (*(volatile uint32_t*)0x02000000)
#define reg_uart_clkdiv (*(volatile uint32_t*)0x02000004)
#define reg_uart_data (*(volatile uint32_t*)0x02000008)
#define reg_camera_control (*(volatile uint32_t*)0x03000000)
#define reg_camera_status (*(volatile const uint32_t*)0x03000004)
#define reg_camera_config_command (*(volatile uint32_t*)0x03000008)
#define reg_camera_config_status (*(volatile const uint32_t*)0x0300000c)
#define reg_camera_config_table ((volatile uint32_t*)0x03001000)

#define CAMERA_CTRL_ENCRYPT          (1u << 0)

#define CAMERA_STATUS_ENCRYPT_ACTIVE (1u << 0)
#define CAMERA_STATUS_STREAM_READY   (1u << 1)
#define CAMERA_STATUS_STREAM_ACTIVE  (1u << 2)
#define CAMERA_STATUS_STREAM_FAULT   (1u << 3)
#define CAMERA_STATUS_CPU_TRAP       (1u << 4)

#define CAMERA_CONFIG_CAPACITY       256u
#define CAMERA_CONFIG_COMMAND_APPLY  (1u << 31)
#define CAMERA_CONFIG_COMMAND_CLEAR_REJECTED (1u << 30)

#define CAMERA_CONFIG_STATUS_BUSY     (1u << 0)
#define CAMERA_CONFIG_STATUS_DONE     (1u << 1)
#define CAMERA_CONFIG_STATUS_REJECTED (1u << 2)
#define CAMERA_CONFIG_STATUS_INDEX_SHIFT 8
#define CAMERA_CONFIG_STATUS_INDEX_MASK  (0x1ffu << CAMERA_CONFIG_STATUS_INDEX_SHIFT)

#define OV7670_REG(reg, value) \
	((((uint32_t)(reg) & 0xffu) << 8) | ((uint32_t)(value) & 0xffu))

#ifndef UART_CLKDIV
#define UART_CLKDIV 85
#endif

#ifndef PROMPT_TIMEOUT_CYCLES
#define PROMPT_TIMEOUT_CYCLES 9750000
#endif

/*
 * Default QVGA/RGB565 camera setup formerly synthesized as the ROM in
 * cam_init.v. Each element is one naturally aligned MMIO store; only its low
 * 16 bits are implemented in the FPGA table RAM.
 *
 * Keep timing-critical values (CLKRC, COM7, COM3, COM14, scaling, and DBLV)
 * coordinated with timing_check.py. Other tables can be substituted at
 * runtime with camera_configure().
 */
static const uint32_t ov7670_default_config[] = {
	OV7670_REG(0x12, 0x80), /* COM7: soft reset */
	OV7670_REG(0x12, 0x80), /* repeated as in the proven configuration */
	OV7670_REG(0x12, 0x14), /* COM7: QVGA + RGB */
	OV7670_REG(0x11, 0x01), /* CLKRC: XCLK / 2 */
	OV7670_REG(0x0c, 0x04), /* COM3: DCW enable */
	OV7670_REG(0x3e, 0x19), /* COM14: manual scale, PCLK / 2 */
	OV7670_REG(0x8c, 0x00), /* RGB444 disable */
	OV7670_REG(0x04, 0x00), /* COM1 */
	OV7670_REG(0x40, 0xd0), /* COM15: full-range RGB565 */
	OV7670_REG(0x3a, 0x04), /* TSLB */
	OV7670_REG(0x14, 0x38), /* COM9: 16x AGC ceiling */
	OV7670_REG(0x4f, 0xb3),
	OV7670_REG(0x50, 0xb3),
	OV7670_REG(0x51, 0x00),
	OV7670_REG(0x52, 0x3d),
	OV7670_REG(0x53, 0xa7),
	OV7670_REG(0x54, 0xe4),
	OV7670_REG(0x58, 0x9e),
	OV7670_REG(0x3d, 0xc0), /* COM13 */
	OV7670_REG(0x11, 0x01),
	OV7670_REG(0x17, 0x11), /* HSTART */
	OV7670_REG(0x18, 0x61), /* HSTOP */
	OV7670_REG(0x32, 0xa4), /* HREF */
	OV7670_REG(0x19, 0x03), /* VSTART */
	OV7670_REG(0x1a, 0x7b), /* VSTOP */
	OV7670_REG(0x03, 0x0a), /* VREF */
	OV7670_REG(0x0e, 0x61),
	OV7670_REG(0x0f, 0x4b),
	OV7670_REG(0x16, 0x02),
	OV7670_REG(0x1e, 0x34), /* MVFP */
	OV7670_REG(0x21, 0x02),
	OV7670_REG(0x22, 0x91),
	OV7670_REG(0x29, 0x07),
	OV7670_REG(0x33, 0x0b),
	OV7670_REG(0x35, 0x0b),
	OV7670_REG(0x37, 0x1d),
	OV7670_REG(0x38, 0x71),
	OV7670_REG(0x39, 0x2a),
	OV7670_REG(0x3c, 0x78),
	OV7670_REG(0x4d, 0x40),
	OV7670_REG(0x4e, 0x20),
	OV7670_REG(0x69, 0x00),
	OV7670_REG(0x6b, 0x0a), /* DBLV: PLL bypass */
	OV7670_REG(0x74, 0x10),
	OV7670_REG(0x8d, 0x4f),
	OV7670_REG(0x8e, 0x00),
	OV7670_REG(0x8f, 0x00),
	OV7670_REG(0x90, 0x00),
	OV7670_REG(0x91, 0x00),
	OV7670_REG(0x96, 0x00),
	OV7670_REG(0x9a, 0x00),
	OV7670_REG(0xb0, 0x84),
	OV7670_REG(0xb1, 0x0c),
	OV7670_REG(0xb2, 0x0e),
	OV7670_REG(0xb3, 0x82),
	OV7670_REG(0xb8, 0x0a),
	OV7670_REG(0x70, 0x3a), /* QVGA scaling */
	OV7670_REG(0x71, 0x35),
	OV7670_REG(0x72, 0x11),
	OV7670_REG(0x73, 0xf1),
	OV7670_REG(0xa2, 0x02),

	/* AEC/banding and auto-control tuning. */
	OV7670_REG(0x24, 0x95),
	OV7670_REG(0x25, 0x33),
	OV7670_REG(0x26, 0xe3),
	OV7670_REG(0x3b, 0x03),
	OV7670_REG(0xa5, 0x05),
	OV7670_REG(0xab, 0x07),
	OV7670_REG(0x9f, 0x78),
	OV7670_REG(0xa0, 0x68),
	OV7670_REG(0xa1, 0x03),
	OV7670_REG(0xa6, 0xd8),
	OV7670_REG(0xa7, 0xd8),
	OV7670_REG(0xa8, 0xf0),
	OV7670_REG(0xa9, 0x90),
	OV7670_REG(0xaa, 0x94),
	OV7670_REG(0x13, 0xff), /* COM8: AGC/AEC/AWB */

	/* AWB tuning. */
	OV7670_REG(0x01, 0x40),
	OV7670_REG(0x02, 0x60),
	OV7670_REG(0x43, 0x0a),
	OV7670_REG(0x44, 0xf0),
	OV7670_REG(0x45, 0x34),
	OV7670_REG(0x46, 0x58),
	OV7670_REG(0x47, 0x28),
	OV7670_REG(0x48, 0x3a),
	OV7670_REG(0x59, 0x88),
	OV7670_REG(0x5a, 0x88),
	OV7670_REG(0x5b, 0x44),
	OV7670_REG(0x5c, 0x67),
	OV7670_REG(0x5d, 0x49),
	OV7670_REG(0x5e, 0x0e),
	OV7670_REG(0x6c, 0x0a),
	OV7670_REG(0x6d, 0x55),
	OV7670_REG(0x6e, 0x11),
	OV7670_REG(0x6f, 0x9f),
	OV7670_REG(0x6a, 0x40),
	OV7670_REG(0x41, 0x38), /* COM16: AWB gain */

	/* Pixel correction and edge enhancement. */
	OV7670_REG(0x3f, 0x00),
	OV7670_REG(0x75, 0x05),
	OV7670_REG(0x76, 0xe1),
	OV7670_REG(0x4b, 0x09),
	OV7670_REG(0x77, 0x01),
	OV7670_REG(0xc9, 0x60),

	/* Gamma curve (0x7a..0x89). */
	OV7670_REG(0x7a, 0x20),
	OV7670_REG(0x7b, 0x10),
	OV7670_REG(0x7c, 0x1e),
	OV7670_REG(0x7d, 0x35),
	OV7670_REG(0x7e, 0x5a),
	OV7670_REG(0x7f, 0x69),
	OV7670_REG(0x80, 0x76),
	OV7670_REG(0x81, 0x80),
	OV7670_REG(0x82, 0x88),
	OV7670_REG(0x83, 0x8f),
	OV7670_REG(0x84, 0x96),
	OV7670_REG(0x85, 0xa3),
	OV7670_REG(0x86, 0xaf),
	OV7670_REG(0x87, 0xc4),
	OV7670_REG(0x88, 0xd7),
	OV7670_REG(0x89, 0xe8),
};

#define OV7670_DEFAULT_CONFIG_COUNT \
	(sizeof(ov7670_default_config) / sizeof(ov7670_default_config[0]))

typedef char ov7670_default_config_must_fit[
	(OV7670_DEFAULT_CONFIG_COUNT <= CAMERA_CONFIG_CAPACITY) ? 1 : -1];

/*
 * Runtime colour-only patches. Saturation is adjusted by scaling the signed
 * colour-matrix magnitudes while preserving MTXS (the coefficient sign bits).
 * COM13 keeps gamma/automatic UV saturation enabled, COM16 keeps matrix
 * doubling disabled, and SATCTR remains at the proven 0x60 from the default
 * table because its low nibble is an automatic-adjustment result.
 *
 * These deliberately avoid clock, window, scaling, and output-format
 * registers, so switching presets cannot change the expected frame geometry.
 */
static const uint32_t ov7670_color_normal[] = {
	OV7670_REG(0x3d, 0xc0), /* COM13: gamma + automatic UV saturation */
	OV7670_REG(0x41, 0x38), /* COM16: matrix doubling disabled */
	OV7670_REG(0x4f, 0xb3), /* MTX1 */
	OV7670_REG(0x50, 0xb3), /* MTX2 */
	OV7670_REG(0x51, 0x00), /* MTX3 */
	OV7670_REG(0x52, 0x3d), /* MTX4 */
	OV7670_REG(0x53, 0xa7), /* MTX5 */
	OV7670_REG(0x54, 0xe4), /* MTX6 */
	OV7670_REG(0x58, 0x9e), /* MTXS: coefficient signs */
};

static const uint32_t ov7670_color_muted[] = {
	OV7670_REG(0x3d, 0xc0),
	OV7670_REG(0x41, 0x38),
	OV7670_REG(0x4f, 0x5a), /* approximately 50% matrix magnitude */
	OV7670_REG(0x50, 0x5a),
	OV7670_REG(0x51, 0x00),
	OV7670_REG(0x52, 0x1f),
	OV7670_REG(0x53, 0x54),
	OV7670_REG(0x54, 0x72),
	OV7670_REG(0x58, 0x9e),
};

static const uint32_t ov7670_color_vivid[] = {
	OV7670_REG(0x3d, 0xc0),
	OV7670_REG(0x41, 0x38),
	OV7670_REG(0x4f, 0xff), /* approximately 150%, clipped for a clear test */
	OV7670_REG(0x50, 0xff),
	OV7670_REG(0x51, 0x00),
	OV7670_REG(0x52, 0x5c),
	OV7670_REG(0x53, 0xfb),
	OV7670_REG(0x54, 0xff),
	OV7670_REG(0x58, 0x9e),
};

#define OV7670_COLOR_CONFIG_COUNT \
	(sizeof(ov7670_color_normal) / sizeof(ov7670_color_normal[0]))

typedef char ov7670_color_configs_must_match[
	((sizeof(ov7670_color_muted) == sizeof(ov7670_color_normal)) &&
	 (sizeof(ov7670_color_vivid) == sizeof(ov7670_color_normal)) &&
	 (OV7670_COLOR_CONFIG_COUNT <= CAMERA_CONFIG_CAPACITY)) ? 1 : -1];

enum camera_color_preset {
	CAMERA_COLOR_NORMAL,
	CAMERA_COLOR_MUTED,
	CAMERA_COLOR_VIVID,
};

static enum camera_color_preset camera_color_preset_requested =
	CAMERA_COLOR_NORMAL;

// --------------------------------------------------------

extern uint32_t flashio_worker_begin;
extern uint32_t flashio_worker_end;

void flashio(uint8_t *data, int len, uint8_t wrencmd)
{
	uint32_t func[&flashio_worker_end - &flashio_worker_begin];

	uint32_t *src_ptr = &flashio_worker_begin;
	uint32_t *dst_ptr = func;

	while (src_ptr != &flashio_worker_end)
		*(dst_ptr++) = *(src_ptr++);

	((void(*)(uint8_t*, uint32_t, uint32_t))func)(data, len, wrencmd);
}

#ifdef HX8KDEMO
void set_flash_qspi_flag()
{
	uint8_t buffer[8];
	uint32_t addr_cr1v = 0x800002;

	// Read Any Register (RDAR 65h)
	buffer[0] = 0x65;
	buffer[1] = addr_cr1v >> 16;
	buffer[2] = addr_cr1v >> 8;
	buffer[3] = addr_cr1v;
	buffer[4] = 0; // dummy
	buffer[5] = 0; // rdata
	flashio(buffer, 6, 0);
	uint8_t cr1v = buffer[5];

	// Write Enable (WREN 06h) + Write Any Register (WRAR 71h)
	buffer[0] = 0x71;
	buffer[1] = addr_cr1v >> 16;
	buffer[2] = addr_cr1v >> 8;
	buffer[3] = addr_cr1v;
	buffer[4] = cr1v | 2; // Enable QSPI
	flashio(buffer, 5, 0x06);
}

void set_flash_latency(uint8_t value)
{
	reg_spictrl = (reg_spictrl & ~0x007f0000) | ((value & 15) << 16);

	uint32_t addr = 0x800004;
	uint8_t buffer_wr[5] = {0x71, addr >> 16, addr >> 8, addr, 0x70 | value};
	flashio(buffer_wr, 5, 0x06);
}

void set_flash_mode_spi()
{
	reg_spictrl = (reg_spictrl & ~0x00700000) | 0x00000000;
}

void set_flash_mode_dual()
{
	reg_spictrl = (reg_spictrl & ~0x00700000) | 0x00400000;
}

void set_flash_mode_quad()
{
	reg_spictrl = (reg_spictrl & ~0x00700000) | 0x00200000;
}

void set_flash_mode_qddr()
{
	reg_spictrl = (reg_spictrl & ~0x00700000) | 0x00600000;
}
#endif

#ifdef ICEBREAKER
void set_flash_qspi_flag()
{
	uint8_t buffer[8];

	// Read Configuration Registers (RDCR1 35h)
	buffer[0] = 0x35;
	buffer[1] = 0x00; // rdata
	flashio(buffer, 2, 0);
	uint8_t sr2 = buffer[1];

	// Write Enable Volatile (50h) + Write Status Register 2 (31h)
	buffer[0] = 0x31;
	buffer[1] = sr2 | 2; // Enable QSPI
	flashio(buffer, 2, 0x50);
}

void set_flash_mode_spi()
{
	reg_spictrl = (reg_spictrl & ~0x007f0000) | 0x00000000;
}

void set_flash_mode_dual()
{
	reg_spictrl = (reg_spictrl & ~0x007f0000) | 0x00400000;
}

void set_flash_mode_quad()
{
	reg_spictrl = (reg_spictrl & ~0x007f0000) | 0x00240000;
}

void set_flash_mode_qddr()
{
	reg_spictrl = (reg_spictrl & ~0x007f0000) | 0x00670000;
}

void enable_flash_crm()
{
	reg_spictrl |= 0x00100000;
}
#endif

// --------------------------------------------------------

void putchar(char c)
{
	if (c == '\n')
		putchar('\r');
	reg_uart_data = c;
}

void print(const char *p)
{
	while (*p)
		putchar(*(p++));
}

void print_hex(uint32_t v, int digits)
{
	for (int i = 7; i >= 0; i--) {
		char c = "0123456789abcdef"[(v >> (4*i)) & 15];
		if (c == '0' && i >= digits) continue;
		putchar(c);
		digits = i;
	}
}

void print_dec(uint32_t v)
{
	if (v >= 1000) {
		print(">=1000");
		return;
	}

	if      (v >= 900) { putchar('9'); v -= 900; }
	else if (v >= 800) { putchar('8'); v -= 800; }
	else if (v >= 700) { putchar('7'); v -= 700; }
	else if (v >= 600) { putchar('6'); v -= 600; }
	else if (v >= 500) { putchar('5'); v -= 500; }
	else if (v >= 400) { putchar('4'); v -= 400; }
	else if (v >= 300) { putchar('3'); v -= 300; }
	else if (v >= 200) { putchar('2'); v -= 200; }
	else if (v >= 100) { putchar('1'); v -= 100; }

	if      (v >= 90) { putchar('9'); v -= 90; }
	else if (v >= 80) { putchar('8'); v -= 80; }
	else if (v >= 70) { putchar('7'); v -= 70; }
	else if (v >= 60) { putchar('6'); v -= 60; }
	else if (v >= 50) { putchar('5'); v -= 50; }
	else if (v >= 40) { putchar('4'); v -= 40; }
	else if (v >= 30) { putchar('3'); v -= 30; }
	else if (v >= 20) { putchar('2'); v -= 20; }
	else if (v >= 10) { putchar('1'); v -= 10; }

	if      (v >= 9) { putchar('9'); v -= 9; }
	else if (v >= 8) { putchar('8'); v -= 8; }
	else if (v >= 7) { putchar('7'); v -= 7; }
	else if (v >= 6) { putchar('6'); v -= 6; }
	else if (v >= 5) { putchar('5'); v -= 5; }
	else if (v >= 4) { putchar('4'); v -= 4; }
	else if (v >= 3) { putchar('3'); v -= 3; }
	else if (v >= 2) { putchar('2'); v -= 2; }
	else if (v >= 1) { putchar('1'); v -= 1; }
	else putchar('0');
}

uint32_t camera_config_get_status()
{
	return reg_camera_config_status;
}

bool camera_config_load(const uint32_t *entries, uint32_t count)
{
	if (count == 0 || count > CAMERA_CONFIG_CAPACITY)
		return false;

	if (camera_config_get_status() & CAMERA_CONFIG_STATUS_BUSY)
		return false;

	for (uint32_t i = 0; i < count; i++)
		reg_camera_config_table[i] = entries[i];

	return true;
}

bool camera_config_apply(uint32_t count)
{
	if (count == 0 || count > CAMERA_CONFIG_CAPACITY)
		return false;

	if (camera_config_get_status() & CAMERA_CONFIG_STATUS_BUSY)
		return false;

	reg_camera_config_command =
		CAMERA_CONFIG_COMMAND_APPLY |
		CAMERA_CONFIG_COMMAND_CLEAR_REJECTED |
		count;

	/*
	 * REJECTED is cleared and APPLY is issued atomically. A very short table
	 * could finish before the status read below, so acceptance is determined
	 * from REJECTED rather than requiring BUSY to remain high.
	 */
	return (camera_config_get_status() &
		CAMERA_CONFIG_STATUS_REJECTED) == 0;
}

bool camera_configure(const uint32_t *entries, uint32_t count)
{
	if (!camera_config_load(entries, count))
		return false;

	return camera_config_apply(count);
}

bool camera_configure_default()
{
	if (!camera_configure(ov7670_default_config,
			      OV7670_DEFAULT_CONFIG_COUNT))
		return false;

	camera_color_preset_requested = CAMERA_COLOR_NORMAL;
	return true;
}

const char *camera_color_preset_name(enum camera_color_preset preset)
{
	switch (preset) {
	case CAMERA_COLOR_NORMAL:
		return "normal";
	case CAMERA_COLOR_MUTED:
		return "muted";
	case CAMERA_COLOR_VIVID:
		return "vivid";
	default:
		return "unknown";
	}
}

bool camera_configure_color(enum camera_color_preset preset)
{
	const uint32_t *entries;

	switch (preset) {
	case CAMERA_COLOR_NORMAL:
		entries = ov7670_color_normal;
		break;
	case CAMERA_COLOR_MUTED:
		entries = ov7670_color_muted;
		break;
	case CAMERA_COLOR_VIVID:
		entries = ov7670_color_vivid;
		break;
	default:
		return false;
	}

	if (!camera_configure(entries, OV7670_COLOR_CONFIG_COUNT))
		return false;

	camera_color_preset_requested = preset;
	return true;
}

void cmd_camera_color(enum camera_color_preset preset)
{
	if (camera_configure_color(preset)) {
		print("Camera colour preset ");
		print(camera_color_preset_name(preset));
		print(" accepted.\n");
	} else {
		print("Camera configuration busy or rejected.\n");
	}
}

void camera_set_encryption(bool enable)
{
	uint32_t control = reg_camera_control;

	if (enable)
		control |= CAMERA_CTRL_ENCRYPT;
	else
		control &= ~CAMERA_CTRL_ENCRYPT;

	reg_camera_control = control;
}

uint32_t camera_get_status()
{
	return reg_camera_status;
}

void cmd_camera_status()
{
	uint32_t control = reg_camera_control;
	uint32_t status = camera_get_status();
	uint32_t config_status = camera_config_get_status();

	print("Camera request: ");
	print((control & CAMERA_CTRL_ENCRYPT) ? "encrypt\n" : "bypass\n");

	print("Current frame: ");
	print((status & CAMERA_STATUS_ENCRYPT_ACTIVE) ?
			"encrypted\n" : "bypass\n");

	print("Stream ready: ");
	print((status & CAMERA_STATUS_STREAM_READY) ? "yes\n" : "no\n");

	print("Stream active: ");
	print((status & CAMERA_STATUS_STREAM_ACTIVE) ? "yes\n" : "no\n");

	print("Stream fault: ");
	print((status & CAMERA_STATUS_STREAM_FAULT) ? "yes\n" : "no\n");

	print("CPU trap: ");
	print((status & CAMERA_STATUS_CPU_TRAP) ? "yes\n" : "no\n");

	print("Camera config: ");
	if (config_status & CAMERA_CONFIG_STATUS_BUSY)
		print("applying\n");
	else if (config_status & CAMERA_CONFIG_STATUS_DONE)
		print("ready\n");
	else
		print("not applied\n");

	print("Config index/count: ");
	print_dec((config_status & CAMERA_CONFIG_STATUS_INDEX_MASK) >>
		  CAMERA_CONFIG_STATUS_INDEX_SHIFT);
	print("/");
	print_dec(reg_camera_config_command & 0x1ffu);
	print("\n");

	print("Config rejected: ");
	print((config_status & CAMERA_CONFIG_STATUS_REJECTED) ? "yes\n" : "no\n");

	print("Colour preset request: ");
	print(camera_color_preset_name(camera_color_preset_requested));
	print("\n");
}

char getchar_prompt(char *prompt)
{
	int32_t c = -1;

	uint32_t cycles_begin, cycles_now, cycles;
	__asm__ volatile ("rdcycle %0" : "=r"(cycles_begin));

	if (prompt)
		print(prompt);

	while (c == -1) {
		__asm__ volatile ("rdcycle %0" : "=r"(cycles_now));
		cycles = cycles_now - cycles_begin;
		if (cycles > PROMPT_TIMEOUT_CYCLES) {
			if (prompt)
				print(prompt);
			cycles_begin = cycles_now;
		}
		c = reg_uart_data;
	}

	return c;
}

char getchar()
{
	return getchar_prompt(0);
}

void cmd_print_spi_state()
{
	print("SPI State:\n");

	print("  LATENCY ");
	print_dec((reg_spictrl >> 16) & 15);
	print("\n");

	print("  DDR ");
	if ((reg_spictrl & (1 << 22)) != 0)
		print("ON\n");
	else
		print("OFF\n");

	print("  QSPI ");
	if ((reg_spictrl & (1 << 21)) != 0)
		print("ON\n");
	else
		print("OFF\n");

	print("  CRM ");
	if ((reg_spictrl & (1 << 20)) != 0)
		print("ON\n");
	else
		print("OFF\n");
}

uint32_t xorshift32(uint32_t *state)
{
	/* Algorithm "xor" from p. 4 of Marsaglia, "Xorshift RNGs" */
	uint32_t x = *state;
	x ^= x << 13;
	x ^= x >> 17;
	x ^= x << 5;
	*state = x;

	return x;
}

void cmd_memtest()
{
	int cyc_count = 5;
	int stride = 256;
	uint32_t state;

	volatile uint32_t *base_word = (uint32_t *) 0;
	volatile uint8_t *base_byte = (uint8_t *) 0;

	print("Running memtest ");

	// Walk in stride increments, word access
	for (int i = 1; i <= cyc_count; i++) {
		state = i;

		for (int word = 0; word < MEM_TOTAL / sizeof(int); word += stride) {
			*(base_word + word) = xorshift32(&state);
		}

		state = i;

		for (int word = 0; word < MEM_TOTAL / sizeof(int); word += stride) {
			if (*(base_word + word) != xorshift32(&state)) {
				print(" ***FAILED WORD*** at ");
				print_hex(4*word, 4);
				print("\n");
				return;
			}
		}

		print(".");
	}

	// Byte access
	for (int byte = 0; byte < 128; byte++) {
		*(base_byte + byte) = (uint8_t) byte;
	}

	for (int byte = 0; byte < 128; byte++) {
		if (*(base_byte + byte) != (uint8_t) byte) {
			print(" ***FAILED BYTE*** at ");
			print_hex(byte, 4);
			print("\n");
			return;
		}
	}

	print(" passed\n");
}

// --------------------------------------------------------

void cmd_read_flash_id()
{
	uint8_t buffer[17] = { 0x9F, /* zeros */ };
	flashio(buffer, 17, 0);

	for (int i = 1; i <= 16; i++) {
		putchar(' ');
		print_hex(buffer[i], 2);
	}
	putchar('\n');
}

// --------------------------------------------------------

#ifdef HX8KDEMO
uint8_t cmd_read_flash_regs_print(uint32_t addr, const char *name)
{
	set_flash_latency(8);

	uint8_t buffer[6] = {0x65, addr >> 16, addr >> 8, addr, 0, 0};
	flashio(buffer, 6, 0);

	print("0x");
	print_hex(addr, 6);
	print(" ");
	print(name);
	print(" 0x");
	print_hex(buffer[5], 2);
	print("\n");

	return buffer[5];
}

void cmd_read_flash_regs()
{
	print("\n");
	uint8_t sr1v = cmd_read_flash_regs_print(0x800000, "SR1V");
	uint8_t sr2v = cmd_read_flash_regs_print(0x800001, "SR2V");
	uint8_t cr1v = cmd_read_flash_regs_print(0x800002, "CR1V");
	uint8_t cr2v = cmd_read_flash_regs_print(0x800003, "CR2V");
	uint8_t cr3v = cmd_read_flash_regs_print(0x800004, "CR3V");
	uint8_t vdlp = cmd_read_flash_regs_print(0x800005, "VDLP");
}
#endif

#ifdef ICEBREAKER
uint8_t cmd_read_flash_reg(uint8_t cmd)
{
	uint8_t buffer[2] = {cmd, 0};
	flashio(buffer, 2, 0);
	return buffer[1];
}

void print_reg_bit(int val, const char *name)
{
	for (int i = 0; i < 12; i++) {
		if (*name == 0)
			putchar(' ');
		else
			putchar(*(name++));
	}

	putchar(val ? '1' : '0');
	putchar('\n');
}

void cmd_read_flash_regs()
{
	putchar('\n');

	uint8_t sr1 = cmd_read_flash_reg(0x05);
	uint8_t sr2 = cmd_read_flash_reg(0x35);
	uint8_t sr3 = cmd_read_flash_reg(0x15);

	print_reg_bit(sr1 & 0x01, "S0  (BUSY)");
	print_reg_bit(sr1 & 0x02, "S1  (WEL)");
	print_reg_bit(sr1 & 0x04, "S2  (BP0)");
	print_reg_bit(sr1 & 0x08, "S3  (BP1)");
	print_reg_bit(sr1 & 0x10, "S4  (BP2)");
	print_reg_bit(sr1 & 0x20, "S5  (TB)");
	print_reg_bit(sr1 & 0x40, "S6  (SEC)");
	print_reg_bit(sr1 & 0x80, "S7  (SRP)");
	putchar('\n');

	print_reg_bit(sr2 & 0x01, "S8  (SRL)");
	print_reg_bit(sr2 & 0x02, "S9  (QE)");
	print_reg_bit(sr2 & 0x04, "S10 ----");
	print_reg_bit(sr2 & 0x08, "S11 (LB1)");
	print_reg_bit(sr2 & 0x10, "S12 (LB2)");
	print_reg_bit(sr2 & 0x20, "S13 (LB3)");
	print_reg_bit(sr2 & 0x40, "S14 (CMP)");
	print_reg_bit(sr2 & 0x80, "S15 (SUS)");
	putchar('\n');

	print_reg_bit(sr3 & 0x01, "S16 ----");
	print_reg_bit(sr3 & 0x02, "S17 ----");
	print_reg_bit(sr3 & 0x04, "S18 (WPS)");
	print_reg_bit(sr3 & 0x08, "S19 ----");
	print_reg_bit(sr3 & 0x10, "S20 ----");
	print_reg_bit(sr3 & 0x20, "S21 (DRV0)");
	print_reg_bit(sr3 & 0x40, "S22 (DRV1)");
	print_reg_bit(sr3 & 0x80, "S23 (HOLD)");
	putchar('\n');
}
#endif

// --------------------------------------------------------

uint32_t cmd_benchmark(bool verbose, uint32_t *instns_p)
{
	uint8_t data[256];
	uint32_t *words = (void*)data;

	uint32_t x32 = 314159265;

	uint32_t cycles_begin, cycles_end;
	uint32_t instns_begin, instns_end;
	__asm__ volatile ("rdcycle %0" : "=r"(cycles_begin));
	__asm__ volatile ("rdinstret %0" : "=r"(instns_begin));

	for (int i = 0; i < 20; i++)
	{
		for (int k = 0; k < 256; k++)
		{
			x32 ^= x32 << 13;
			x32 ^= x32 >> 17;
			x32 ^= x32 << 5;
			data[k] = x32;
		}

		for (int k = 0, p = 0; k < 256; k++)
		{
			if (data[k])
				data[p++] = k;
		}

		for (int k = 0, p = 0; k < 64; k++)
		{
			x32 = x32 ^ words[k];
		}
	}

	__asm__ volatile ("rdcycle %0" : "=r"(cycles_end));
	__asm__ volatile ("rdinstret %0" : "=r"(instns_end));

	if (verbose)
	{
		print("Cycles: 0x");
		print_hex(cycles_end - cycles_begin, 8);
		putchar('\n');

		print("Instns: 0x");
		print_hex(instns_end - instns_begin, 8);
		putchar('\n');

		print("Chksum: 0x");
		print_hex(x32, 8);
		putchar('\n');
	}

	if (instns_p)
		*instns_p = instns_end - instns_begin;

	return cycles_end - cycles_begin;
}

// --------------------------------------------------------

#ifdef HX8KDEMO
void cmd_benchmark_all()
{
	uint32_t instns = 0;

	print("default        ");
	reg_spictrl = (reg_spictrl & ~0x00700000) | 0x00000000;
	print(": ");
	print_hex(cmd_benchmark(false, &instns), 8);
	putchar('\n');

	for (int i = 8; i > 0; i--)
	{
		print("dspi-");
		print_dec(i);
		print("         ");

		set_flash_latency(i);
		reg_spictrl = (reg_spictrl & ~0x00700000) | 0x00400000;

		print(": ");
		print_hex(cmd_benchmark(false, &instns), 8);
		putchar('\n');
	}

	for (int i = 8; i > 0; i--)
	{
		print("dspi-crm-");
		print_dec(i);
		print("     ");

		set_flash_latency(i);
		reg_spictrl = (reg_spictrl & ~0x00700000) | 0x00500000;

		print(": ");
		print_hex(cmd_benchmark(false, &instns), 8);
		putchar('\n');
	}

	for (int i = 8; i > 0; i--)
	{
		print("qspi-");
		print_dec(i);
		print("         ");

		set_flash_latency(i);
		reg_spictrl = (reg_spictrl & ~0x00700000) | 0x00200000;

		print(": ");
		print_hex(cmd_benchmark(false, &instns), 8);
		putchar('\n');
	}

	for (int i = 8; i > 0; i--)
	{
		print("qspi-crm-");
		print_dec(i);
		print("     ");

		set_flash_latency(i);
		reg_spictrl = (reg_spictrl & ~0x00700000) | 0x00300000;

		print(": ");
		print_hex(cmd_benchmark(false, &instns), 8);
		putchar('\n');
	}

	for (int i = 8; i > 0; i--)
	{
		print("qspi-ddr-");
		print_dec(i);
		print("     ");

		set_flash_latency(i);
		reg_spictrl = (reg_spictrl & ~0x00700000) | 0x00600000;

		print(": ");
		print_hex(cmd_benchmark(false, &instns), 8);
		putchar('\n');
	}

	for (int i = 8; i > 0; i--)
	{
		print("qspi-ddr-crm-");
		print_dec(i);
		print(" ");

		set_flash_latency(i);
		reg_spictrl = (reg_spictrl & ~0x00700000) | 0x00700000;

		print(": ");
		print_hex(cmd_benchmark(false, &instns), 8);
		putchar('\n');
	}

	print("instns         : ");
	print_hex(instns, 8);
	putchar('\n');
}
#endif

#ifdef ICEBREAKER
void cmd_benchmark_all()
{
	uint32_t instns = 0;

	print("default   ");
	set_flash_mode_spi();
	print_hex(cmd_benchmark(false, &instns), 8);
	putchar('\n');

	print("dual      ");
	set_flash_mode_dual();
	print_hex(cmd_benchmark(false, &instns), 8);
	putchar('\n');

	// print("dual-crm  ");
	// enable_flash_crm();
	// print_hex(cmd_benchmark(false, &instns), 8);
	// putchar('\n');

	print("quad      ");
	set_flash_mode_quad();
	print_hex(cmd_benchmark(false, &instns), 8);
	putchar('\n');

	print("quad-crm  ");
	enable_flash_crm();
	print_hex(cmd_benchmark(false, &instns), 8);
	putchar('\n');

	print("qddr      ");
	set_flash_mode_qddr();
	print_hex(cmd_benchmark(false, &instns), 8);
	putchar('\n');

	print("qddr-crm  ");
	enable_flash_crm();
	print_hex(cmd_benchmark(false, &instns), 8);
	putchar('\n');

}
#endif

void cmd_echo()
{
	print("Return to menu by sending '!'\n\n");
	char c;
	while ((c = getchar()) != '!')
		putchar(c);
}

// --------------------------------------------------------

#ifdef FIRMWARE_SMOKE_TEST
void main()
{
	reg_camera_config_command = CAMERA_CONFIG_COMMAND_APPLY | 257u;
	if ((camera_config_get_status() &
	     (CAMERA_CONFIG_STATUS_BUSY | CAMERA_CONFIG_STATUS_REJECTED)) !=
	    CAMERA_CONFIG_STATUS_REJECTED)
		while (1) { /* invalid-count rejection smoke-test failure */ }

	if (!camera_configure_default())
		while (1) { /* configuration MMIO smoke-test failure */ }
	camera_set_encryption(true);
	while (1) { /* synthesized flash-boot/MMIO smoke test */ }
}
#else
void main()
{
	reg_uart_clkdiv = UART_CLKDIV;
	print("Booting..\n");

	set_flash_qspi_flag();

	if (!camera_configure_default())
		print("Camera configuration request was rejected.\n");

	while (getchar_prompt("Press ENTER to continue..\n") != '\r') { /* wait */ }

	print("\n");
	print("  ____  _          ____         ____\n");
	print(" |  _ \\(_) ___ ___/ ___|  ___  / ___|\n");
	print(" | |_) | |/ __/ _ \\___ \\ / _ \\| |\n");
	print(" |  __/| | (_| (_) |__) | (_) | |___\n");
	print(" |_|   |_|\\___\\___/____/ \\___/ \\____|\n");
	print("\n");

	print("Total memory: ");
	print_dec(MEM_TOTAL / 1024);
	print(" KiB\n");
	print("\n");

	//cmd_memtest(); // test overwrites bss and data memory
	print("\n");

	cmd_print_spi_state();
	print("\n");

	while (1)
	{
		print("\n");

		print("Select an action:\n");
		print("\n");
		print("   [1] Read SPI Flash ID\n");
		print("   [2] Read SPI Config Regs\n");
		print("   [3] Switch to default mode\n");
		print("   [4] Switch to Dual I/O mode\n");
		print("   [5] Switch to Quad I/O mode\n");
		print("   [6] Switch to Quad DDR mode\n");
		print("   [7] Toggle continuous read mode\n");
		print("   [9] Run simplistic benchmark\n");
		print("   [0] Benchmark all configs\n");
		print("   [M] Run Memtest\n");
		print("   [S] Print SPI state\n");
		print("   [e] Echo UART\n");
		print("   [E] Encrypted video\n");
		print("   [B] Decrypted video\n");
		print("   [C] Print camera status\n");
		print("   [R] Reload default camera configuration\n");
		print("   [N] Normal camera colours\n");
		print("   [L] Muted camera colours\n");
		print("   [V] Vivid camera colours\n");
		print("\n");

		for (int rep = 10; rep > 0; rep--)
		{
			print("Command> ");
			char cmd = getchar();
			if (cmd > 32 && cmd < 127)
				putchar(cmd);
			print("\n");

			switch (cmd)
			{
			case '1':
				cmd_read_flash_id();
				break;
			case '2':
				cmd_read_flash_regs();
				break;
			case '3':
				set_flash_mode_spi();
				break;
			case '4':
				set_flash_mode_dual();
				break;
			case '5':
				set_flash_mode_quad();
				break;
			case '6':
				set_flash_mode_qddr();
				break;
			case '7':
				reg_spictrl = reg_spictrl ^ 0x00100000;
				break;
			case '9':
				cmd_benchmark(true, 0);
				break;
			case '0':
				cmd_benchmark_all();
				break;
			case 'M':
				cmd_memtest();
				break;
			case 'S':
				cmd_print_spi_state();
				break;
			case 'e':
				cmd_echo();
				break;
			case 'E':
				camera_set_encryption(true);
				print("Encryption requested; applies at the next accepted frame.\n");
				break;
			case 'B':
				camera_set_encryption(false);
				print("Bypass requested; applies at the next accepted frame.\n");
				break;
			case 'C':
				cmd_camera_status();
				break;
			case 'R':
				if (camera_configure_default())
					print("Camera configuration accepted.\n");
				else
					print("Camera configuration busy or rejected.\n");
				break;
			case 'N':
				cmd_camera_color(CAMERA_COLOR_NORMAL);
				break;
			case 'L':
				cmd_camera_color(CAMERA_COLOR_MUTED);
				break;
			case 'V':
				cmd_camera_color(CAMERA_COLOR_VIVID);
				break;
			default:
				continue;
			}

			break;
		}
	}
}
#endif
