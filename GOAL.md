# Implemented clock-matched design goal

## Objective

Stream an OV7670 directly to a 240×280 ST7789 panel on iCEBreaker without a CPU
or framebuffer. Use the panel's internal GRAM as the frame store and spend only
one 256×16 EBR on rate matching.

## Corrected clock tree

The display architecture is retained. The PLL sits at 39.00 MHz, the frequency
this design has been shown to close timing on with real reproducible margin
(10.9%). SPI is now generated through an SB_IO DDR output cell instead of a
plain toggle register, so it runs at a full sys_clk instead of sys_clk/2.

```text
12.000 MHz
    │
    └─ SB_PLL40_PAD → 39.000 MHz system
                         ├─ DDR SPI bit clock → 39.000 MHz ST7789 SCK
                         └─ /2 toggle         → 19.500 MHz OV7670 XCLK
                                                    │
                                                    ├─ CLKRC /2
                                                    │    = 9.750 MHz internal
                                                    └─ QVGA PCLK /2
                                                         = 4.875 MHz
```

SPI now runs at a full sys_clk via an SB_IO DDR output cell for SCLK plus
NEG_TRIGGER-registered cells for MOSI/DC (see `spi_stream_tx.v`), instead of
the previous sys_clk/2 ceiling of a plain single-edge toggle register. That
doubling of the display's drain rate lets the camera's CLKRC divider tighten
from /3 to /2, and because the display headroom grew faster than the camera
rate, the line-time margin actually *improves* (4.76% -> 28.6%) even as frame
rate rises. This DDR phase relationship was verified in simulation against
the real iCE40 `SB_IO` behavioral model before being trusted on hardware --
getting the DDR timing wrong would silently corrupt every byte, so it wasn't
something to get right by inspection alone.

Relevant OV7670 settings:

| Register | Value | Purpose |
|---|---:|---|
| `COM7` 0x12 | 0x14 | QVGA selection plus RGB output |
| `CLKRC` 0x11 | 0x01 | internal clock = XCLK / 2 |
| `DBLV` 0x6B | 0x0A | camera PLL disabled |
| `COM3` 0x0C | 0x04 | enable downsample/crop path |
| `COM14` 0x3E | 0x19 | manual QVGA scaling and PCLK / 2 |
| `RGB444` 0x8C | 0x00 | disable RGB444 |
| `COM15` 0x40 | 0xD0 | RGB565, full range |
| `0x70..0x73`, `0xA2` | QVGA set | 320×240 scaling |

## Geometry

- Camera: 320×240 QVGA RGB565.
- Keep columns 20 through 299.
- Output: 280×240 landscape, one camera pixel per panel pixel.
- Panel: `MADCTL=0xA0`, `CASET=20..299`, `RASET=0..239`.
- No scaler, line buffer, or framebuffer.

## Rate matching

Using 1568 camera internal-clock cycles per QVGA line:

```text
camera line = 1568 / 9.750 MHz = 160.82 us
panel line  = 280 × 16 / 39.000 MHz = 114.87 us
margin      = 45.95 us per line (28.6%)
```

The panel now drains noticeably faster than the camera fills, over both the
active burst and the complete line: with CAM_INT_HZ = SYS_HZ/4 and
SPI_HZ = SYS_HZ, the active-video input and output pixel rates are
algebraically equal (`CAM_INT_HZ/4 == SPI_HZ/16`), so the FIFO barely moves
during the retained active region instead of peaking near 70 pixels. A
256-pixel FIFO is now far larger than needed for steady-state margin, but is
kept as-is since it costs only the one EBR already budgeted.

The nominal frame rate is approximately 12.19 fps, based on scaling the
preliminary 10 fps figure at an 8 MHz camera internal clock.

## Synchronization strategy

1. Initialize the OV7670 over SCCB.
2. Initialize the ST7789 using the known-working reset and register sequence.
3. Arm capture at the first synchronized OV7670 VSYNC after both initializers
   report done.
4. Flush the small FIFO at that frame boundary.
5. Send ST7789 CASET/RASET/RAMWR.
6. Capture and stream exactly 280×240 RGB565 pixels.
7. Return to frame-wait state before the next VSYNC.

All camera pins, including PCLK, are synchronized and sampled in the 39.00 MHz
system domain. PCLK is not used as an FPGA clock, avoiding an asynchronous FIFO.

## Fault detection

A sticky fault is raised for:

- FIFO overflow.
- FIFO underflow.
- A new frame boundary arriving before the panel finishes the previous frame.

These faults drive the red LED. Both initializers complete drives the green LED.

## Resource target

- One 256×16 EBR for pixel rate matching.
- LUT/register logic for capture, SCCB, SPI, and controllers.
- ST7789 init ROM may infer LUT ROM or an additional EBR depending on yosys.
- No 280-pixel line buffer and no 280×240 framebuffer.
