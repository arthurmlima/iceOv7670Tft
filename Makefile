PROJECT   := tangprimer25k
TOP       := tangprimer25k_st7789_top
BOARD     := tangprimer25k
BITSTREAM := impl/pnr/$(PROJECT).fs

GOWIN_IDE := /Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE
PRIM_SIM  := $(GOWIN_IDE)/simlib/gw5a/prim_sim.v

SOURCES  := tangprimer25k_st7789_top.v gowin_pll_40m.v btn_debounce.v \
            cam_init.v cam_capture.v frame_stream_gate.v \
            pixel_xor_stage.v xormap_32.v pixel_fifo.v \
            st7789_camera_ctrl.v st7789_init_rom.v spi_stream_tx.v

all: $(BITSTREAM)

# gw_sh is the Gowin IDE's headless Tcl console; see docs/SETUP.md for the
# one-time wrapper install that puts it on PATH with the right DYLD_* vars.
# gw_sh exits 0 even when a stage fails, so the stale bitstream is removed
# first and its reappearance is what counts as success.
$(BITSTREAM): $(SOURCES) $(PROJECT).cst $(PROJECT).sdc $(PROJECT).gprj build.tcl
	rm -f $@
	gw_sh build.tcl
	@test -f $@ || { echo "build FAILED: $@ was not produced"; exit 1; }

prog: $(BITSTREAM)
	openFPGALoader -b $(BOARD) $(BITSTREAM)

flash: $(BITSTREAM)
	openFPGALoader -b $(BOARD) -f $(BITSTREAM)

# Checks the SPI pad phase relationship against Gowin's own ODDR model, the
# way the iCE40 build checked it against SB_IO.  Requires iverilog.
SIM_SOURCES := tb_spi_gowin_io.v \
               st7789_camera_ctrl.v st7789_init_rom.v spi_stream_tx.v

sim: $(SIM_SOURCES)
	iverilog -g2012 -o /tmp/$(PROJECT)_spi_tb.vvp \
		-s tb_spi_gowin_io $(SIM_SOURCES) "$(PRIM_SIM)"
	vvp /tmp/$(PROJECT)_spi_tb.vvp

timing:
	python3 timing_check.py

clean:
	rm -rf impl

.PHONY: all prog flash sim timing clean
