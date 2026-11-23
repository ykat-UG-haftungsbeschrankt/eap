#
# Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
#
# Permission for non-commercial use is hereby granted,
# free of charge, without warranty of any kind.

IVERILOG ?= iverilog
VVP ?= vvp
YOSYS ?= yosys
NEXTPNR ?= nextpnr-gowin
GOWIN_PACK ?= gowin_pack
OPENFPGALOADER ?= openFPGALoader
GOWIN_DEVICE ?= GW1NR-LV9QN88PC6/I5
PACK_DEVICE ?= GW1N-9C
BUILD_DIR ?= ../build/blm
BOARD_CST ?= tangnano9k_binary_lut.cst
BOARD_TOP := blm_binary_lut_tangnano9k_top
BOARD_RTL := ../rtl/eap16_event_router.sv ../rtl/uart_rx.sv \
             ../rtl/uart_tx.sv ../rtl/eap16_uart_console.sv \
             binary_lut_pe.sv binary_lut_array.sv \
             binary_lut_tangnano9k_top.sv

SIM_MIN := $(BUILD_DIR)/tb_bit_sequence_learner_h2.vvp
SIM_DEFAULT := $(BUILD_DIR)/tb_bit_sequence_learner_h4.vvp
SIM_MAX := $(BUILD_DIR)/tb_bit_sequence_learner_h12.vvp
SIM_EVICTION := $(BUILD_DIR)/tb_bit_sequence_cache_eviction.vvp
SIM_BINARY_PE := $(BUILD_DIR)/tb_binary_lut_pe.vvp
DUAL_SIM := $(BUILD_DIR)/tb_binary_lut_dual_array.vvp
MULTI_SIM := $(BUILD_DIR)/tb_binary_lut_multi_array.vvp
SOURCES := bit_sequence_learner.sv tb_bit_sequence_learner.sv
BENCH_SIM := $(BUILD_DIR)/tb_bit_sequence_benchmark.vvp
GOWIN_SYNTH := $(BUILD_DIR)/binary_lut_pe_gowin.json
GOWIN_PLACE := $(BUILD_DIR)/binary_lut_pe_placed.json
GOWIN_REPORT := $(BUILD_DIR)/binary_lut_pe_report.json
BOARD_SIM := $(BUILD_DIR)/tb_binary_lut_tangnano9k_top.vvp
NETWORK_BENCH_SIM := $(BUILD_DIR)/tb_binary_lut_network_benchmark.vvp
BOARD_SYNTH := $(BUILD_DIR)/binary_lut_tangnano9k_synth.json
BOARD_ROUTED := $(BUILD_DIR)/binary_lut_tangnano9k_routed.json
BOARD_BITSTREAM := $(BUILD_DIR)/binary_lut_tangnano9k.fs
DUAL_SYNTH := $(BUILD_DIR)/binary_lut_dual_gowin.json
DUAL_PLACED := $(BUILD_DIR)/binary_lut_dual_placed.json
DUAL_PLACE_REPORT := $(BUILD_DIR)/binary_lut_dual_place_report.json
DUAL_ROUTED := $(BUILD_DIR)/binary_lut_dual_routed.json
DUAL_REPORT := $(BUILD_DIR)/binary_lut_dual_pnr_report.json

.PHONY: test benchmark network-benchmark dual-network-test \
        dual-network-estimate dual-network-place fpga-check fpga-place \
        board-bitstream board-program

test: $(SIM_MIN) $(SIM_DEFAULT) $(SIM_MAX) $(SIM_EVICTION) \
      $(SIM_BINARY_PE) $(BOARD_SIM) $(DUAL_SIM) $(MULTI_SIM)
	$(VVP) $(SIM_MIN)
	$(VVP) $(SIM_DEFAULT)
	$(VVP) $(SIM_MAX)
	$(VVP) $(SIM_EVICTION)
	$(VVP) $(SIM_BINARY_PE)
	$(VVP) $(BOARD_SIM)
	$(VVP) $(DUAL_SIM)
	$(VVP) $(MULTI_SIM)

benchmark: $(BENCH_SIM)
	$(VVP) $(BENCH_SIM)

network-benchmark: $(NETWORK_BENCH_SIM) $(DUAL_SIM) $(MULTI_SIM)
	$(VVP) $(NETWORK_BENCH_SIM)
	$(VVP) $(DUAL_SIM)
	$(VVP) $(MULTI_SIM)

dual-network-test: $(DUAL_SIM) $(MULTI_SIM)
	$(VVP) $(DUAL_SIM)
	$(VVP) $(MULTI_SIM)

dual-network-estimate: $(DUAL_PLACED)

dual-network-place: $(DUAL_ROUTED)

fpga-check:
	$(YOSYS) -Q -q -p 'read_verilog -sv binary_lut_pe.sv; hierarchy -check -top binary_lut_pe; synth -top binary_lut_pe; check'

