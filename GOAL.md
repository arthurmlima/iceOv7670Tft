# Implemented clock-matched design goal

## Objective

Stream an OV7670 directly to a 240×280 ST7789 panel on iCEBreaker without a CPU
or framebuffer. Use the panel's internal GRAM as the frame store and spend only
one 256×16 EBR on rate matching.

## Corrected clock tree

The display architecture is retained, but the PLL is reduced to the nearest
valid step below the measured timing limit. The camera and SPI rates scale with it.

```text
12.000 MHz
    │
    └─ SB_PLL40_PAD → 42.000 MHz system
                         ├─ /2 SPI bit clock → 21.000 MHz ST7789 SCK
                         └─ /2 toggle        → 21.000 MHz OV7670 XCLK
                                                   │
                                                   ├─ CLKRC /3
                                                   │    = 7.000 MHz internal
                                                   └─ QVGA PCLK /2
                                                        = 3.500 MHz
```

SPI now runs at sys_clk/2, the fastest bit rate this single-clock-domain SPI
engine can generate (each SCLK half-period needs at least one clk_sys cycle).
Doubling the display's drain rate lets the camera's CLKRC divider be loosened
from /6 to /3 while preserving the same line-time margin, roughly doubling
frame rate.

Relevant OV7670 settings:

| Register | Value | Purpose |
|---|---:|---|
| `COM7` 0x12 | 0x14 | QVGA selection plus RGB output |
| `CLKRC` 0x11 | 0x02 | internal clock = XCLK / 3 |
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
camera line = 1568 / 7.000 MHz = 224.00 us
panel line  = 280 × 16 / 21.000 MHz = 213.33 us
margin      = 10.67 us per line
```

The panel is slower than the camera during the active cropped burst but faster
over the complete line. The FIFO rises by roughly 70 pixels during the retained
active region and drains through horizontal blanking -- the same peak as
before, since camera and display rates scale together with sys_clk. A
256-pixel FIFO still provides more than 3× that expected peak.

The nominal frame rate is approximately 8.75 fps, based on scaling the
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

All camera pins, including PCLK, are synchronized and sampled in the 42.00 MHz
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
