<!--
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
-->

# BLM: FPGA learning experiments

This folder contains two standalone synthesizable experiments:

- [`bit_sequence_learner.sv`](bit_sequence_learner.sv): an online,
  bounded-context next-bit predictor, not a language model.
- [`binary_lut_pe.sv`](binary_lut_pe.sv): a binary-synapse PE with a small
  LUT-style membrane transition function.

Neither is integrated with the EAP network or UART.

## Context-table bit-sequence learner

`HISTORY_BITS` defaults to 4 and must be in the range 2 through 12.
`CACHE_ENTRIES` defaults to 32 and must be in the range 1 through 64. The
fixed-capacity, fully associative cache stores a valid bit, the complete
`HISTORY_BITS`-wide context tag, and a 2-bit saturating successor counter per
entry. Its state grows as `CACHE_ENTRIES * (HISTORY_BITS + 3)` bits rather than
`2**HISTORY_BITS` counters, plus history, control, and replacement-pointer
state. The fully associative lookup compares the bounded set of tags each
cycle.

On a cache hit, the counter's high bit is the prediction; observing a successor
`1` increments the counter and `0` decrements it. Counters saturate at
`2'b00` and `2'b11`. A miss has no learned prediction (`next_bit_valid=0`,
`next_bit_prediction=0`); the observed successor installs a new entry with
that first observation applied. Allocation uses the first invalid entry, then
round-robin replacement when full. Hits do not move the replacement pointer.
Reset clears the cache and history.

`next_bit_prediction` is available before the next input bit is accepted, and
`next_bit_valid` is high only when the history is full and its tag is cached.
Assert `bit_valid` for each observed bit. Assert `sequence_start` with the
first bit of a new sequence to clear history without clearing cached learning;
the first `HISTORY_BITS` bits seed context without training across the boundary.
Asserting `sequence_start` without `bit_valid` also clears history. Idle clock
cycles do not change the model; it learns bit order, not elapsed time. A UART
decoder would need to deliver each payload bit using `bit_valid`.

This is bounded-order learning, not truly unbounded arbitrary-sequence
learning. At the default setting, it can learn next-bit mappings determined by
the previous four bits, while retaining at most 32 contexts. If more distinct
contexts occur, round-robin replacement forgets older ones. A larger context
helps only when earlier bits disambiguate successors.

![Diagram comparing the current full-tag cache lookup with a hash-indexed alternative](./context_cache.svg)

Run the self-checking simulations with:

```sh
make -C blm test
```

This tests the minimum (`HISTORY_BITS=2`), default (`4`), and maximum (`12`)
history lengths, plus miss handling and round-robin eviction in a two-entry
cache; the maximum history test also uses the maximum 64-entry cache. Run the
default four-bit-context accuracy benchmark with:

```sh
make -C blm benchmark
```

The benchmark trains and then scores streams online, counting each prediction
before learning from that bit. It excludes the first four bits of each scored
sequence and compares against a constant-zero baseline. In addition to
alternating `0101` and repeated `0011`, the order-4 de Bruijn sequence covers
all 16 four-bit contexts. These are simulation results, not FPGA throughput or
hardware resource measurements.

## Binary-synapse LUT PE experiment

[`binary_lut_pe.sv`](binary_lut_pe.sv) is a standalone PE variant; it does not
replace or connect to EAP-16. Its two-bit membrane register is advanced by an
explicit 16-row transition table indexed by membrane state, binary synaptic
input, and maintenance tick. Synthesis maps that table to FPGA logic; the
registers still hold the membrane state. The state advances `0 -> 1 -> 2`;
a connected event in state 2 spikes and resets to 0. A maintenance tick
decrements the state when there is no connected event, and an event takes
priority over a simultaneous tick. `teacher_spike` also forces a spike/reset.

Synapses are a one-bit-per-source connection mask. A connected event adds one
membrane step; a maintenance tick leaks one step when there is no connected
event. Each source has a one-bit pre-activity flag, set by an event and cleared
by a maintenance tick, plus one bit for recent post activity. A postsynaptic
spike forms connections for flagged non-self sources; a presynaptic event
after recent post activity disconnects that source. Formation wins on a
simultaneous formation/depression.
`learning_enable=0` freezes flags and synapses while membrane updates continue.
The parameters require `N >= 2` and `0 <= PE_ID < N`; an out-of-range event ID
selects no synapse. This variant is excitatory-only and omits idle pruning;
both are deliberate differences from the signed-weight EAP PE.

