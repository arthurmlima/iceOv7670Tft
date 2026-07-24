# PicoRV32 / PicoSoC RTL provenance

These files are vendored, unmodified RTL from
[YosysHQ/picorv32](https://github.com/YosysHQ/picorv32), pinned at commit
[`87c89acc18994c8cf9a2311e871818e87d304568`](https://github.com/YosysHQ/picorv32/commit/87c89acc18994c8cf9a2311e871818e87d304568):

- `picorv32.v` from the repository root
- `spimemio.v`, `simpleuart.v`, `ice40up5k_spram.v`, and `spiflash.v`
  from `picosoc/`
- `COPYING` from the repository root

The upstream ISC license and source headers are preserved. The local
`camera_control_soc.v` wrapper is a reduced PicoSoC-style integration tailored
to this camera design's two clock domains and MMIO controls.
