#
# Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
#
# Permission for non-commercial use is hereby granted,
# free of charge, without warranty of any kind.

IVERILOG ?= iverilog
VVP ?= vvp
PYTHON ?= python3
YOSYS ?= yosys
NEXTPNR ?= nextpnr-gowin
GOWIN_PACK ?= gowin_pack
OPENFPGALOADER ?= openFPGALoader
BUILD_DIR ?= build
PE_COUNT ?= 16
WEIGHT_W ?= 8
IDLE_W ?= 8
EVENT_FIFO_DEPTH ?= 64
BENCHMARK_TRIALS ?= 8
BENCHMARK_SEED ?= 1

CORE_RTL := rtl/eap_dynamic_pe.sv rtl/eap16_event_router.sv rtl/eap16_top.sv
COMPARISON_RTL := $(CORE_RTL) rtl/eap16_fixed_topology_top.sv
COMPARISON_TB := $(BUILD_DIR)/tb_snn_comparison.vvp
FIXED_COMPARISON_SYNTH := $(BUILD_DIR)/snn_fixed_topology_gowin.json
ADAPTIVE_COMPARISON_SYNTH := $(BUILD_DIR)/snn_adaptive_eap16_gowin.json
COMPARISON_TOPOLOGY_MASK := 256'h00f0000f00000000000000000000000000000000000000000000000000000000
UART_RTL := rtl/uart_rx.sv rtl/uart_tx.sv rtl/eap16_uart_console.sv
BOARD_RTL := $(CORE_RTL) $(UART_RTL) rtl/eap16_tangnano9k_top.sv
BOARD_CST := constraints/tangnano9k.cst
BOARD_TOP := eap16_tangnano9k_top
DEVICE := GW1NR-LV9QN88PC6/I5
PACK_DEVICE := GW1N-9C
WIDTH_TAG := n$(PE_COUNT)_w$(WEIGHT_W)_i$(IDLE_W)_q$(EVENT_FIFO_DEPTH)
PNR_CST := $(BUILD_DIR)/tangnano9k_pnr.cst
PACK_CST := $(BUILD_DIR)/tangnano9k_pack.cst
UART_TB := $(BUILD_DIR)/tb_eap16_tangnano9k_top_$(WIDTH_TAG).vvp
SYNTH_JSON := $(BUILD_DIR)/eap16_tangnano9k_$(WIDTH_TAG)_synth.json
ROUTED_JSON := $(BUILD_DIR)/eap16_tangnano9k_$(WIDTH_TAG)_routed.json
BITSTREAM := $(BUILD_DIR)/eap16_tangnano9k_$(WIDTH_TAG).fs

.PHONY: all test benchmark bitstream program clean

all: test

test: $(BUILD_DIR)/tb_eap_dynamic_pe.vvp \
      $(BUILD_DIR)/tb_eap_parameter_boundaries.vvp \
      $(BUILD_DIR)/tb_eap16_event_router.vvp \
      $(UART_TB)
	$(VVP) $(BUILD_DIR)/tb_eap_dynamic_pe.vvp
	$(VVP) $(BUILD_DIR)/tb_eap_parameter_boundaries.vvp
	$(VVP) $(BUILD_DIR)/tb_eap16_event_router.vvp
	$(VVP) $(UART_TB)

benchmark: $(COMPARISON_TB) $(FIXED_COMPARISON_SYNTH) $(ADAPTIVE_COMPARISON_SYNTH)
	$(PYTHON) tools/compare_snn.py --sim $(COMPARISON_TB) \
	    --fixed-netlist $(FIXED_COMPARISON_SYNTH) \
	    --adaptive-netlist $(ADAPTIVE_COMPARISON_SYNTH) \
	    --build-dir $(BUILD_DIR) --vvp $(VVP) \
	    --trials $(BENCHMARK_TRIALS) --seed $(BENCHMARK_SEED)

$(BUILD_DIR)/tb_eap_dynamic_pe.vvp: rtl/eap_dynamic_pe.sv tb/tb_eap_dynamic_pe.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -s tb_eap_dynamic_pe -o $@ $^

$(BUILD_DIR)/tb_eap_parameter_boundaries.vvp: rtl/eap_dynamic_pe.sv rtl/eap16_event_router.sv rtl/eap16_fixed_topology_top.sv tb/tb_eap_parameter_boundaries.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -s tb_eap_parameter_boundaries -o $@ $^

$(BUILD_DIR)/tb_eap16_event_router.vvp: rtl/eap16_event_router.sv rtl/eap_dynamic_pe.sv rtl/eap16_top.sv tb/tb_eap16_event_router.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -s tb_eap16_event_router -o $@ $^

