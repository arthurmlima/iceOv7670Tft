TOP        := icebreaker_st7789_top
PCF        := icebreaker.pcf
DEVICE     := up5k
PACKAGE    := sg48
FREQ       := 39.00
BUILD_DIR  ?= build

# The project Makefile now builds the firmware-booting FPGA image by default.
# Set BOOT_FROM_FLASH=0 only when intentionally rebuilding the hardware-only
# safe-stub configuration.
BOOT_FROM_FLASH ?= 1

YOSYS        ?= yosys
YOSYS_CONFIG ?= yosys-config
NEXTPNR      ?= nextpnr-ice40
ICEPACK      ?= icepack
ICEPROG      ?= iceprog
IVERILOG     ?= iverilog
VVP          ?= vvp

CROSS        ?= /opt/riscv32i/bin/riscv32-unknown-elf-
FW_CFLAGS    ?= -Os

SOURCES := icebreaker_st7789_top.v \
           camera_control_soc.v \
           cam_init.v cam_capture.v frame_stream_gate.v \
           pixel_xor_stage.v xormap_32.v pixel_fifo.v \
           st7789_camera_ctrl.v st7789_init_rom.v spi_stream_tx.v \
           third_party/picorv32/ice40up5k_spram.v \
           third_party/picorv32/spimemio.v \
           third_party/picorv32/simpleuart.v \
           third_party/picorv32/picorv32.v

SOC_SOURCES := camera_control_soc.v \
               third_party/picorv32/ice40up5k_spram.v \
               third_party/picorv32/spimemio.v \
               third_party/picorv32/simpleuart.v \
               third_party/picorv32/picorv32.v

HW_NAME    := $(TOP)_boot$(BOOT_FROM_FLASH)
JSON       := $(BUILD_DIR)/$(HW_NAME).json
ASC        := $(BUILD_DIR)/$(HW_NAME).asc
BITSTREAM  := $(BUILD_DIR)/$(HW_NAME).bin
YSLOG      := $(BUILD_DIR)/$(HW_NAME).yslog
NPNRLOG    := $(BUILD_DIR)/$(HW_NAME).nextpnr.log

FW_LDS     := $(BUILD_DIR)/icebreaker_sections.lds
FW_ELF     := $(BUILD_DIR)/icebreaker_fw.elf
FW_HEX     := $(BUILD_DIR)/icebreaker_fw.hex
FW_BIN     := $(BUILD_DIR)/icebreaker_fw.bin
FW_DIS     := $(BUILD_DIR)/icebreaker_fw.dis
FW_MAP     := $(BUILD_DIR)/icebreaker_fw.map
FW_SIM_ELF := $(BUILD_DIR)/icebreaker_fw_sim.elf
FW_SIM_HEX := $(BUILD_DIR)/icebreaker_fw_sim.hex
FW_SMOKE_ELF := $(BUILD_DIR)/icebreaker_fw_smoke.elf
FW_SMOKE_HEX := $(BUILD_DIR)/icebreaker_fw_smoke.hex

SIM_VVP      := $(BUILD_DIR)/firmware_tb.vvp
SOC_SYN_JSON := $(BUILD_DIR)/camera_control_soc_syn.json
SOC_SYN_V    := $(BUILD_DIR)/camera_control_soc_syn.v
SOC_SYN_LOG  := $(BUILD_DIR)/camera_control_soc_syn.yslog
SYN_SIM_VVP  := $(BUILD_DIR)/firmware_syn_tb.vvp
SIM_VCD      := $(BUILD_DIR)/firmware_tb.vcd

ICE40_CELLS_SIM ?= $(shell $(YOSYS_CONFIG) --datdir)/ice40/cells_sim.v

all: hardware firmware

hardware: $(BITSTREAM)

firmware: $(FW_BIN) $(FW_HEX) $(FW_DIS)

$(BUILD_DIR):
	mkdir -p $@

# ---------------- FPGA hardware ----------------

