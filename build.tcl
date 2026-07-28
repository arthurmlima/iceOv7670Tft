# ============================================================================
# build.tcl - headless synthesis / place & route / bitstream for gw_sh
#
#   gw_sh build.tcl          (or: make)
#
# Output: impl/pnr/tangprimer25k.fs
# ============================================================================
# TOP is set by build_pattern.tcl; default to the camera build.
if {![info exists TOP]} { set TOP tangprimer25k_st7789_top }

open_project tangprimer25k.gprj

set_option -top_module $TOP

# Release pins that default to a dedicated configuration function.  Each of
# these is required by a pin this design actually uses; nothing else is freed
# (in particular JTAG stays JTAG, so the board remains reprogrammable).
set_option -use_cpu_as_gpio 1     ;# E2  50 MHz oscillator
set_option -use_sspi_as_gpio 1    ;# E2  50 MHz oscillator
set_option -use_ready_as_gpio 1   ;# E8  READY LED
set_option -use_done_as_gpio 1    ;# D7  DONE LED

run all
