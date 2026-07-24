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
- UART commands `E`, `B`, and `C` request encryption, request bypass, and
  print camera status;
- the linker entry and PicoRV32 reset vector are both `0x0010_0000`.

Run `make firmware` to create the ELF, Verilog hex image, raw flash binary,
map, and disassembly under `build/`. Run `make sim` for the RTL
flash-boot/UART/MMIO test. `make synsim` runs a minimized build of the same C
camera-control function against the synthesized SoC netlist.

`make prog` programs both the FPGA image and firmware. `make prog-fw` updates
only the firmware at flash offset 1 MiB.
