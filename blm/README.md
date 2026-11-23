<!--
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
-->

# BLM: FPGA learning experiments

This folder contains two standalone synthesizable FPGA learning experiments:

- [`bit_sequence_learner.sv`](bit_sequence_learner.sv): an online,
  bounded-context next-bit predictor (not a language model or part of the
  spiking network).
- [`binary_lut_pe.sv`](binary_lut_pe.sv) and its multi-network fabric
  ([`binary_lut_array.sv`](binary_lut_array.sv),
  [`binary_lut_dual_array.sv`](binary_lut_dual_array.sv)): a binary-synapse
  spiking network with direct PE-addressed / broadcast events, multi-hot peer
  spike broadcast, a 1-bit serial scan-chain snapshot/restore mechanism, and
  two Tang Nano 9K UART board wrappers (a 1×16 ASCII wrapper and a 4×16
  binary UART + snapshot wrapper).

Both experiments are separate from the signed-weight EAP-16 network in
[`../rtl/`](../rtl). Learned connectivity is logical state stored in
flip-flops; the FPGA fabric does not physically reconfigure itself.

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

## Binary-synapse LUT PE and array architecture

[`binary_lut_pe.sv`](binary_lut_pe.sv) is a compact binary-synapse PE variant
separate from EAP-16. It holds a 2-bit membrane state, a 1-bit `spike` output,
an `N`-bit `synapse_on` mask, an `N`-bit `candidate_pre` flag mask, and a
1-bit `post_recent` flag.

- **Membrane & spike dynamics:** `synaptic_input = |(event_source_mask & synapse_on)`.
  A connected event increments the 2-bit membrane state (`0 -> 1 -> 2`); a
  connected event in state 2 (or entering state 3) spikes and resets the
  membrane to 0. A `maintenance_tick` leaks the membrane by 1 when there is no
  connected event; synaptic input takes priority over a simultaneous tick.
  `teacher_spike` forces a spike and reset.
- **Online plasticity:** non-self source events set `candidate_pre` bits
  (cleared on `maintenance_tick`). A postsynaptic spike forms synapses for
  flagged non-self sources and sets `post_recent`. A presynaptic event while
  `post_recent` is high disconnects that source; formation wins on a
  simultaneous formation/depression. `learning_enable=0` freezes synapses and
  flags while membrane integration and spiking continue.
- **Parameters & boundaries:** requires `N >= 2` and `0 <= PE_ID < N`.
  Self-connections and self-traces are always masked to zero (`NONSELF_MASK`).
  This variant is excitatory-only and omits idle-age pruning (deliberate
  differences from signed-weight EAP-16).

[`binary_lut_array.sv`](binary_lut_array.sv) instantiates `N` PEs (`2 <= N <= 16`)
with **no round-robin router or event FIFO**:

- External events use `event_valid`, `event_source`, `event_target_pe`, and
  `event_broadcast` (`0` = target a single PE; `1` = broadcast to all PEs),
  with `event_ready` backpressure during reset, snapshot pause, or an
  out-of-range target PE.
- Internal PE spikes are combined directly into every PE's `event_source_mask`
  as a multi-hot vector (`external_onehot | spikes`), so simultaneous spikes
  broadcast in parallel without queuing or arbitration.
- Optional connection counting is controlled by `COUNT_ENABLE` (default `1`)
  and `COUNT_SELECTED_ONLY` (default `0`, per-PE counts; `1` counts only
  `selected_pe` using a balanced popcount tree).

For standalone PE synthesis and placement without routing, run
`make -C blm fpga-check` or `make -C blm fpga-place`. With `N=16` and
`SNAPSHOT_ACCESS=0`, Yosys 0.52 (`synth_gowin -nowidelut`) maps 65 LUT1–LUT4
cells and 34 flip-flops; nextpnr-gowin 0.7-1+b2 places it at **67/8,640
slices** (no-route standalone estimate, not a full-array timing result).

## Generic parallel BLM networks

[`binary_lut_dual_array.sv`](binary_lut_dual_array.sv) retains its original
module name, with configurable `NETWORK_COUNT` (default 4) and `N` PEs per
array (default 16). Each array has its own PE-addressed event input
(`event_valid`, `event_source`, `event_target_pe`, `event_broadcast`,
`event_ready`), `teacher_spike` mask, `learning_enable`, `maintenance_tick`,
and multi-hot peer spike broadcast (`spikes` ORed into every PE's source mask
with no round-robin router or FIFO). Arrays share only clock, reset, and
snapshot controls; they process separate streams in parallel and learn
separate connection masks.

The flat, combinational synapse read port (`SYNAPSE_READ_PORT=0` by default)
and connection-count logic (`CONNECTION_COUNTS=0` by default) are opt-in for
area. Set `SYNAPSE_READ_PORT=1` for live one-bit reads using address
`network_id*N*N + target_pe*N + source_id`.

Exact state snapshot and restore (`SNAPSHOT_ACCESS=1` by default) uses a
1-bit serial scan chain across all PEs and networks rather than wide random-
access read/write muxes. Assert `snapshot_pause` for the whole scan or
restore; this pauses every array, deasserts `event_ready`, and asserts
`snapshot_ready` once out of reset. While paused, assert
`snapshot_shift_enable` to advance the chain by one bit per rising clock edge:

