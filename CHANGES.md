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

## Frame-rate follow-up

14. `SPI_HZ` raised from 9.75 MHz to 19.50 MHz (`spi_stream_tx` `HALF_DIV`
    goes from 2 to 1), the fastest SCLK this single-clock-domain SPI engine
    can generate.
15. `cam_init.v` changes `CLKRC` from `0x05` (/6) to `0x02` (/3) at both
    table locations, now that the panel drains twice as fast.
16. Net effect: the same ~4.76% per-line timing margin and ~70-pixel FIFO
    peak are preserved, but nominal frame rate roughly doubles, from about
    4.06 fps to about 8.13 fps.

## Follow-on: PLL raised to the verified timing ceiling

17. The 39.00 MHz build left nextpnr-reported margin unused (43.40 MHz max).
    Rebuilding at progressively higher `--freq` targets (42, 43.5, 45, 48 MHz)
    showed 42.00 MHz (`DIVF=55`) is the highest step that reproducibly closes
    timing -- verified with three clean rebuilds, each landing at 45.00 MHz
    achieved. 43.5 MHz and above failed; nextpnr's placement search became
    non-monotonic near the edge, so this was determined empirically rather
    than assumed from the single 43.40 MHz data point.
18. `SYS_CLK_HZ`/`SPI_HZ` raised to 42000000/21000000 and the Makefile `FREQ`
    default to 42.00. Because OV7670 XCLK is also `sys_clk/2`, the camera
    pixel rate and display drain rate scale together, so `CLKRC=/3` keeps the
    same ~4.76% line margin without any further retuning.
19. Net effect: nominal frame rate rises from about 8.13 fps to about 8.75 fps.

## Follow-on: DDR SPI engine, PLL reverted, CLKRC tightened (superseded above)

20. `spi_stream_tx.v` was rebuilt around an `SB_IO` DDR output cell for SCLK
    (one discrete pulse per `clk_sys` cycle instead of one pulse per two
    cycles) plus `NEG_TRIGGER`-registered cells for MOSI/DC, doubling SPI
    from sys_clk/2 to a full sys_clk. This is a real hardware-timing change
    (not just a divider tweak), so it was verified in simulation against the
    actual iCE40 `SB_IO` behavioral model from `cells_sim.v` before touching
    the real design -- confirming bit-exact byte transmission, correct
    per-byte DC latching, discrete (non-merged) SCLK pulses, and that
    `tx_done` can't let CS cut off the last bit's pulse mid-transmission.
21. Building the DDR engine into the design changed placement pressure on
    the unrelated async BTN_N -> `tft_cs` critical path (this design's
    recurring bottleneck). At 42.00 MHz (item 17-18 above) that path only
    closed with a 0.17% margin -- reproducible, but far too close to real
    PVT variation to trust. `SYS_CLK_HZ`/`SPI_HZ` were reverted to
    39000000/39000000 (Makefile `FREQ` back to 39.00), which reproducibly
    closes with 43.25 MHz max (10.9% margin) with the new SPI engine in
    place.
22. With SPI now twice as fast, `cam_init.v`'s `CLKRC` was tightened from
    `0x02` (/3) to `0x01` (/2) at both table locations. `CLKRC=0x00`
    (bypass, /1) was checked and rejected: even at the new SPI rate the
    camera would outrun the display. Because `CAM_INT_HZ = sys_clk/4` and
    `SPI_HZ = sys_clk` at these settings, the line-time margin is *larger*
    than before (4.76% -> 28.6%) even though the camera clock also grew.
23. Net effect: nominal frame rate rises from about 8.75 fps to about
    12.19 fps -- roughly 1.5x from `CLKRC`, on top of the DDR SPI engine
    that made the `CLKRC` change safe to make at all. See `timing_check.py`.