$(JSON): $(SOURCES) $(PCF) Makefile | $(BUILD_DIR)
	$(YOSYS) -ql $(YSLOG) \
		-p 'chparam -set RISCV_BOOT_FROM_FLASH $(BOOT_FROM_FLASH) $(TOP); synth_ice40 -top $(TOP) -json $@' \
		$(SOURCES)

$(ASC): $(JSON) $(PCF)
	$(NEXTPNR) --$(DEVICE) --package $(PACKAGE) --freq $(FREQ) \
		--seed 1 --json $< --pcf $(PCF) --asc $@ --log $(NPNRLOG)

$(BITSTREAM): $(ASC)
	$(ICEPACK) $< $@

# ---------------- PicoSoC firmware ----------------

$(FW_LDS): firmware/sections.lds | $(BUILD_DIR)
	$(CROSS)cpp -P -DICEBREAKER -o $@ $<

$(FW_ELF): $(FW_LDS) firmware/start.s firmware/firmware.c Makefile
	$(CROSS)gcc $(FW_CFLAGS) -DICEBREAKER \
		-march=rv32i -mabi=ilp32 -ffreestanding -fno-builtin \
		-fno-pic -fno-pie -nostdlib \
		-Wl,--build-id=none,-Bstatic,-T,$(FW_LDS),-Map,$(FW_MAP),--strip-debug \
		-o $@ firmware/start.s firmware/firmware.c
	$(CROSS)size $@

$(FW_HEX): $(FW_ELF)
	$(CROSS)objcopy -O verilog $< $@

$(FW_BIN): $(FW_ELF)
	$(CROSS)objcopy -O binary $< $@

$(FW_DIS): $(FW_ELF)
	$(CROSS)objdump -d -S $< > $@

$(FW_SIM_ELF): $(FW_LDS) firmware/start.s firmware/firmware.c Makefile
	$(CROSS)gcc $(FW_CFLAGS) -DICEBREAKER \
		-DUART_CLKDIV=2 -DPROMPT_TIMEOUT_CYCLES=100000 \
		-march=rv32i -mabi=ilp32 -ffreestanding -fno-builtin \
		-fno-pic -fno-pie -nostdlib \
		-Wl,--build-id=none,-Bstatic,-T,$(FW_LDS),--strip-debug \
		-o $@ firmware/start.s firmware/firmware.c

$(FW_SIM_HEX): $(FW_SIM_ELF)
	$(CROSS)objcopy -O verilog $< $@

$(FW_SMOKE_ELF): $(FW_LDS) firmware/start.s firmware/firmware.c Makefile
	$(CROSS)gcc $(FW_CFLAGS) -DICEBREAKER -DFIRMWARE_SMOKE_TEST \
		-march=rv32i -mabi=ilp32 -ffreestanding -fno-builtin \
		-ffunction-sections -fdata-sections -fno-pic -fno-pie -nostdlib \
		-Wl,--build-id=none,-Bstatic,-T,$(FW_LDS),--strip-debug,--gc-sections \
		-o $@ firmware/start.s firmware/firmware.c

$(FW_SMOKE_HEX): $(FW_SMOKE_ELF)
	$(CROSS)objcopy -O verilog $< $@

firmware-info: $(FW_ELF)
	$(CROSS)readelf -h -A $<
	$(CROSS)size $<

# ---------------- Upstream-style firmware simulation ----------------

$(SIM_VVP): firmware/camera_control_soc_tb.v $(SOC_SOURCES) Makefile \
		third_party/picorv32/spiflash.v | $(BUILD_DIR)
	$(IVERILOG) -g2012 -DNO_ICE40_DEFAULT_ASSIGNMENTS -s testbench -o $@ \
		firmware/camera_control_soc_tb.v $(SOC_SOURCES) \
		third_party/picorv32/spiflash.v $(ICE40_CELLS_SIM)

sim: $(SIM_VVP) $(FW_SIM_HEX)
	$(VVP) -N $(SIM_VVP) +firmware=$(abspath $(FW_SIM_HEX))

