# OV7670 → ST7789 240×280, iCEBreaker, no CPU

Live camera video straight to the panel: the ST7789's internal GRAM is the
framebuffer, the FPGA only rate-matches. Total image memory on the FPGA is
**one 256×16 FIFO (4 kbit, one EBR)** — about 0.4% of a framebuffer.

```
12 MHz ─ PLL ─ 48 MHz ──┬─ /2 → SCK  24 MHz ──────────────► ST7789
                        └─ /2 → XCLK 24 MHz → OV7670
                               CLKRC /3 → f_int 8 MHz
                               QVGA, PCLK/2 → PCLK 4 MHz (sampled as data)
```

One display line (280×16 SCK) fits in one camera line (1568 f_int cycles):
24 ≥ 2.857 × 8 MHz, ~5% slack. Frame rate **10.0 fps**, display genlocked to
the camera. Panel runs **landscape** (MADCTL 0xA0), window CASET 20..299 /
RASET 0..239; the camera's 320-pixel QVGA lines are center-cropped to 280 —
an exact 1:1 map, no scaler.

Verified in this repo: `make sim` runs an end-to-end smoke test (SCCB init →
panel init → two frames; checks exact byte counts, the crop, and that the
FIFO never overflows). Synthesis/PnR with yosys + nextpnr closes timing at
48 MHz (50.3 MHz achieved), 677/5280 LCs, 2/30 EBRs (pixel FIFO + init ROM).

## Files

| file | contents |
|---|---|
| `top.v` | PLL, POR, XCLK, open-drain SIOD (SB_IO + pull-up), wiring, LEDs |
| `cam_init.v` | SCCB master + OV7670 register ROM (see deltas below) |
| `cam_capture.v` | PCLK-as-data sampling, RGB565 assembly, 320→280 crop |
| `pixel_fifo.v` | the one EBR |
| `st7789_ctrl.v` | reset dance, init ROM, per-frame window, pixel streaming |
| `spi8.v` | gapless mode-0 byte engine (16 clk/byte back-to-back) |
| `icebreaker.pcf`, `Makefile`, `sim/tb_smoke.v` | build + smoke test |

## Wiring

Camera module → PMOD1A/1B, panel → PMOD2 (all 3.3 V; power from the PMOD
3V3/GND pins; keep XCLK and PCLK jumpers short).

| OV7670 pin | FPGA signal | PMOD pos | | ST7789 pin | FPGA signal | PMOD pos |
|---|---|---|---|---|---|---|
| D0–D7 | CAM_D[0..7] | 1A: 1,2,3,4,7,8,9,10 | | SCL/SCK | LCD_SCK | 2: 1 |
| XCLK | CAM_XCLK | 1B: 1 | | SDA/MOSI | LCD_MOSI | 2: 2 |
| PCLK | CAM_PCLK | 1B: 2 | | DC | LCD_DC | 2: 3 |
| HREF | CAM_HREF | 1B: 3 | | CS | LCD_CS_N | 2: 4 |
| VSYNC | CAM_VSYNC | 1B: 4 | | RES | LCD_RES_N | 2: 7 |
| SIOC | CAM_SIOC | 1B: 7 | | BLK | LCD_BL | 2: 8 |
| SIOD | CAM_SIOD | 1B: 8 | | | | |
| RESET# | CAM_RST_N | 1B: 9 | | | | |
| PWDN | CAM_PWDN | 1B: 10 | | | | |

SIOD uses the FPGA's internal pull-up; most OV7670 breakouts also have their
own — both together is fine. If SCCB ever proves flaky over long jumpers, an
external 4.7 kΩ to 3.3 V on SIOC/SIOD settles it.

## Build / flash

```
make        # yosys → nextpnr (--freq 48) → icepack
make prog   # iceprog
make sim    # iverilog smoke test
```

## Bring-up

1. Power up with both modules connected. The backlight stays **off** during
   panel init and turns on ~0.5 s after configuration.
2. **Green LED on** = camera SCCB done AND panel init done → streaming.
3. **Red LED** = the pixel FIFO overflowed at least once since reset. It
   should never light; if it does, the clock plan is off (check CLKRC/DBLV
   wiring of your module, i.e. that a stray camera PLL isn't enabled).
4. User button = full reset (re-runs both init sequences).

## Knobs

**Orientation.** If the image is mirrored or upside down (module batches
vary), change one ROM byte: `st7789_ctrl.v` init ROM index 13, `16'h41A0` →
`16'h4160` (MADCTL 0x60, the other landscape). Camera-side MVFP (SCCB reg
0x1E) is the alternative lever.

**Colors wrong (red/blue smearing, green tint).** The two RGB565 bytes are
swapped somewhere in the chain on some module revisions. Swap the assembly in
`cam_capture.v`: `{hi_byte, d_s1}` → `{d_s1, hi_byte}`.

**48 MHz margin.** Timing closes at 50.3 MHz, but if a modified build ever
misses, the whole system scales coherently to 36 MHz: in `top.v` set PLL
`DIVF = 7'b0101111` (icepll -i 12 -o 36), and nothing else — SCK 18 / XCLK 18
→ f_int 6 MHz, ratio 3.0 ≥ 2.857, 7.5 fps. The ms/SCCB tick constants are
parameters derived from the clock, so pass `CLK_HZ`/`TICK_DIV` accordingly
(`36_000_000` and `90`).

## Camera register table: what changed and why

The SCCB ROM is the proven register set verbatim, except:

| reg | was | now | why |
|---|---|---|---|
| CLKRC 0x11 | 0x00 | 0x02 | f_int = XCLK/3 = 8 MHz — the rate-match anchor |
| DBLV 0x6B | 0x4A | 0x0A | ×4 PLL **off** (×4 would quadruple every rate) |
| COM3 0x0C | 0x00 | 0x04 | DCW enable \ |
| COM14 0x3E | 0x00 | 0x19 | manual scale, PCLK/2 — QVGA 320×240 |
| 0x70–0x73, 0xA2 | — | added | canonical QVGA scaling set / |
| RGB444 0x8C | 0x03 | 0x00 | RGB444 mode **off** \ the old table left the |
| COM15 0x40 | 0xF0 | 0xD0 | true RGB565, full range / sensor in 444/555 |

The last two matter: the previous pipeline tolerated whatever byte format the
sensor emitted because software unpacked it, but the panel consumes raw
RGB565 — so the sensor must actually be in RGB565 mode.
