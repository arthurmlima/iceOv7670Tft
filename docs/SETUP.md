# Gowin CLI FPGA toolchain setup (macOS)

How this repo builds and flashes FPGA bitstreams from the command line only,
using Gowin's own tools (no Gowin IDE GUI, no open-source toolchain). Written
after setting up a Sipeed Tang Primer 25K (Gowin GW5A-25A); the general
pattern applies to any Gowin device Gowin IDE supports.

Do this once per machine. After that, every project just needs the four
files described under "Project anatomy" and `gw_sh` + `openFPGALoader` on
`PATH`.

## Prerequisites

- **Gowin IDE**, installed manually from
  https://www.gowinsemi.com/en/support/download_eda/ (free account
  required; their EULA blocks automating this step). This ships `gw_sh`,
  a headless Tcl console that does synthesis, place & route, and
  bitstream generation - everything the GUI does, scriptable.
- **Homebrew**, for `openFPGALoader` (does the actual flashing over
  USB-JTAG). Not available as a Gowin-provided tool.
- macOS with `zsh` as the login shell (adjust the wrapper's shebang and
  the rc file if using bash).

## One-time machine setup

Run:

```sh
bash docs/install-gowin-cli.sh
```

This is idempotent - safe to re-run. It:

1. Writes a wrapper script to `~/.local/bin/gw_sh`.
2. Adds `~/.local/bin` to `PATH` in `~/.zshrc` (skipped if already there).
3. Installs `openFPGALoader` via Homebrew if missing.

Open a new terminal afterward (or `source ~/.zshrc`), then confirm:

```sh
gw_sh              # prints the Gowin Tcl console banner; Ctrl-D to exit
openFPGALoader --scan-usb   # lists connected boards
```

### Why a wrapper script, not just a PATH entry

`gw_sh` is a Mach-O binary inside the `.app` bundle. Launched directly, it
fails:

```
dyld[...]: Library not loaded: @rpath/libGWTE.dylib
```

It needs `DYLD_LIBRARY_PATH` and `DYLD_FRAMEWORK_PATH` pointed at the
IDE's `lib/` directory (normally supplied implicitly when macOS launches
the `.app` through Finder/`open`, which we're bypassing here).

Setting those variables via `export` in a *calling* shell - an interactive
terminal, a Makefile's `export` directive, a `.zshrc` line consumed further
up the process chain - does not reliably survive to `gw_sh`. macOS System
Integrity Protection strips `DYLD_*` environment variables at the moment
any SIP-protected system binary (`/bin/sh`, `/bin/bash`, `/bin/zsh` in
their system locations) is `exec`'d. Since `make` runs every recipe line
through `/bin/sh`, a plain `export DYLD_LIBRARY_PATH=...` at the top of a
Makefile gets silently dropped before `gw_sh` ever sees it - confirmed by
testing (`echo $DYLD_LIBRARY_PATH` printed empty inside the recipe despite
the Makefile-level export).

The fix that always works: set the variables *inside* an already-running,
non-restricted process, immediately before it directly `exec`s the
(non-restricted) `gw_sh` binary. A wrapper script does exactly that - the
shell interpreting the wrapper freshly assigns the vars in its own live
environment and hands off directly to `gw_sh`, with no further restricted
hop in between. This works identically whether the wrapper is invoked from
an interactive shell, a Makefile, or another script.

`~/.local/bin` is used (not a Gowin-managed location) because it's a
common convention for user-installed shims and is easy to keep separate
from both Homebrew-managed and Gowin-managed files.

## Finding your device's exact ID string

Gowin's project files need three device identifiers together: an internal
DB id (e.g. `gw5a25a-002`), a family/package short name (e.g. `GW5A-25A`),
and the full ordering part number (e.g. `GW5A-LV25MG121NC1/I0`). These
don't always match what's silkscreened or listed on a store page - the
Tang Primer 25K's chip is commonly written `GW5A-LV25MG121C1/I0`, missing
the `N` package-revision letter that Gowin's own DB uses.

Look them up directly from the installed IDE rather than guessing:

```sh
grep "<your part number substring>" \
  "/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/data/device/device_info.csv"
```

Each matching row is comma-separated:
`<db-id>,<full-pn>,<family>,<name>,<base>,<rev>,<package>,...`

For the Tang Primer 25K this returned two candidate rows (silicon
revisions A and B of the same part number); we used the `A` revision
(`gw5a25a-002` / `GW5A-25A`) because that's the one Project Apicula's
chipdb also ships for this chip, suggesting it's the more common
variant - but if your board misbehaves, try the other revision.

## Project anatomy

A minimal Gowin CLI project is four files:

