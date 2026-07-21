# OV7670 -> ST7789 on iCEBreaker, open toolchain (yosys + nextpnr + icestorm)

PROJ  = cam_st7789
SRCS  = top.v spi8.v st7789_ctrl.v cam_init.v cam_capture.v pixel_fifo.v
FREQ  = 48

all: $(PROJ).bin

$(PROJ).json: $(SRCS)
	yosys -p 'synth_ice40 -top top -json $@' $(SRCS)

$(PROJ).asc: $(PROJ).json icebreaker.pcf
	nextpnr-ice40 --up5k --package sg48 --freq $(FREQ) \
	    --json $(PROJ).json --pcf icebreaker.pcf --asc $@

$(PROJ).bin: $(PROJ).asc
	icepack $< $@

prog: $(PROJ).bin
	iceprog $<

time: $(PROJ).asc
	icetime -d up5k -c $(FREQ) $<

# ---- simulation (iverilog): shrunk timing parameters, see sim/tb_smoke.v ----
sim: sim/tb_smoke.v $(SRCS)
	iverilog -g2005 -o sim/tb_smoke.vvp \
	    sim/tb_smoke.v sim/ice40_stubs.v \
	    spi8.v st7789_ctrl.v cam_init.v cam_capture.v pixel_fifo.v
	vvp sim/tb_smoke.vvp

clean:
	rm -f $(PROJ).json $(PROJ).asc $(PROJ).bin sim/*.vvp sim/*.vcd

.PHONY: all prog time sim clean
