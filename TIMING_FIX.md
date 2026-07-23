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