- **Save (`snapshot_write_enable=0`)**: `snapshot_read_data` shifts out the
  chain tail while feeding back into the chain head (non-destructive circular
  scan). After `SNAPSHOT_TOTAL_BITS` cycles, the entire state is captured and
  every register is back in its original position.
- **Restore (`snapshot_write_enable=1`)**: drive `snapshot_write_data` with
  the saved bits in the same order they were read out for
  `SNAPSHOT_TOTAL_BITS` cycles.

Each PE chains `2*(N-1) + 4` real state bits (excluding the permanently-zero
self-connection and self-trace bits): `N-1` `synapse_on` bits, `N-1`
`candidate_pre` bits, 2-bit `membrane_state`, `post_recent`, and `spike`. For
`N=16`, that is 34 bits/PE, 544 bits (68 bytes) per network, **1,088 bits
(136 bytes)** for 2 networks, and **2,176 bits (272 bytes)** for the default
4 networks. Any external producer event not accepted before pausing is outside
the snapshot and should stay stable until resume.

Run the throughput, spike-broadcast, isolation, and scan-chain snapshot checks
with:

```sh
make -C blm dual-network-test
make -C blm quad-board-test
```

The fabric self-check verifies `NETWORK_COUNT=2` (`N=16`, 1,088 bits),
`NETWORK_COUNT=3` (`N=16`, 1,632 bits), `NETWORK_COUNT=4` (`N=16`, 2,176
bits), and `NETWORK_COUNT=2` (`N=8`, 288 bits). Each network accepts 256
addressed events in 256 cycles with zero stalls, combines simultaneous peer
spikes into one multi-hot mask, isolates learning between networks, and passes
non-destructive circular readback -> zero overwrite -> full restore ->
bit-exact verification. The full BLM suite passes with Icarus Verilog 12.0 via
`make -B -C blm test`.

### Minimal binary UART interface & quad Tang Nano 9K board top

[`blm_uart_bridge.sv`](blm_uart_bridge.sv) and
[`binary_lut_quad_tangnano9k_top.sv`](binary_lut_quad_tangnano9k_top.sv) wrap
4 × 16-PE BLM networks (64 PEs total) with a compact binary UART bridge
(115200 8N1, pins in [`tangnano9k_quad_binary_lut.cst`](tangnano9k_quad_binary_lut.cst)):

| Command bytes | Action | Reply |
|---|---|---|
| `0x00` | `PING` | `0x55` |
| `0x1n` (`n=0..3`) | Select active network `n` (clears latched spikes) | `0x1n` (or `0xFE`) |
| `0x2x` | Set `learning_enable[net] = x[0]` | `0x2x` |
| `0x30 {pe[3:0], src[3:0]}` | Send addressed event to `pe` on active network | `0x30` (or `0xFE`) |
| `0x31 {4'b0, src[3:0]}` | Broadcast `src` to all PEs on active network | `0x31` (or `0xFE`) |
| `0x4p` (`p=0..15`) | Pulse `teacher_spike[net, p]` | `0x4p` (or `0xFE`) |
| `0x50` | Pulse `maintenance_tick[net]` | `0x50` (or `0xFE`) |
| `0x60` | Read & clear 16-bit latched spikes on active network | 2 bytes (`lo`, `hi`) |
| `0x70` | `SNAPSHOT_SAVE` (auto-pauses, non-destructive circular scan) | 272 bytes |
| `0x71` + 272 bytes | `SNAPSHOT_LOAD` (auto-pauses, restores all 4 networks) | `0x71` |
| `0x72` / `0x73` | Manual pause on / off | `0x72` / `0x73` |

Build and program the quad-network Tang Nano 9K bitstream with:

```sh
make -C blm quad-board-bitstream
make -C blm quad-board-program
```

With `N=16`, `NETWORK_COUNT=4`, `SNAPSHOT_ACCESS=1`, Yosys 0.52
(`synth_gowin -nowidelut`) maps 8,216 LUT1–LUT4 cells, 60 ALU cells, and
2,409 flip-flops. nextpnr-gowin 0.7-1+b2 **places and fully routes** the
pin-constrained Tang Nano 9K image at **8,422/8,640 slices (97%)**, 10/274
IOBs, and **45.09 MHz** routed maximum for `eap_clk` against the 13.5 MHz
constraint, and `gowin_pack` produces
`build/blm/binary_lut_quad_tangnano9k.fs`. Physical hardware UART verification
on the board has not been run yet.

For core-only unconstrained dual-network placement/routing (`N=16`,
`NETWORK_COUNT=2`, `SNAPSHOT_ACCESS=1`), `make -C blm dual-network-place`
placed and routed at **3,860/8,640 slices (44%)**, 124/274 IOBs, and
**64.51 MHz** routed maximum.

Run the 16-PE network benchmark with:

```sh
make -C blm network-benchmark
```

