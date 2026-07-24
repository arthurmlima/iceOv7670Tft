# iCEBreaker OV7670 → ST7789 live camera stream

This project extends the known-working ST7789 test-pattern design with an
OV7670 camera. It is pure Verilog: no CPU, no external RAM, and no full
framebuffer.

The data path is:

```text
OV7670 RGB565 → center crop 320×240 to 280×240
              → 256×16 synchronous FIFO (one iCE40 EBR)
              → ST7789 RAMWR stream
```

The ST7789's own GRAM is the framebuffer. The FPGA FIFO only absorbs the
difference between the camera's bursty active-video timing and the display's
constant SPI drain rate.

## Clock plan

The PLL is at 39.00 MHz -- the frequency this design reproducibly closes
timing on with real margin. Speed came instead from rebuilding the SPI
engine to run at a full system-clock rate rather than half of it, and then
using that headroom to tighten the camera's pixel clock:

| Clock | Value | Source |
|---|---:|---|
| Board oscillator | 12.000 MHz | iCEBreaker |
| FPGA system clock | 39.000 MHz | `SB_PLL40_PAD` |
| ST7789 SCLK | 39.000 MHz | system clock (DDR SPI engine) |
| OV7670 XCLK | 19.500 MHz | system clock / 2 |
| OV7670 internal clock | 9.750 MHz | XCLK / 2, `CLKRC=0x01` |
| OV7670 PCLK | 4.875 MHz | QVGA scaling, PCLK / 2 |

The PLL settings are `DIVR=0`, `DIVF=51`, `DIVQ=4`, `FILTER_RANGE=1`. Raising
the PLL itself was tried (42.00 MHz survived on its own with 45.00 MHz max),
but once the SPI engine below was rebuilt with SB_IO DDR/NEG_TRIGGER cells,
the extra IO logic shifted placement enough that 42.00 MHz only closed with a
0.17% margin -- reproducible, but too close to real-hardware PVT variation to
trust. 39.00 MHz with the new SPI engine closes with 43.25 MHz max (10.9%
margin), so the PLL stayed at the safe baseline and the win came from the SPI
engine and `CLKRC` instead.

`spi_stream_tx` previously needed two `clk_sys` cycles per SPI bit (one to
raise SCLK, one to lower it -- the fastest a plain single-edge toggle
register can do). It's now built from an `SB_IO` DDR output cell for SCLK
(one discrete high-then-low pulse per `clk_sys` cycle) plus `NEG_TRIGGER`
registered cells for MOSI/DC, giving each data bit a half-`clk_sys`-cycle
setup margin ahead of the SCLK edge that samples it -- the same relationship
the old design got from a full spare cycle, just compressed into DDR/negedge
timing instead of an extra FSM cycle. This phase relationship was verified in
simulation against the real iCE40 `SB_IO` behavioral model (not just derived
by hand) before being trusted on hardware, including checking `tx_done`
can't let CS cut off the last bit's pulse mid-transmission.

Doubling the display's drain rate this way let `CLKRC` tighten from /3 to /2.
`CLKRC=/1` (bypass) was also checked and rejected -- it makes the camera
faster than the display can drain even at the new SPI rate. Since
`CAM_INT_HZ = sys_clk/4` and `SPI_HZ = sys_clk` at the chosen settings, the
line-time margin ratio is scale-invariant with `sys_clk`: raising or lowering
the PLL later won't need `CLKRC` retuned, only the numbers in the proof below.

## Line-rate proof

Using the OV7670 QVGA timing assumption from the preliminary design
(1568 internal-clock cycles per line):

```text
camera line time = 1568 / 9.750 MHz = 160.82 us
display line time = 280 × 16 / 39.000 MHz = 114.87 us
line slack        = 45.95 us = 28.6%
```

The center crop retains camera columns 20 through 299. With the display now
draining faster than before, the active-video input and output pixel rates
work out algebraically equal (`CAM_INT_HZ/4 == SPI_HZ/16`), so the FIFO
barely moves during the retained active region instead of the roughly
70-pixel peak of the previous (sys_clk/2 SPI) build. The 256-pixel FIFO is
now far larger than steady-state margin requires but costs nothing extra to
keep.

The expected frame rate is approximately 12.19 fps if the preliminary
design's 10 fps at an 8 MHz internal camera clock scales linearly.

Run:

```sh
python3 timing_check.py
```

to print the exact values used by this repository.

## Display geometry

The panel is operated in landscape mode:

- `MADCTL = 0xA0`
- visible stream: 280 × 240 pixels
- `CASET = 20..299`
- `RASET = 0..239`
- camera input: QVGA 320 × 240 (`COM7=0x14`)
- crop: remove 20 pixels from each horizontal side
- pixel format: RGB565, high byte first

The ST7789 hardware reset timing and initialization register sequence are
retained from the working display project.

## Wiring

The iCEBreaker PMOD signals are 3.3 V. Use an OV7670 breakout explicitly
rated for 3.3 V logic. A bare sensor requires its specified rails and suitable
level translation.

### ST7789 on PMOD 1B

These are the same FPGA pins used by the working display design.

| ST7789 | iCEBreaker | FPGA pin |
|---|---|---:|
| SCL/SCK | P1B1 | 43 |
| SDA/MOSI | P1B2 | 38 |
| RES | P1B3 | 34 |
| DC | P1B4 | 31 |
| CS | P1B7 | 42 |
| BLK | P1B8 | 36 |

