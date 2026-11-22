<!--
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
-->

# EAP-16 — Experience-Adaptive Processor

EAP-16 is an integer-only, event-driven spiking-network RTL prototype. Its
synaptic graph is stored in mutable registers; the FPGA fabric does not
physically reconfigure itself during learning.

![Diagram of implemented EAP-16 interfaces and current hardware status](docs/eap16-implemented-interfaces.svg)

![Single-PE internals and logical 16-PE interconnection](docs/eap16-pe-detail.svg)

## Run the tests

Install Icarus Verilog (`iverilog` and `vvp`) and GNU Make, then run:

```sh
make test
```

The self-checking tests cover reset, the minimum legal PE parameters
(`N=2`, `FANIN=1`), self-connection exclusion, source ID zero, connection
formation and queued allocation, potentiation, depression, simultaneous
pre/post priority, signed weight saturation, pruning, LIF integration and
threshold behavior, 4-bit weight/idle-age parameters, and the Tang Nano 9K
UART command sequence. The event-router test covers FIFO ordering, simultaneous
feedback spikes, external-event backpressure, overflow reporting, and
top-level spike feedback. The PE test also verifies that disabling plasticity
freezes learning state while LIF membrane/spike behavior remains active.

## Compare the SNN implementations

Run the seeded classification and mapped-resource comparison with:

```sh
make benchmark
```

The benchmark requires Python 3.10+ (standard library only), Icarus Verilog,
Yosys with `synth_gowin`, and GNU Make. The number of trials and starting seed
are configurable, for example:

```sh
make benchmark BENCHMARK_TRIALS=12 BENCHMARK_SEED=20
```

The defined task is two-class event-pattern classification on 16 PEs. Class 0
uses feature sources 0–3 and class 1 uses sources 4–7; output neurons are PE 14
and PE 15. Each trial trains EAP-16 on four labeled feature-pair patterns
(two per class), then scores the four held-out pair combinations per class.
Evaluation adds a short opposite-class confuser and 0–3 unconnected distractor
events. The class with more output spikes wins; ties count as incorrect.
Plasticity is enabled during training and frozen during evaluation using
`learning_enable`. The fixed-topology baseline starts with the eight
ground-truth feature-to-class edges at weight +8, while EAP-16 starts with no
edges. The software reference is cycle-checked against the fixed RTL, including
spikes, backpressure, and overflow. The comparison uses a threshold of 100 to
make the short task observable; the RTL default remains 1000. Both network
cores use `N=16`, 8-bit weights, and a 64-entry shared event FIFO.

With the default eight seeds (1–8), the software reference, fixed-topology RTL,
and adaptive EAP-16 each classify 64/64 held-out patterns (100%; 32/32 per
class). These results show that EAP-16 learned the intended mapping for this
synthetic task, not that it outperforms the fixed baseline: the baseline is
preconfigured with the correct, stable topology.

The same `make benchmark` command maps both network cores through Yosys
`synth_gowin`. Current mapped primitive counts are:

| Model | LUT1–4 | MUX2_LUT | ALU | FF | RAM primitives | Mapped cells |
|---|---:|---:|---:|---:|---:|---:|
| Fixed topology | 1,408 | 474 | 1,200 | 543 | 4 | 3,753 |
| Adaptive EAP-16 | 36,571 | 4,595 | 20,489 | 8,351 | 4 | 70,135 |

On this mapping, adaptive EAP-16 uses 25.97× the LUT1–4 cells and 15.38× the
flip-flops (about +2,497% and +1,438%, respectively), for no accuracy gain on
this oracle-topology task. This is a strong overhead for a static known mapping;
the possible benefit on unknown or changing topologies is not measured here.
The adaptive synthesis top keeps `learning_enable` as a runtime input; the
board wrapper ties it high, so the freeze-control logic may optimize away in
that integration. These are synthesis-mapped primitive counts, not placed
area, timing, power, or energy results. The per-pattern scores, per-trial
summary, cycle traces, and synthesis summary are written under `build/`.

## Network and synapse-width experiments

`PE_COUNT` controls the instantiated PE count (2–16, default 16). `WEIGHT_W`
and `IDLE_W` configure synapse weight and idle-age widths; their Rev 0.2
defaults are 8 bits. `EVENT_FIFO_DEPTH` defaults to 64 and must be at least 2;
it sets both the shared event FIFO depth and the per-source pending-spike
counter limit. Override them through Make:

