#!/usr/bin/env python3
"""Clock and rate-matching calculation for the OV7670/ST7789 design."""

SYS_HZ = 42_000_000
SPI_HZ = 21_000_000
XCLK_HZ = SYS_HZ / 2
CLKRC_DIV = 3
CAM_INT_HZ = XCLK_HZ / CLKRC_DIV
PCLK_HZ = CAM_INT_HZ / 2

CAM_LINE_INT_CYCLES = 1568
CAM_ACTIVE_PIXELS = 320
CROP_PIXELS = 280
BITS_PER_PIXEL = 16
FIFO_DEPTH = 256

camera_line_s = CAM_LINE_INT_CYCLES / CAM_INT_HZ
display_line_s = CROP_PIXELS * BITS_PER_PIXEL / SPI_HZ
slack_s = camera_line_s - display_line_s

# During QVGA active video, two bytes/pixel at PCLK=f_int/2 means one pixel
# every four internal-clock periods. The display drains SPI_HZ/16 pixels/s.
input_pixel_hz = CAM_INT_HZ / 4
output_pixel_hz = SPI_HZ / BITS_PER_PIXEL
crop_active_s = CROP_PIXELS / input_pixel_hz
peak_fifo_pixels = crop_active_s * (input_pixel_hz - output_pixel_hz)

fps_from_goal = 10.0 * CAM_INT_HZ / 8_000_000

assert slack_s > 0, "Display does not fit inside one camera line"
assert peak_fifo_pixels < FIFO_DEPTH, "FIFO is too small"

print(f"System clock:          {SYS_HZ/1e6:.6f} MHz")
print(f"ST7789 SPI clock:      {SPI_HZ/1e6:.6f} MHz")
print(f"OV7670 XCLK:           {XCLK_HZ/1e6:.6f} MHz")
print(f"OV7670 internal clock: {CAM_INT_HZ/1e6:.6f} MHz")
print(f"OV7670 PCLK:           {PCLK_HZ/1e6:.6f} MHz")
print()
print(f"Camera line time:      {camera_line_s*1e6:.3f} us")
print(f"Display line time:     {display_line_s*1e6:.3f} us")
print(f"Line slack:            {slack_s*1e6:.3f} us "
      f"({100*slack_s/camera_line_s:.2f}%)")
print(f"Estimated FIFO peak:   {peak_fifo_pixels:.1f} pixels")
print(f"FIFO depth:            {FIFO_DEPTH} pixels")
print(f"Estimated frame rate:  {fps_from_goal:.3f} fps")
