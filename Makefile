PROJECT   := tangprimer25k
TOP       := tangprimer25k_st7789_top
BOARD     := tangprimer25k
BITSTREAM := impl/pnr/$(PROJECT).fs
PATTERN_FS := impl/pnr/$(PROJECT)_pattern.fs

GOWIN_IDE := /Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE
PRIM_SIM  := $(GOWIN_IDE)/simlib/gw5a/prim_sim.v

SOURCES  := tangprimer25k_st7789_top.v tangprimer25k_pattern_top.v \
            gowin_pll.v async_fifo.v btn_debounce.v status_led.v \
            test_pattern_src.v \
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

# Diagnostic build: identical except the camera is replaced by a moving test
# pattern with the camera's exact timing.  Overwrites the same bitstream, so
# run plain `make` afterwards to get the camera build back.
# Renaming the result also removes the camera bitstream, so a later `make`
# rebuilds it instead of mistaking the pattern build for an up-to-date one.
pattern:
	rm -f $(BITSTREAM)
	gw_sh build_pattern.tcl
	@test -f $(BITSTREAM) || { echo "build FAILED"; exit 1; }
	mv $(BITSTREAM) $(PATTERN_FS)
	@echo "pattern bitstream: $(PATTERN_FS)   (load it with: make prog-pattern)"

prog-pattern: $(PATTERN_FS)
	openFPGALoader -b $(BOARD) $(PATTERN_FS)

$(PATTERN_FS):
	$(MAKE) pattern

prog: $(BITSTREAM)
	openFPGALoader -b $(BOARD) $(BITSTREAM)

flash: $(BITSTREAM)
	openFPGALoader -b $(BOARD) -f $(BITSTREAM)

# Checks the SPI pad phase relationship against Gowin's own ODDR model, the
# way the iCE40 build checked it against SB_IO.  Requires iverilog.
SIM_SOURCES := tb_spi_gowin_io.v \
               st7789_camera_ctrl.v st7789_init_rom.v spi_stream_tx.v

RECOVERY_SOURCES := tb_frame_recovery.v st7789_camera_ctrl.v \
                    st7789_init_rom.v spi_stream_tx.v frame_stream_gate.v \
                    pixel_fifo.v

sim: sim-spi sim-recovery sim-camera

sim-spi: $(SIM_SOURCES)
	iverilog -g2012 -o /tmp/$(PROJECT)_spi_tb.vvp \
		-s tb_spi_gowin_io $(SIM_SOURCES) "$(PRIM_SIM)"
	vvp /tmp/$(PROJECT)_spi_tb.vvp

# Proves the starved-frame deadlock is gone: a short frame must abort and the
# stream must resume without a reset.
sim-recovery: $(RECOVERY_SOURCES)
	iverilog -g2012 -o /tmp/$(PROJECT)_recovery_tb.vvp \
		-s tb_frame_recovery $(RECOVERY_SOURCES) "$(PRIM_SIM)"
	vvp /tmp/$(PROJECT)_recovery_tb.vvp

CAMERA_SOURCES := tb_cam_capture.v cam_capture.v async_fifo.v

# Drives a synthetic OV7670 at real QVGA timing through cam_capture and the
# clock-domain crossing, and checks every pixel by coordinate.
sim-camera: $(CAMERA_SOURCES)
	iverilog -g2012 -o /tmp/$(PROJECT)_camera_tb.vvp \
		-s tb_cam_capture $(CAMERA_SOURCES) "$(PRIM_SIM)"
	vvp /tmp/$(PROJECT)_camera_tb.vvp

timing:
	python3 timing_check.py

clean:
	rm -rf impl

.PHONY: all pattern prog prog-pattern flash sim sim-spi sim-recovery sim-camera timing clean
