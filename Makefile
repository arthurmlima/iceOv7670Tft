TOP      := icebreaker_st7789_top
PCF      := icebreaker.pcf
DEVICE   := up5k
PACKAGE  := sg48
FREQ     := 39.00

SOURCES  := icebreaker_st7789_top.v \
            cam_init.v cam_capture.v frame_stream_gate.v \
            pixel_xor_stage.v xormap_32.v pixel_fifo.v \
            st7789_camera_ctrl.v st7789_init_rom.v spi_stream_tx.v

all: $(TOP).bin

$(TOP).json: $(SOURCES)
	yosys -ql $(TOP).yslog -p 'synth_ice40 -top $(TOP) -json $@' $(SOURCES)

$(TOP).asc: $(TOP).json $(PCF)
	nextpnr-ice40 --$(DEVICE) --package $(PACKAGE) --freq $(FREQ) \
		--json $< --pcf $(PCF) --asc $@ --log $(TOP).nextpnr.log

$(TOP).bin: $(TOP).asc
	icepack $< $@

prog: $(TOP).bin
	iceprog $<

timing:
	python3 timing_check.py

clean:
	rm -f $(TOP).json $(TOP).asc $(TOP).bin \
	      $(TOP).yslog $(TOP).nextpnr.log

.PHONY: all prog timing clean
