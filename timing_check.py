#!/usr/bin/env python3
"""Clock, frame-rate and buffering calculation for the OV7670/ST7789 design.

The iCEBreaker design ran in a *rate-balanced* regime: the camera's active
video pixel rate was made exactly equal to the panel's drain rate, so the FIFO
never accumulated and 256 entries were plenty.  That balance is also what
pinned the frame rate at 12.5 fps, because it forced the camera's internal
clock down to clk_sys/4.

Bypassing CLKRC doubles the internal clock and so doubles the frame rate, at
the cost of leaving that regime: the camera now outruns the panel during
active video, and the surplus has to be held.  This script sizes that surplus
and checks the two conditions that still have to hold.
"""

SYS_HZ = 40_000_000     # Tang Primer 25K: PLLA CLKOUT0, 50 MHz -> 40 MHz
SPI_HZ = 40_000_000     # full-rate DDR SPI engine: SPI_HZ = SYS_HZ
XCLK_HZ = 24_000_000    # PLLA CLKOUT1, the OV7670's rated maximum
CAP_HZ = 100_000_000    # PLLA CLKOUT2: oversamples PCLK in cam_capture
CLKRC_DIV = 1           # CLKRC = 0x00, no prescale
CAM_INT_HZ = XCLK_HZ / CLKRC_DIV
PCLK_HZ = CAM_INT_HZ / 2        # COM14 PCLK divider

# OV7670 frame geometry, in internal-clock cycles.  510 lines of 1568 whatever
# the output resolution: QVGA decimates the output, it does not shorten the
# array scan.  This is why frame rate depends on nothing but CAM_INT_HZ.
CAM_LINE_INT_CYCLES = 1568
CAM_TOTAL_LINES = 510
CAM_FRAME_INT_CYCLES = CAM_LINE_INT_CYCLES * CAM_TOTAL_LINES

CROP_PIXELS = 280
ACTIVE_LINES = 240
BITS_PER_PIXEL = 16
FIFO_DEPTH = 40_960             # must match FIFO_DEPTH in the top level
BSRAM_BITS = 56 * 18_432        # GW5A-25A

NPIX = CROP_PIXELS * ACTIVE_LINES

fps = CAM_INT_HZ / CAM_FRAME_INT_CYCLES
cam_frame_s = CAM_FRAME_INT_CYCLES / CAM_INT_HZ
disp_frame_s = NPIX * BITS_PER_PIXEL / SPI_HZ
disp_ceiling_fps = 1 / disp_frame_s

drain_pix_hz = SPI_HZ / BITS_PER_PIXEL

# Worst case for buffering: the sensor emits its ACTIVE_LINES output lines in
# consecutive line periods.  (If it instead spreads them over 2x that many, as
# vertical DCW decimation suggests, the panel keeps up and the FIFO only holds
# an intra-line ripple -- so this is the safe side to size for.)
active_s = ACTIVE_LINES * CAM_LINE_INT_CYCLES / CAM_INT_HZ
drained_during_active = drain_pix_hz * active_s
deficit_pixels = max(0.0, NPIX - drained_during_active)

# Capture periods per PCLK period.  cam_capture only needs one sampling edge
# inside each PCLK phase, so what this really sets is how far the PCLK duty
# cycle may drift before a phase is missed entirely.
cap_per_pclk = CAP_HZ / PCLK_HZ
min_duty = 100.0 / cap_per_pclk

assert disp_frame_s < cam_frame_s, \
    "Panel cannot finish a frame before the next VSYNC"
assert deficit_pixels <= FIFO_DEPTH, \
    f"FIFO too small: need {deficit_pixels:.0f}, have {FIFO_DEPTH}"
assert FIFO_DEPTH * BITS_PER_PIXEL <= BSRAM_BITS, "FIFO does not fit in BSRAM"
assert cap_per_pclk >= 4, \
    f"cam_capture wants >=4 capture periods per PCLK, has {cap_per_pclk:.1f}"

print(f"System clock:          {SYS_HZ/1e6:.6f} MHz")
print(f"ST7789 SPI clock:      {SPI_HZ/1e6:.6f} MHz")
print(f"OV7670 XCLK:           {XCLK_HZ/1e6:.6f} MHz")
print(f"OV7670 internal clock: {CAM_INT_HZ/1e6:.6f} MHz  (CLKRC /{CLKRC_DIV})")
print(f"OV7670 PCLK:           {PCLK_HZ/1e6:.6f} MHz")
print(f"Capture clock:         {CAP_HZ/1e6:.6f} MHz")
print()
print(f"Frame rate:            {fps:.2f} fps   = f_int / {CAM_FRAME_INT_CYCLES}")
print(f"Camera frame period:   {cam_frame_s*1e3:.2f} ms")
print(f"Panel frame time:      {disp_frame_s*1e3:.2f} ms "
      f"(ceiling {disp_ceiling_fps:.1f} fps)")
print(f"Panel finishes with:   {(cam_frame_s-disp_frame_s)*1e3:.2f} ms to spare")
print()
print(f"Active video span:     {active_s*1e3:.2f} ms  (worst case)")
print(f"Pixels in / drained:   {NPIX} / {drained_during_active:.0f}")
print(f"Peak FIFO occupancy:   {deficit_pixels:.0f} pixels")
print(f"FIFO depth:            {FIFO_DEPTH} pixels "
      f"({100*deficit_pixels/FIFO_DEPTH:.0f}% used, "
      f"{100*FIFO_DEPTH*BITS_PER_PIXEL/BSRAM_BITS:.0f}% of BSRAM)")
print()
print(f"Samples per PCLK:      {cap_per_pclk:.2f}")
print(f"PCLK duty tolerance:   down to {min_duty:.0f}% "
      f"before a phase is missed")