fpga-place: $(GOWIN_PLACE)

board-bitstream: $(BOARD_BITSTREAM)

board-program: $(BOARD_BITSTREAM)
	$(OPENFPGALOADER) -b tangnano9k $<

$(GOWIN_SYNTH): binary_lut_pe.sv
	mkdir -p $(BUILD_DIR)
	$(YOSYS) -Q -q -p 'read_verilog -sv $<; synth_gowin -top binary_lut_pe -json $@; check'

$(GOWIN_PLACE): $(GOWIN_SYNTH)
	$(NEXTPNR) --quiet --json $< --device $(GOWIN_DEVICE) --freq 13.5 \
	    --no-route --write $@ --report $(GOWIN_REPORT)

$(BOARD_SIM): $(BOARD_RTL) tb_binary_lut_tangnano9k_top.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -Wno-timescale -s tb_binary_lut_tangnano9k_top -o $@ $^

$(NETWORK_BENCH_SIM): ../rtl/eap16_event_router.sv binary_lut_pe.sv binary_lut_array.sv tb_binary_lut_network_benchmark.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -Wno-timescale -s tb_binary_lut_network_benchmark -o $@ $^

$(DUAL_SIM): ../rtl/eap16_event_router.sv binary_lut_pe.sv binary_lut_array.sv binary_lut_dual_array.sv tb_binary_lut_dual_array.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -Wno-timescale -s tb_binary_lut_dual_array -o $@ $^

$(MULTI_SIM): ../rtl/eap16_event_router.sv binary_lut_pe.sv binary_lut_array.sv binary_lut_dual_array.sv tb_binary_lut_dual_array.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -Wno-timescale -s tb_binary_lut_dual_array \
	    -Ptb_binary_lut_dual_array.NETWORK_COUNT=3 -o $@ $^

$(DUAL_SYNTH): ../rtl/eap16_event_router.sv binary_lut_pe.sv binary_lut_array.sv binary_lut_dual_array.sv
	mkdir -p $(BUILD_DIR)
	$(YOSYS) -Q -q -l $(BUILD_DIR)/binary_lut_dual_yosys.log \
	    -p "read_verilog -sv $^; synth_gowin -top binary_lut_dual_array -json $@"

$(DUAL_ROUTED): $(DUAL_SYNTH)
	$(NEXTPNR) --json $< --write $@ --device $(GOWIN_DEVICE) \
	    --freq 13.5 --report $(DUAL_REPORT)

$(DUAL_PLACED): $(DUAL_SYNTH)
	$(NEXTPNR) --json $< --write $@ --device $(GOWIN_DEVICE) \
	    --freq 13.5 --no-route --report $(DUAL_PLACE_REPORT)

$(BOARD_SYNTH): $(BOARD_RTL)
	mkdir -p $(BUILD_DIR)
	$(YOSYS) -Q -q -l $(BUILD_DIR)/binary_lut_tangnano9k_yosys.log \
	    -p "read_verilog -sv $^; synth_gowin -top $(BOARD_TOP) -json $@"

$(BOARD_ROUTED): $(BOARD_SYNTH) $(BOARD_CST)
	$(NEXTPNR) --json $< --write $@ --device $(GOWIN_DEVICE) \
	    --cst $(BOARD_CST) --freq 13.5 \
	    --report $(BUILD_DIR)/binary_lut_tangnano9k_pnr_report.json

$(BOARD_BITSTREAM): $(BOARD_ROUTED) $(BOARD_CST)
	$(GOWIN_PACK) -d $(PACK_DEVICE) -s $(BOARD_CST) -o $@ $<

$(SIM_DEFAULT): $(SOURCES)
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -Wno-timescale -s tb_bit_sequence_learner -o $@ $(SOURCES)

$(SIM_MIN): $(SOURCES)
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -Wno-timescale -s tb_bit_sequence_learner \
	    -Ptb_bit_sequence_learner.HISTORY_BITS=2 -o $@ $(SOURCES)

$(SIM_MAX): $(SOURCES)
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -Wno-timescale -s tb_bit_sequence_learner \
	    -Ptb_bit_sequence_learner.HISTORY_BITS=12 \
	    -Ptb_bit_sequence_learner.CACHE_ENTRIES=64 -o $@ $(SOURCES)

$(SIM_EVICTION): bit_sequence_learner.sv tb_bit_sequence_cache_eviction.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -Wno-timescale -s tb_bit_sequence_cache_eviction -o $@ $^

$(SIM_BINARY_PE): binary_lut_pe.sv tb_binary_lut_pe.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -Wno-timescale -s tb_binary_lut_pe -o $@ $^

$(BENCH_SIM): bit_sequence_learner.sv benchmark.sv
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -Wno-timescale -s tb_bit_sequence_benchmark -o $@ $^