```sh
make test PE_COUNT=2 WEIGHT_W=4 IDLE_W=4
make bitstream PE_COUNT=2 WEIGHT_W=4 IDLE_W=4
make test PE_COUNT=2 WEIGHT_W=4 IDLE_W=4 EVENT_FIFO_DEPTH=16
```

`WEIGHT_W` supports 2–8 bits and uses symmetric saturation
[-(2^(W-1)-1), +(2^(W-1)-1)]. The default initial/fixed weight scales from +8
at 8 bits to +4 at 7 bits, +2 at 6 bits, and +1 at 2–5 bits. This approximates
the same fraction of signed full scale, with a minimum nonzero positive weight.
`INITIAL_WEIGHT` and `FIXED_WEIGHT` can still be overridden explicitly.
At 3–5 bits the +1 default is below the default +2 `MIN_WEIGHT`; an unused
connection can therefore be pruned after its idle age reaches `PRUNE_AGE`.
`IDLE_W` supports 1–8 bits; its default prune age is 200 ticks at 8 bits and
the maximum representable age at narrower widths. Width changes alter learning
dynamics and PE-count changes alter network capacity; each configuration
needs simulation and place-and-route validation. The previously measured
default 16-PE UART image did not fit the Tang Nano 9K; that estimate predates
the shared router (see the hardware status below).

## Build and program the Tang Nano 9K

The open-source FPGA flow needs Yosys with `synth_gowin`, `nextpnr-gowin`,
`gowin_pack`, and `openFPGALoader`:

```sh
make bitstream
make program
```

When the board target fits, `make bitstream` writes
`build/eap16_tangnano9k_n16_w8_i8_q64.fs` with the default parameters, and
`make program` loads it over JTAG. Programming is volatile and must be repeated
after power is removed. Close the serial terminal before programming the board.
To load the fitted two-PE experiment, run
`make program PE_COUNT=2 WEIGHT_W=4 IDLE_W=4 EVENT_FIFO_DEPTH=64`.

The 27 MHz board clock is divided by two for the EAP core (13.5 MHz), below
the configured timing target. The UART uses 115200 baud, 8 data bits, no parity,
and one stop bit (8N1). When a UART-enabled bitstream is available, connect to
the Tang Nano 9K's USB serial port, then send one command at a time and wait
for its response:

```text
EVENT 00
EVENT 00
... repeat until eight EVENT commands have been acknowledged ...
TEACH 01
READ 01
```

`EVENT nn` injects one source event, `TEACH nn` injects a teacher spike at a
PE, `TICK` advances maintenance by one cycle, `READ nn` reports that PE's
connection count and current spike bit, and `HELP` lists the commands. IDs are
decimal from 00 through `PE_COUNT-1` (up to 15). The UART does not currently
return individual synapse sources or weights; those are checked in simulation.

The currently programmed pre-router two-PE, 4/4-bit image used the old +7
initial-weight fallback; the current RTL default for a 4-bit weight is +1.
With the default 16-PE, 8/8-bit configuration, the initial weight remains +8.
A later teacher spike can potentiate a connection while its candidate trace
remains active. A `TICK` decays traces and ages connections. The host should
wait for each text reply before sending another command; an overlapping
command is discarded and reported as `ERR BUSY`.

- LED 0 blinks as a heartbeat.
- LED 1 turns on when the most recently selected PE has at least one incoming
  connection.
- LEDs 5:2 show the low four bits of that PE's connection count.
- LEDs are active-low.
- All six LEDs turn on if the event router reports feedback-counter overflow;
  this sticky fault clears on reset.

The board uses UART TX on pin 17 and RX on pin 18, plus its 27 MHz oscillator,
active-low reset, and six LEDs. Pin assignments are in
[`constraints/tangnano9k.cst`](constraints/tangnano9k.cst).

**Current hardware status:** the previously measured default 16-PE UART image
did not place on the GW1NR-9C (63,456/8,640 slices); that estimate predates the
shared event router and is not a measurement of the current RTL. The
configurable `PE_COUNT=2 WEIGHT_W=4 IDLE_W=4` image placed at 1,716/8,640
slices and is currently programmed; it also predates the router. The current
16-PE network cores have been Gowin-mapped for the comparison, but the UART
board top has not been placed or timing-closed with the router.

## Project layout

- [`rtl/eap_dynamic_pe.sv`](rtl/eap_dynamic_pe.sv) — LIF state, synapses,
  candidate traces, learning, formation, and pruning for one PE.
