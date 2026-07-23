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