Latest run (Icarus Verilog 12.0): the broadcast stream delivered 4,096
PE-events in 256 cycles (16 PE-events/cycle), and the addressed learning path
formed source 0 on PE 1, spiked in 8 cycles, and verified peer spike
broadcast. These are RTL simulation measurements.

The single-network Tang Nano 9K UART top (`make -C blm board-bitstream`,
16 PEs, UART console, and status LEDs, synthesized with `-nowidelut`) placed
and routed at **2,103/8,640 slices (24%)** with a **45.12 MHz** routed maximum
for `eap_clk` against the 13.5 MHz constraint. The complete board run is
recorded in
[`binary_lut_tangnano9k_pnr_report.json`](../build/blm/binary_lut_tangnano9k_pnr_report.json).

At the constrained clock, one event broadcast per cycle corresponds to a
theoretical 13.5 million network broadcasts/s (216 million PE-event updates/s
across 16 PEs). This is derived from the RTL rate and timing estimate, not a
measured board throughput or power result. The board heartbeat is active, but
the UART hardware smoke test has not produced a reply; physical end-to-end
operation remains unverified.

## Compare against EAP-16 and fixed topology

From the repository root, run `make benchmark-networks` to compare the binary
LUT network (using the single-stream broadcast wrapper
[`binary_lut_array_benchmark_top.sv`](binary_lut_array_benchmark_top.sv)),
adaptive EAP-16, and the fixed-topology SNN on the same seeded event-pattern
task. The default run uses eight seeds and scores eight held-out patterns per
seed:

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
  Fixed-topology SNN               894       403   978   554     4   2957
  Adaptive EAP-16                35868      4407 20257  8362     4  69023
  Binary-LUT BLM                  3567      2438    64   544     0   6741
Primitive counts are not placement, timing, power, or area results. No physical event-rate or application-scale claim is made.
Per-trial results: build/snn_binary_comparison_trials.csv
```

Note that `make benchmark-networks` runs default `synth_gowin` (with wide-LUT
mapping enabled) for an apples-to-apples synthesis command across all three
models; BLM uses zero RAM primitives because it has no event FIFO. For FPGA
placement and routing, the `blm/` targets pass `synth_gowin -nowidelut`, which
eliminates Gowin `MUX2_LUT5..8` slice bloat.

The fixed-topology model is an oracle baseline with the correct connections
prewired, so equal accuracy does not show that learning improves this task.
The benchmark uses teacher-labeled training and a small synthetic workload;
it is not a general SNN quality test or a comparison to a dense ANN. Primitive
counts are for synthesis-mapped network cores, not placed area or timing.

## Files and Make targets

- [`bit_sequence_learner.sv`](bit_sequence_learner.sv),
  [`tb_bit_sequence_learner.sv`](tb_bit_sequence_learner.sv),
  [`tb_bit_sequence_cache_eviction.sv`](tb_bit_sequence_cache_eviction.sv),
  [`benchmark.sv`](benchmark.sv) — bounded-context bit-sequence learner.
- [`binary_lut_pe.sv`](binary_lut_pe.sv),
  [`tb_binary_lut_pe.sv`](tb_binary_lut_pe.sv) — binary-synapse PE with
  serial scan-chain snapshot support.
- [`binary_lut_array.sv`](binary_lut_array.sv),
  [`binary_lut_array_benchmark_top.sv`](binary_lut_array_benchmark_top.sv),
  [`tb_binary_lut_network_benchmark.sv`](tb_binary_lut_network_benchmark.sv) —
  16-PE router-free array and benchmarks.
- [`binary_lut_dual_array.sv`](binary_lut_dual_array.sv),
  [`tb_binary_lut_dual_array.sv`](tb_binary_lut_dual_array.sv) — generic
  multi-network fabric (`NETWORK_COUNT=4`, `N=16`, `SNAPSHOT_ACCESS=1`).
- [`blm_uart_bridge.sv`](blm_uart_bridge.sv),
  [`binary_lut_quad_tangnano9k_top.sv`](binary_lut_quad_tangnano9k_top.sv),
  [`tangnano9k_quad_binary_lut.cst`](tangnano9k_quad_binary_lut.cst),
  [`tb_binary_lut_quad_tangnano9k_top.sv`](tb_binary_lut_quad_tangnano9k_top.sv)
  — 4×16-PE Tang Nano 9K binary UART + 272-byte snapshot top.
- [`binary_lut_tangnano9k_top.sv`](binary_lut_tangnano9k_top.sv),
  [`tangnano9k_binary_lut.cst`](tangnano9k_binary_lut.cst),
  [`tb_binary_lut_tangnano9k_top.sv`](tb_binary_lut_tangnano9k_top.sv) —
  single-network 1×16-PE ASCII UART Tang Nano 9K top.

Key Make targets (`make -C blm <target>`): `test`, `benchmark`,
`network-benchmark`, `dual-network-test`, `dual-network-estimate`,
`dual-network-place`, `fpga-check`, `fpga-place`, `board-bitstream`,
`board-program`, `quad-board-test`, `quad-board-bitstream`, and
`quad-board-program`.