### OV7670 data on PMOD 1A

| OV7670 | iCEBreaker | FPGA pin |
|---|---|---:|
| D0 | P1A1 | 4 |
| D1 | P1A2 | 2 |
| D2 | P1A3 | 47 |
| D3 | P1A4 | 45 |
| D4 | P1A7 | 3 |
| D5 | P1A8 | 48 |
| D6 | P1A9 | 46 |
| D7 | P1A10 | 44 |

### OV7670 control on PMOD 2

The stock LED/button wing uses PMOD 2. Remove it or expose that connector before
connecting the camera.

| OV7670 | iCEBreaker | FPGA pin |
|---|---|---:|
| XCLK | P2_1 | 27 |
| PCLK | P2_2 | 25 |
| HREF | P2_3 | 21 |
| VSYNC | P2_4 | 19 |
| SIOC | P2_7 | 26 |
| SIOD | P2_8 | 23 |
| RESET# | P2_9 | 20 |
| PWDN | P2_10 | 18 |

`SIOD` is open-drain and uses the FPGA's internal pull-up. A short external
4.7 kΩ pull-up to 3.3 V may help if SCCB wiring is long. `SIOC` is push-pull.

Connect the camera and display grounds together. Power each module according to
its breakout-board requirements, and do not expose FPGA pins to more than 3.3 V.

## Build and program

Required tools:

- `yosys`
- `nextpnr-ice40`
- `icepack`
- `iceprog`

Commands:

```sh
make
make prog
```

The build targets `up5k-sg48` and asks nextpnr to close timing at 39.00 MHz.

## Status LEDs and reset

- Green LED on: camera SCCB initialization and ST7789 initialization completed.
- Red LED on: FIFO overflow, FIFO underflow, or a new camera frame arrived
  before the previous panel transfer completed.
- User button: full camera and panel reset/reinitialization.

The backlight remains off until panel initialization completes.

## Important files

| File | Function |
|---|---|
| `icebreaker_st7789_top.v` | PLL, reset, XCLK, SCCB I/O, integration, LEDs |
| `cam_init.v` | OV7670 SCCB register sequence with `/2` clock setting |
| `cam_capture.v` | synchronized PCLK sampling, RGB565 assembly, 320→280 crop |
| `pixel_fifo.v` | 256×16 single-clock rate-matching FIFO |
| `st7789_camera_ctrl.v` | panel reset/init/window and FIFO pixel streaming |
| `spi_stream_tx.v` | gapless mode-0 byte transmitter, DDR SCLK at 39.0 MHz |
| `st7789_init_rom.v` | known-working panel initialization sequence |
| `icebreaker.pcf` | display and camera pin assignments |
| `timing_check.py` | clock, line-slack, and FIFO-burst calculations |

The old `st7789_rgb_test.v`, `rgb_test_pattern.v`, and `spi_master_tx.v` are
retained as references but are not included in the camera build.

## Bring-up checks

1. Verify `cam_xclk` is approximately 19.500 MHz.
2. Verify `cam_sioc` activity after reset and that the green LED eventually
   turns on.
3. Verify `cam_pclk` is approximately 4.875 MHz during active video. A much
   higher value usually means `CLKRC` or `DBLV` did not take effect.
4. Verify `tft_scl` (SCLK) is a clean ~39 MHz square wave while streaming,
   with no runt/merged pulses -- this is the first place a DDR phase mistake
   would show up. If the panel shows garbled or shifted color data instead of
   a recognizable (if unsynced) image, suspect the SCLK/MOSI/DC DDR timing in
   `spi_stream_tx.v` before anything else; the previous sys_clk/2 SPI engine
   (see git history) is the known-good fallback if this needs to be ruled out.
5. If the image colors are byte-swapped, change
   `{hi_byte, d_s1}` to `{d_s1, hi_byte}` in `cam_capture.v`.
6. If the image is mirrored or upside down, try ST7789 `MADCTL=0x60` or adjust
   OV7670 `MVFP` register `0x1E`.
7. If the red LED turns on, probe XCLK/PCLK first; the design depends on the
   camera accepting `CLKRC=0x01` and `DBLV=0x0A`.

## Verification note

The RTL is organized for yosys/nextpnr and has been statically reviewed in this
package. Run `make` on the target toolchain to confirm synthesis, EBR inference,
pin placement, and final timing on the installed tool versions.

The DDR SPI engine in `spi_stream_tx.v` additionally has behavior-level
verification: a testbench (not included in this package) instantiated it
alongside the real iCE40 `SB_IO` behavioral model from
`yosys/ice40/cells_sim.v` and confirmed bit-exact byte transmission, correct
per-byte DC latching, gapless multi-byte bursts, discrete (non-merged) SCLK
pulses, and a real half-`clk_sys`-cycle (~12.8 ns at 39 MHz) setup margin on
MOSI/DC ahead of each sampling edge. That covers logical correctness and
relative timing margin -- it does not substitute for confirming the panel
renders a real image on actual hardware, since board-level trace lengths,
connector quality, and the ST7789 unit's actual (not just datasheet-typical)
setup-time tolerance are outside what simulation can see.
