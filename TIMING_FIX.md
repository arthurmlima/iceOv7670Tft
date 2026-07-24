# 39.00 MHz timing fix

The previous build requested 39.75 MHz, while nextpnr reported a maximum
frequency of 39.73 MHz.

The iCE40 integer PLL cannot generate 39.70 MHz from the 12 MHz oscillator with
the required VCO/PFD range. The next genuine lower PLL step is 39.00 MHz:

- `DIVR = 0`
- `DIVF = 51`
- `DIVQ = 4`
- system clock = 39.000 MHz
- SPI clock = 9.750 MHz
- OV7670 XCLK = 19.500 MHz

The camera's `CLKRC=/6` and panel `/4` SPI relationship are unchanged, so the
line-rate ratio and expected FIFO peak remain the same. The absolute frame rate
changes slightly from about 4.14 fps to about 4.06 fps.

Build with:

```sh
make clean
make
make prog
```

## Follow-on: faster SPI and camera clock

`/4` SPI division was more conservative than necessary. `spi_stream_tx` can
run as fast as `clk_sys/2` (each SCLK half-period needs at least one
`clk_sys` cycle), so the panel SCLK was raised to 19.500 MHz (`SPI_HZ`
parameter, `/2` instead of `/4`). That doubles the display's drain rate,
which let the camera's `CLKRC` divider loosen from `/6` to `/3`
(6.500 MHz internal clock) while keeping the same ~4.76% per-line timing
margin and ~70-pixel FIFO peak. Nominal frame rate roughly doubles, from
about 4.06 fps to about 8.13 fps. See `GOAL.md` and `README.md` for the
updated clock tree and line-rate proof, and `timing_check.py` for the
numbers.

## Follow-on: PLL raised to 42.00 MHz (superseded below)

The 39.00 MHz build closed with 43.40 MHz of nextpnr-reported margin unused.
Empirically rebuilding at higher `--freq` targets found 42.00 MHz
(`DIVR=0`, `DIVF=55`, `DIVQ=4`) reproducibly closes timing (45.00 MHz
achieved across three clean rebuilds), while 43.5 MHz and above did not.
`SYS_CLK_HZ`/`SPI_HZ` are now 42000000/21000000 and the Makefile `FREQ`
default is 42.00. Since OV7670 XCLK is also `sys_clk/2`, the camera and
display rates scaled together and the ~4.76% line-time margin is unchanged.
Frame rate rises from about 8.13 fps to about 8.75 fps.

## Follow-on: DDR SPI engine, PLL reverted to 39.00 MHz, CLKRC tightened

Pushing further meant breaking the sys_clk/2 ceiling on SPI itself.
`spi_stream_tx.v` was rebuilt around an `SB_IO` DDR output cell for SCLK
(one discrete pulse per `clk_sys` cycle instead of one pulse per two cycles)
plus `NEG_TRIGGER`-registered cells for MOSI/DC, giving each data bit a half
`clk_sys`-cycle setup margin ahead of the SCLK edge that samples it. This is
a genuine hardware-timing redesign, not a divider tweak, so it was verified
in simulation against the real iCE40 `SB_IO` behavioral model
(`yosys/ice40/cells_sim.v`) before being trusted on hardware -- confirming
bit-exact byte transmission, correct per-byte DC latching, discrete
(non-merged) SCLK pulses, and that `tx_done` can't let CS cut off the final
bit's pulse mid-transmission. An early draft that tied both DDR phases to
the same signal merged consecutive bit pulses into one long pulse instead of
one per bit, and a mixed-up `PIN_TYPE` encoding for the MOSI/DC cells made
them combinational instead of registered -- both caught by the testbench,
not by inspection.

Building the DDR engine into the design changed placement pressure on the
unrelated async BTN_N -> `tft_cs` path (this design's recurring critical
path). At 42.00 MHz that path only closed with a 0.17% margin -- reproducible
but too close to real PVT variation to trust. `SYS_CLK_HZ`/`SPI_HZ` were
reverted to 39000000/39000000 (Makefile `FREQ` back to 39.00), which
reproducibly closes with 43.25 MHz max (10.9% margin) with the new SPI
engine in place -- the PLL itself is back to the original safe baseline, and
all of the speed gain comes from the SPI engine and `CLKRC` instead.

With SPI now running twice as fast relative to XCLK, `cam_init.v`'s `CLKRC`
tightened from `0x02` (/3) to `0x01` (/2). `CLKRC=0x00` (bypass, /1) was
checked and rejected: even at the new SPI rate the camera would outrun the
display (see `timing_check.py`). Because `CAM_INT_HZ = sys_clk/4` and
`SPI_HZ = sys_clk` at these settings, the line-time margin is *larger* than
before (4.76% -> 28.6%) even as the camera clock also grew 1.5x. Net effect:
frame rate rises from about 8.75 fps to about 12.19 fps.