- [`rtl/eap16_event_router.sv`](rtl/eap16_event_router.sv) — shared event FIFO,
  round-robin arbitration, and per-source feedback-spike staging.
- [`rtl/eap16_top.sv`](rtl/eap16_top.sv) — routed 16-PE network integration.
- [`rtl/eap16_fixed_topology_top.sv`](rtl/eap16_fixed_topology_top.sv) —
  static-connectivity LIF RTL baseline for comparisons.
- [`learning_enable`](rtl/eap16_top.sv) gates online plasticity; the board top
  holds it high, while the benchmark disables learning for held-out evaluation.
- [`rtl/eap16_uart_console.sv`](rtl/eap16_uart_console.sv),
  [`rtl/uart_rx.sv`](rtl/uart_rx.sv), and [`rtl/uart_tx.sv`](rtl/uart_tx.sv) —
  UART commands, receive, and transmit.
- [`rtl/eap16_tangnano9k_top.sv`](rtl/eap16_tangnano9k_top.sv) — board
  UART interface and LED status.
- [`tb/`](tb) — self-checking SystemVerilog testbenches.
- [`tb/tb_snn_comparison.sv`](tb/tb_snn_comparison.sv) and
  [`tools/compare_snn.py`](tools/compare_snn.py) — common-workload simulation
  comparison and integer software reference.
- [`docs/DESIGN.md`](docs/DESIGN.md) — architecture and limitations.
- [`docs/eap16-implemented-interfaces.svg`](docs/eap16-implemented-interfaces.svg)
  — current interface and data-flow diagram.
- [`docs/eap16-pe-detail.svg`](docs/eap16-pe-detail.svg) — PE internals and
  logical network connections.

## Current limitations

The shared FIFO defaults to 64 entries. A round-robin arbiter accepts either a
valid external event or one queued internal spike per cycle, and broadcasts
the FIFO head to all PEs. External producers must hold `event_valid` and
`event_source` stable until `event_ready` is asserted. Feedback spikes are
counted per source while waiting for arbitration; if a per-source counter
fills, `event_overflow` latches until reset and the incoming spike cannot be
retained. This bounded-overload fault is shown by all LEDs turning on. UART
`READ` does not return individual weights. Teacher spikes are still a training
aid. `learning_enable=0` freezes traces and synapse formation, weight, age, and
pruning updates while the membrane and spike path continues to run. The board
ties this input high, preserving its existing online-learning behavior.
Simulation passing does not establish general task accuracy, timing, power, or
application performance.

## Validation report

Validated in this workspace:

- The PE, parameter-boundary, event-router, UART command/readback, and board
  tests pass with Icarus Verilog 12.0-2+b1.
- `make benchmark PYTHON=/usr/bin/python3` passes with Python 3.13.5,
  Icarus Verilog 12.0-2+b1, and Yosys 0.52. The fixed software reference
  matches the fixed RTL; all three models score 64/64 on the specified
  synthetic task.
- Yosys `synth_gowin` mapped both 16-PE comparison network cores; see the
  benchmark table above. No place-and-route run was made for these variants.
- Yosys 0.52 structural check for `N=2`, `FANIN=1`, and
  `EVENT_FIFO_DEPTH=4`:
  ```sh
  yosys -Q -p "read_verilog -sv rtl/eap_dynamic_pe.sv rtl/eap16_event_router.sv rtl/eap16_top.sv; \
    chparam -set N 2 -set FANIN 1 -set EVENT_FIFO_DEPTH 4 eap16_top; \
    hierarchy -check -top eap16_top; proc; check"
  ```
  reports zero structural problems. This is not a full synthesis, placement,
  timing, or area result.
- Yosys 0.52-2 maps the standalone UART console to about 790 LUT cells and 178
  flip-flops. This is separate from the PE array and is not a full-board area
  result.
- The pre-router `PE_COUNT=2 WEIGHT_W=4 IDLE_W=4` image placed at
  1,716/8,640 slices, passed the 13.5 MHz timing check, and was loaded to the
  attached GW1N(R)-9C; openFPGALoader 0.13.1-1 reported DONE. This is the
  currently loaded image, not the current routed RTL.
- The pre-router default-width 16-PE UART target failed placement at
  63,456/8,640 slices with nextpnr-gowin 0.7-1+b2. This does not measure the
  current router integration. The earlier fixed demo did not prove the full
  16-PE network fit.
