# Integration changes

Compared with the original ST7789 test-pattern project:

1. The PLL is reduced from 39.75 MHz to the next valid lower setting, 39.00 MHz,
   after nextpnr reported 39.73 MHz maximum. SPI scales from 9.9375 MHz to 9.75 MHz.
2. The display remains on the same FPGA pins, correctly identified as PMOD 1B.
3. OV7670 data uses PMOD 1A; OV7670 timing/control uses PMOD 2.
4. `cam_init.v` changes `COM7` from `0x04` to `0x14` so the camera
   explicitly selects QVGA while retaining RGB output.
5. `cam_init.v` now programs `CLKRC=0x05` at both table locations, giving
   XCLK/6 instead of XCLK/3.
6. The OV7670 PLL remains disabled with `DBLV=0x0A`.
7. QVGA/RGB565 settings from the preliminary camera project are retained.
8. `cam_capture.v` samples PCLK as synchronized data in the 39.00 MHz domain,
   assembles RGB565, and crops 320 columns to 280.
9. `pixel_fifo.v` adds a 256×16 single-clock FIFO intended to infer one EBR.
10. `spi_stream_tx.v` replaces the per-byte SPI engine for camera pixels so
   adjacent bytes have no inserted SCLK gap.
11. `st7789_camera_ctrl.v` reuses the working reset/init ROM and streams
    280×240 pixels into a landscape RAM window.
12. The red LED is now a sticky overflow/underflow/frame-sync fault indicator.
13. `timing_check.py` documents and checks the line-rate and FIFO calculations.

The original test-pattern modules remain in the directory for comparison but
are not in the Makefile source list.