The array supports `2 <= N <= 16` and `FIFO_DEPTH >= 2`. It decodes the routed
source ID once to a one-hot vector; all-zero means no valid event. The default
`COUNT_SELECTED_ONLY=0` reports each PE's connection count. The board top sets
it to 1 and supplies `selected_pe`; only that PE's 16-bit synapse mask is
counted, with the selected count replicated across the packed bus for the
UART console. An out-of-range selected ID returns zero.

The binary PE simulation is included in `make -C blm test`. Run
`make -C blm fpga-check` for generic synthesis and structural checking, or
`make -C blm fpga-place` for Gowin mapping and placement without routing. For
the standalone one-hot-input `N=16` PE, Yosys 0.52 maps 122 LUT1-LUT4 cells
and 34 flip-flops; nextpnr-gowin 0.7 places it at 139/8,640 slice sites.
Its source ID is decoded once by the network array and shared to all PEs.
The no-route standalone report is not a full-array placement or timing result.

The shared event source is decoded once in `binary_lut_array`, replacing
replicated per-PE source-ID comparisons. Connection counts use a balanced
popcount tree. For the UART top, `COUNT_SELECTED_ONLY` computes only the
selected PE's count rather than 16 independent counts. The array's default
mode still reports every PE count for benchmarks.

## Generic parallel BLM networks

[`binary_lut_dual_array.sv`](binary_lut_dual_array.sv) retains its original
module name, but `NETWORK_COUNT` now configures how many independent BLM
arrays it instantiates (default 2). Each array has its own event valid/ready
input, event source, teacher-spike mask, maintenance tick, FIFO, and feedback
path. Arrays share only clock and reset; they process separate streams in
parallel and learn separate connection masks. This is a core-level experiment,
not yet a UART/board wrapper or a multilayer network. `N` configures the PEs
per array (default 16).

The flat, combinational synapse read port is optional. `SYNAPSE_READ_PORT=0`
is the area-saving default because the snapshot map already contains the
synapses; with the port disabled, `synapse_read_data` is tied low. Set
`SYNAPSE_READ_PORT=1` for live one-bit reads using address
`network_id*N*N + target_pe*N + source_id`. With two 16-PE arrays, this is a
9-bit address over 512 connection bits: network 0, PE 1, source 0 is address
16; network 1, PE 2, source 0 is address 288.

The 32-bit snapshot map is network-major and covers the complete resumable
state. Assert `snapshot_pause` for the whole scan or restore; this pauses every
array and deasserts `event_ready`. Reads are combinational. A write is accepted
on the rising clock edge when `snapshot_write_enable` and
`snapshot_write_ready` are high. `snapshot_write_ready` is high only while
paused, out of reset, and addressed within the map. Any producer event that
was not accepted before pausing is outside the network snapshot; keep its
`valid` and source stable until it is accepted after resume.

For the default `N=16`, `FIFO_DEPTH=64`, each network occupies 113 words:

| Local word addresses | Contents |
|---|---|
| 0–31 | Two words per PE, in PE-ID order. Word 0 is `{candidate_pre, synapse_on}`; in word 1, bit 3 is `spike`, bit 2 is `post_recent`, and bits 1:0 are membrane state. |
| 32–95 | The 64 physical FIFO ring slots. Inactive slots read as zero. |
| 96–111 | The 16 pending-feedback counters, in source-ID order. |
| 112 | Router control: FIFO count, read/write pointers, `last_grant`, and sticky overflow in bits 24:0. |

Thus the default two-network map has 226 words and an 8-bit global address.
The FIFO ring contents and pointers/count are both included, so queued events
and pending feedback survive restore exactly.

Run its throughput and isolation checks with:

```sh
make -C blm dual-network-test
```

The self-check runs both the default two-network configuration and a
three-network configuration. With simultaneous streams, each network
delivered 256 events in 257 cycles with no stalls: 0.996 broadcasts/cycle per
network, or 1.992 aggregate for two and 2.988 for three. A separate check
trained one connection in each of two networks, then changed only network 0;
its selected connection count became 2 while network 1 remained at 1. The
testbench also exercises the optional flat port, queues an event and feedback
spike, then saves, corrupts, restores, and compares the full snapshot map.
These are RTL simulation results. The full BLM suite passes with Icarus
Verilog 12.0 via `make -B -C blm test`.

For target utilization/timing estimation, run:

```sh
make -C blm dual-network-estimate
```