sim-vcd: $(SIM_VVP) $(FW_SIM_HEX)
	$(VVP) -N $(SIM_VVP) +firmware=$(abspath $(FW_SIM_HEX)) +vcd

$(SOC_SYN_JSON): $(SOC_SOURCES) Makefile | $(BUILD_DIR)
	$(YOSYS) -ql $(SOC_SYN_LOG) \
		-p 'chparam -set BOOT_FROM_FLASH 1 camera_control_soc; chparam -set STACKADDR 64 camera_control_soc; synth_ice40 -top camera_control_soc -json $@' \
		$(SOC_SOURCES)

$(SOC_SYN_V): $(SOC_SYN_JSON)
	$(YOSYS) -p 'read_json $<; write_verilog -noattr $@'

$(SYN_SIM_VVP): firmware/camera_control_soc_tb.v $(SOC_SYN_V) Makefile \
		third_party/picorv32/spiflash.v
	$(IVERILOG) -g2012 -DNO_ICE40_DEFAULT_ASSIGNMENTS \
		-DSYNTHESIS_NETLIST -DFIRMWARE_SMOKE_TEST -s testbench -o $@ \
		firmware/camera_control_soc_tb.v $(SOC_SYN_V) \
		third_party/picorv32/spiflash.v $(ICE40_CELLS_SIM)

synsim: $(SYN_SIM_VVP) $(FW_SMOKE_HEX)
	$(VVP) -N $(SYN_SIM_VVP) +firmware=$(abspath $(FW_SMOKE_HEX))

# Names retained from the original PicoSoC iCEBreaker Makefile.
icebsim: sim
icebsynsim: synsim

# ---------------- Board programming ----------------

prog: $(BITSTREAM) $(FW_BIN)
	$(ICEPROG) $(BITSTREAM)
	$(ICEPROG) -o 1M $(FW_BIN)

prog-fpga: $(BITSTREAM)
	$(ICEPROG) $(BITSTREAM)

prog-fw: $(FW_BIN)
	$(ICEPROG) -o 1M $(FW_BIN)

icebprog: prog
icebprog_fw: prog-fw

timing:
	python3 timing_check.py

check: firmware sim hardware

check-all: check synsim

GENERATED := $(JSON) $(ASC) $(BITSTREAM) $(YSLOG) $(NPNRLOG) \
             $(BUILD_DIR)/$(TOP).json \
             $(BUILD_DIR)/$(TOP).asc \
             $(BUILD_DIR)/$(TOP).bin \
             $(BUILD_DIR)/$(TOP).yslog \
             $(BUILD_DIR)/$(TOP).nextpnr.log \
             $(BUILD_DIR)/$(TOP)_boot0.json \
             $(BUILD_DIR)/$(TOP)_boot0.asc \
             $(BUILD_DIR)/$(TOP)_boot0.bin \
             $(BUILD_DIR)/$(TOP)_boot0.yslog \
             $(BUILD_DIR)/$(TOP)_boot0.nextpnr.log \
             $(BUILD_DIR)/$(TOP)_boot1.json \
             $(BUILD_DIR)/$(TOP)_boot1.asc \
             $(BUILD_DIR)/$(TOP)_boot1.bin \
             $(BUILD_DIR)/$(TOP)_boot1.yslog \
             $(BUILD_DIR)/$(TOP)_boot1.nextpnr.log \
             $(FW_LDS) $(FW_ELF) $(FW_HEX) $(FW_BIN) $(FW_DIS) $(FW_MAP) \
             $(FW_SIM_ELF) $(FW_SIM_HEX) \
             $(FW_SMOKE_ELF) $(FW_SMOKE_HEX) \
             $(SIM_VVP) $(SOC_SYN_JSON) $(SOC_SYN_V) $(SOC_SYN_LOG) \
             $(SYN_SIM_VVP) $(SIM_VCD)

clean:
	rm -f $(GENERATED)

.PHONY: all hardware firmware firmware-info sim sim-vcd synsim \
        icebsim icebsynsim prog prog-fpga prog-fw icebprog icebprog_fw \
        timing check check-all clean
