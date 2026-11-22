IVERILOG ?= iverilog
VVP ?= vvp
YOSYS ?= yosys
NEXTPNR ?= nextpnr-gowin
GOWIN_PACK ?= gowin_pack
OPENFPGALOADER ?= openFPGALoader
BUILD_DIR ?= build

CORE_RTL := rtl/eap_dynamic_pe.sv rtl/eap16_top.sv
UART_RTL := rtl/uart_rx.sv rtl/uart_tx.sv rtl/eap16_uart_console.sv
BOARD_RTL := $(CORE_RTL) $(UART_RTL) rtl/eap16_tangnano9k_top.sv
BOARD_CST := constraints/tangnano9k.cst
BOARD_TOP := eap16_tangnano9k_top
DEVICE := GW1NR-LV9QN88PC6/I5
PACK_DEVICE := GW1N-9C
PNR_CST := $(BUILD_DIR)/tangnano9k_pnr.cst
PACK_CST := $(BUILD_DIR)/tangnano9k_pack.cst

.PHONY: all test bitstream program clean

all: test

test: $(BUILD_DIR)/tb_eap_dynamic_pe.vvp \
      $(BUILD_DIR)/tb_eap_parameter_boundaries.vvp \
      $(BUILD_DIR)/tb_eap16_tangnano9k_top.vvp
	$(VVP) $(BUILD_DIR)/tb_eap_dynamic_pe.vvp
	$(VVP) $(BUILD_DIR)/tb_eap_parameter_boundaries.vvp
	$(VVP) $(BUILD_DIR)/tb_eap16_tangnano9k_top.vvp

$(BUILD_DIR)/tb_eap_dynamic_pe.vvp: rtl/eap_dynamic_pe.sv tb/tb_eap_dynamic_pe.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -s tb_eap_dynamic_pe -o $@ $^

$(BUILD_DIR)/tb_eap_parameter_boundaries.vvp: rtl/eap_dynamic_pe.sv tb/tb_eap_parameter_boundaries.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -s tb_eap_parameter_boundaries -o $@ $^

$(BUILD_DIR)/tb_eap16_tangnano9k_top.vvp: $(BOARD_RTL) tb/tb_eap16_tangnano9k_top.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -s tb_eap16_tangnano9k_top -o $@ $^

bitstream: $(BUILD_DIR)/eap16_tangnano9k.fs

$(BUILD_DIR)/eap16_tangnano9k_synth.json: $(BOARD_RTL)
	mkdir -p $(BUILD_DIR)
	$(YOSYS) -Q -q -l $(BUILD_DIR)/yosys.log -p "read_verilog -sv $^; synth_gowin -top $(BOARD_TOP) -json $@"

$(BUILD_DIR)/eap16_tangnano9k_routed.json: $(BUILD_DIR)/eap16_tangnano9k_synth.json $(BOARD_CST)
	mkdir -p $(BUILD_DIR)
	cp $(BOARD_CST) $(PNR_CST)
	$(NEXTPNR) --json $< --write $@ --device $(DEVICE) --cst $(PNR_CST) --freq 13.5

$(BUILD_DIR)/eap16_tangnano9k.fs: $(BUILD_DIR)/eap16_tangnano9k_routed.json $(BOARD_CST)
	cp $(BOARD_CST) $(PACK_CST)
	$(GOWIN_PACK) -d $(PACK_DEVICE) -s $(PACK_CST) -o $@ $<

program: $(BUILD_DIR)/eap16_tangnano9k.fs
	$(OPENFPGALOADER) -b tangnano9k $<

clean:
	rm -f $(BUILD_DIR)/tb_eap_dynamic_pe.vvp \
	      $(BUILD_DIR)/tb_eap_parameter_boundaries.vvp \
	      $(BUILD_DIR)/tb_eap16_tangnano9k_top.vvp \
	      $(BUILD_DIR)/eap16_tangnano9k_synth.json \
	      $(BUILD_DIR)/eap16_tangnano9k_routed.json \
	      $(BUILD_DIR)/eap16_tangnano9k.fs \
	      $(PNR_CST) \
	      $(PACK_CST) \
	      $(BUILD_DIR)/yosys.log
