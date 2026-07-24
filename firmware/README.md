# Camera-control PicoSoC firmware

`firmware.c`, `start.s`, and `sections.lds` are adapted from the
[YosysHQ PicoSoC example](https://github.com/YosysHQ/picorv32/tree/87c89acc18994c8cf9a2311e871818e87d304568/picosoc).
The upstream notice is retained in `firmware.c`, and the corresponding ISC
license is vendored at `third_party/picorv32/COPYING`.

The adaptations are specific to this iCEBreaker camera design:

- firmware is built for `rv32i`/`ilp32`;
- the UART divider is 85 for the 9.75 MHz processor clock;
- upstream LED writes at `0x0300_0000` are removed because that address is
  the camera control register here;
- the former hardware camera ROM is the editable
  `ov7670_default_config[]` table in `firmware.c`;
- `camera_config_load()`, `camera_config_apply()`, and
  `camera_configure()` stage and apply any 1–256-entry OV7670 table;
- UART commands `E`, `B`, `C`, and `R` request encryption, request bypass,
  print status, and reload the default camera table;
- UART commands `N`, `L`, and `V` apply normal, muted, and vivid colour-matrix
  patches without changing camera timing or frame geometry;
- the linker entry and PicoRV32 reset vector are both `0x0010_0000`.

Camera-configuration MMIO is:

| Address | Access | Purpose |
|---:|:---:|---|
| `0x0300_0008` | RW | Entry count in bits 8:0; bit 30 clears rejected status; bit 31 applies |
| `0x0300_000C` | RO | Bit 0 locked/pending/busy, bit 1 completed and idle, bit 2 rejected, bits 16:8 current index |
| `0x0300_1000`–`0x0300_13FC` | WO | 256 packed `{register,value}` slots, one 32-bit-aligned store each |

Use `OV7670_REG(register, value)` when defining tables; it preserves the
required logical packing on little-endian RV32. `camera_configure()` is
nonblocking. Counts outside 1–256 are rejected without starting SCCB.
Hardware prevents table writes during transmission and waits for the current
video frame to finish before SCCB begins.

The three built-in colour presets are nine-register delta tables containing
`COM13`, `COM16`, `MTX1`–`MTX6`, and `MTXS`. `L` scales the proven matrix to
about 50%; `V` scales it to about 150% and clips oversized coefficients for a
deliberately visible firmware/hardware test; `N` restores the original
matrix. `SATCTR` remains at the default `0x60`, since its low nibble is an
automatic-adjustment result. Use `C` to see the requested preset and transfer
status.

Run `make firmware` to create the ELF, Verilog hex image, raw flash binary,
map, and disassembly under `build/`. Run `make sim` for the RTL
flash-boot/UART/MMIO test. `make cam-init-sim` tests the SCCB consumer.
`make synsim` runs a minimized build of the same C configuration and
camera-control functions against the synthesized SoC netlist.

`make deploy` synthesizes/compiles and programs both images without running
the test suite. `make load-bitstream` handles only the FPGA image, and
`make load-firmware` handles only firmware at flash offset 1 MiB. Program both
once after this MMIO change; subsequent camera-table experiments need only
`make load-firmware`.

The CPU executes firmware directly from onboard SPI flash at reset address
`0x0010_0000`; there is no separate on-chip instruction RAM in this design.