$(COMPARISON_TB): $(COMPARISON_RTL) tb/tb_snn_comparison.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -s tb_snn_comparison -o $@ $^

$(FIXED_COMPARISON_SYNTH): rtl/eap16_event_router.sv rtl/eap16_fixed_topology_top.sv
	mkdir -p $(BUILD_DIR)
	$(YOSYS) -Q -q -l $(BUILD_DIR)/snn_fixed_topology_gowin.log -p "read_verilog -sv $^; chparam -set N 16 -set EVENT_FIFO_DEPTH 64 -set WEIGHT_W 8 -set THRESHOLD 100 -set FIXED_WEIGHT 8 -set TOPOLOGY_MASK $(COMPARISON_TOPOLOGY_MASK) eap16_fixed_topology_top; synth_gowin -top eap16_fixed_topology_top -json $@"

$(ADAPTIVE_COMPARISON_SYNTH): $(CORE_RTL)
	mkdir -p $(BUILD_DIR)
	$(YOSYS) -Q -q -l $(BUILD_DIR)/snn_adaptive_eap16_gowin.log -p "read_verilog -sv $^; chparam -set N 16 -set FANIN 16 -set EVENT_FIFO_DEPTH 64 -set WEIGHT_W 8 -set IDLE_W 8 -set THRESHOLD 100 eap16_top; synth_gowin -top eap16_top -json $@"

$(UART_TB): $(BOARD_RTL) tb/tb_eap16_tangnano9k_top.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -s tb_eap16_tangnano9k_top \
	    -Ptb_eap16_tangnano9k_top.N=$(PE_COUNT) \
	    -Ptb_eap16_tangnano9k_top.EVENT_FIFO_DEPTH=$(EVENT_FIFO_DEPTH) \
	    -Ptb_eap16_tangnano9k_top.WEIGHT_W=$(WEIGHT_W) \
	    -Ptb_eap16_tangnano9k_top.IDLE_W=$(IDLE_W) -o $@ $^

bitstream: $(BITSTREAM)

$(SYNTH_JSON): $(BOARD_RTL)
	mkdir -p $(BUILD_DIR)
	$(YOSYS) -Q -q -l $(BUILD_DIR)/yosys_$(WIDTH_TAG).log -p "read_verilog -sv $^; chparam -set N $(PE_COUNT) -set EVENT_FIFO_DEPTH $(EVENT_FIFO_DEPTH) -set WEIGHT_W $(WEIGHT_W) -set IDLE_W $(IDLE_W) $(BOARD_TOP); synth_gowin -top $(BOARD_TOP) -json $@"

$(ROUTED_JSON): $(SYNTH_JSON) $(BOARD_CST)
	mkdir -p $(BUILD_DIR)
	cp $(BOARD_CST) $(PNR_CST)
	$(NEXTPNR) --json $< --write $@ --device $(DEVICE) --cst $(PNR_CST) --freq 13.5

$(BITSTREAM): $(ROUTED_JSON) $(BOARD_CST)
	cp $(BOARD_CST) $(PACK_CST)
	$(GOWIN_PACK) -d $(PACK_DEVICE) -s $(PACK_CST) -o $@ $<

program: $(BITSTREAM)
	$(OPENFPGALOADER) -b tangnano9k $<

clean:
	rm -f $(BUILD_DIR)/tb_eap_dynamic_pe.vvp \
	      $(BUILD_DIR)/tb_eap_parameter_boundaries.vvp \
	      $(BUILD_DIR)/tb_eap16_event_router.vvp \
	      $(COMPARISON_TB) \
	      $(BUILD_DIR)/snn_classification_seed_*.mem \
	      $(BUILD_DIR)/snn_classification_results.csv \
	      $(BUILD_DIR)/snn_classification_trials.csv \
	      $(BUILD_DIR)/snn_classification_cycle_trace.csv \
	      $(BUILD_DIR)/snn_comparison_trace.csv \
	      $(BUILD_DIR)/snn_synthesis_summary.csv \
	      $(FIXED_COMPARISON_SYNTH) \
	      $(ADAPTIVE_COMPARISON_SYNTH) \
	      $(BUILD_DIR)/snn_fixed_topology_gowin.log \
	      $(BUILD_DIR)/snn_adaptive_eap16_gowin.log \
	      $(UART_TB) \
	      $(SYNTH_JSON) \
	      $(ROUTED_JSON) \
	      $(BITSTREAM) \
	      $(PNR_CST) \
	      $(PACK_CST) \
	      $(BUILD_DIR)/yosys_$(WIDTH_TAG).log