- **`<name>.v`** - Verilog source.
- **`<name>.cst`** - physical constraints: `IO_LOC "port" <pin>;` plus an
  `IO_PORT` line per port setting drive strength / pull mode / bank
  voltage. Get real pin numbers from your board's schematic or a vendor
  example repo (see the caveat below - verify against the schematic
  before trusting example `.cst` files).
- **`<name>.sdc`** - timing constraints, e.g.
  `create_clock -name clk -period 20 [get_ports {clk}]` for a 50 MHz
  clock (period is in ns).
- **`<name>.gprj`** - the project file gluing it together:

  ```xml
  <?xml version="1" encoding="UTF-8"?>
  <!DOCTYPE gowin-fpga-project>
  <Project>
      <Template>FPGA</Template>
      <Version>5</Version>
      <Device name="GW5A-25A" pn="GW5A-LV25MG121NC1/I0">gw5a25a-002</Device>
      <FileList>
          <File path="src/blink.v" type="file.verilog" enable="1"/>
          <File path="src/blink.cst" type="file.cst" enable="1"/>
          <File path="src/blink.sdc" type="file.sdc" enable="1"/>
      </FileList>
  </Project>
  ```

  Swap the `Device` line for your own lookup result.

In this repo those four files are `tangprimer25k_st7789_top.v` (plus the
other RTL listed in `tangprimer25k.gprj`), `tangprimer25k.cst`,
`tangprimer25k.sdc` and `tangprimer25k.gprj`, all at the top level.

## Build & flash

```sh
printf 'open_project <name>.gprj\nrun all\n' | gw_sh
openFPGALoader -b <board-name> impl/pnr/<name>.fs        # SRAM: volatile
openFPGALoader -b <board-name> -f impl/pnr/<name>.fs     # SPI flash: persists
```

`openFPGALoader --list-boards | grep -i <yourboard>` finds the right
`-b` value.

This repo wraps all of that in `Makefile` + `build.tcl`: `make`, `make prog`,
`make flash`.

## Dedicated pins: freeing them for general I/O

Some pins default to a dedicated internal function (JTAG, SSPI/MSPI
config, an embedded CPU subsystem, DONE/READY config-status) and refuse
placement of ordinary logic:

```
ERROR (PR2017): 'clk' cannot be placed according to constraint,
for the location is a dedicated pin (CPU/SSPI)
```

Free the relevant pin(s) with `set_option` before `run all`:

```
set_option -use_cpu_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -use_mspi_as_gpio 1
set_option -use_done_as_gpio 1
set_option -use_ready_as_gpio 1
set_option -use_jtag_as_gpio 1
```

Only set the ones you actually need - freeing JTAG, for instance, would
break your ability to reprogram over JTAG. These option names aren't
formally documented anywhere we found; they were reverse-engineered from
`data/config/multipurposeconfig.xml` in the IDE install (which lists the
GUI's equivalent checkboxes) and confirmed by testing each one against
`gw_sh` directly.

## Board-specific notes (Sipeed Tang Primer 25K)

- Verified pins: 50 MHz clock on **E2** (needs `use_cpu_as_gpio` +
  `use_sspi_as_gpio`, see above); onboard status LEDs `led_done` on
  **D7** and `led_ready` on **E8** (each needs its own
  `use_..._as_gpio` override to repurpose as plain output).
- The board has exactly **3 LEDs: Power, Ready, Done** - no separate
  general-purpose user LED. Sipeed's official `pmod_led` example
  (`sipeed/TangPrimer-25K-example`) constrains a `led` signal to pin L6
  that does not correspond to any populated LED on this board. The same
  repo has an open issue (#11) about its `key`/button pin being wrong
  too (K6 is actually `USB_N`; real buttons are at H10/H11). Treat that
  repo's `.cst` files as a starting point, not ground truth - verify
  against the schematic or by testing.
- The dock schematic (`Tang_Primer_25K_Dock_60033_Schematic.pdf`, sheet 1)
  settles the button question: the nets are `H11_IOT3A_S1` and
  `H10_IOT3B_S2`, i.e. **S1 = H11, S2 = H10**, both wired through a 100R
  resistor to +3V3, so they read **active high** and want
  `PULL_MODE=DOWN`. That agrees with every Sipeed example
  (`assign rst_n = ~rst;`) and disagrees with litex-boards, which calls
  them `btn_n`.
- The three PMOD headers are `J4`, `J5`, `J6` on the schematic. Their
  connector *symbol* pin numbers are not the physical header pin numbers
  (the symbol numbers the power pins 1-4); see `tangprimer25k.cst` in this
  repo for the physical-pin table, cross-checked against litex-boards and
  Sipeed's own PMOD examples.
- USB-JTAG shows up via `openFPGALoader --scan-usb` as an FTDI2232
  device, "SIPEED USB Debugger". Board name for `-b`:
  `tangprimer25k`.