With `N=16`, `FIFO_DEPTH=64`, `NETWORK_COUNT=2`, and the default
`SYNAPSE_READ_PORT=0`, Yosys 0.52 maps 6,096 LUT1-LUT4 cells, 845 ALU cells,
1,426 flip-flops, and 8 RAM16SDP4 blocks. The nextpnr-gowin 0.7-1+b2
placement-only pass uses **7,486/8,640 slices (86.6%)** and estimates
31.25 MHz against the 13.5 MHz constraint. The command uses `--no-route`; it
checks placement and pre-route timing, not routed timing.

`make -C blm dual-network-place` still requests full routing. The unconstrained
full-route attempt was stopped after more than 22 minutes with routing still
in progress, so full-route timing is not verified. This is a core-only result
without the board UART or Tang Nano pin constraints: it does not create or
program a board bitstream. The core has 187 top-level I/O bits, and the UART
snapshot controls and physical board interface still need integration and
validation.

Run the 16-PE network benchmark with:

```sh
make -C blm network-benchmark
```

It checks ordered delivery of a saturated event burst and a teacher-supervised
source-0-to-PE-1 connection followed by an induced spike and feedback event.
It reports cycle-level router throughput and learning-path latency. These are
RTL simulation measurements; do not interpret them as physical UART
throughput or application accuracy.

Latest run (Icarus Verilog 12.0): all 256 offered events were accepted and
delivered in 257 cycles, with zero stalls or overflow (`0.996` broadcasts per
cycle including startup and drain; the steady-state router limit is one
broadcast per cycle). The supervised path formed source 0 to PE 1; three
subsequent source-0 events produced one PE-1 spike 12 cycles after the initial
candidate event, and that spike was routed back as one event.

The optimized Tang Nano 9K top (16 PEs, shared FIFO, UART, and status logic)
placed and routed at 4,135/8,640 slices (47.9%), down from 6,045 slices
(70.0%) before these optimizations: a 31.6% slice reduction. The BLM network
core's Yosys-mapped LUT1-LUT4 count fell from 3,049 to 2,575, ALU cells from
1,168 to 528, and mapped cells from 5,681 to 4,729; flip-flops remained 687.
The count-only board option increases mux cells somewhat, trading combinational
selection for fewer replicated popcount trees. nextpnr-gowin estimated
16.43 MHz maximum for `eap_clk` against the 13.5 MHz constraint. The complete
board run is recorded in
[`binary_lut_tangnano9k_pnr_report.json`](../build/blm/binary_lut_tangnano9k_pnr_report.json).

At the constrained clock, one event broadcast per cycle corresponds to a
theoretical 13.5 million network broadcasts/s (216 million PE-event updates/s
across 16 PEs). This is derived from the RTL rate and timing estimate, not a
measured board throughput or power result. The board heartbeat is active, but
the UART hardware smoke test has not produced a reply; physical end-to-end
operation remains unverified.

## Compare against EAP-16 and fixed topology

From the repository root, run `make benchmark-networks` to compare the binary
LUT network, adaptive EAP-16, and the fixed-topology SNN on the same seeded
event-pattern task. The default run uses eight seeds and scores eight held-out
patterns per seed:

```text
Task: seeded binary event-pattern classification; 8 trials, 64 held-out patterns.
All models receive the same training/evaluation actions per seed; plasticity is frozen during evaluation.
Fixed-topology SNN is an oracle baseline with the correct 8 edges wired in advance; EAP-16 and BLM learn those edges from teacher spikes.
Classifier: larger spike count at PE 14/15 wins; ties count as wrong.
  Model                         Correct   Accuracy   Mean/trial +/- SD
  Fixed-topology SNN (RTL)       64/64   100.00%  100.00% +/- 0.00%
  Adaptive EAP-16                64/64   100.00%  100.00% +/- 0.00%
  Binary-LUT BLM                 64/64   100.00%  100.00% +/- 0.00%
Gowin-mapped network primitive counts (synthesis only):
  Model                         LUT1-4  MUX2_LUT   ALU   FFs   RAM  Cells
  Fixed-topology SNN              1402       470  1200   543     4   3743
  Adaptive EAP-16                36746      4825 20469  8351     4  70520
  Binary-LUT BLM                  3049       648  1168   687     4   5681
Primitive counts are not placement, timing, power, or area results. No physical event-rate or application-scale claim is made.
Per-trial results: build/snn_binary_comparison_trials.csv
```

The fixed-topology model is an oracle baseline with the correct connections
prewired, so equal accuracy does not show that learning improves this task.
The benchmark uses teacher-labeled training and a small synthetic workload;
it is not a general SNN quality test or a comparison to a dense ANN. Primitive
counts are for synthesis-mapped network cores, not placed area or timing.
