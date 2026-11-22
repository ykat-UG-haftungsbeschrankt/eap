<!--
 * Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
 *
 * Permission for non-commercial use is hereby granted,
 * free of charge, without warranty of any kind.
-->

# EAP-16 architecture — revision 0.2

## Design objective

Explore a neuromorphic processor that can alter its **logical computation graph**
through online experience. The prototype is an event-driven spiking neural
network with local learning state and dynamically managed synaptic connections.

The FPGA's physical logic does not reconfigure itself during learning. Instead,
the graph is represented by mutable synapse-table entries in registers or
BRAM. This is the practical meaning of self-organizing hardware in this revision.

## Block-level organization

```text
                 External AER events (valid/ready)
                               |
                               v
          +-------------------------------------------+
          | Shared 64-entry FIFO + round-robin arbiter|
          +-------------------+-----------------------+
                               |
                    source neuron ID / valid
                               |
             +-----------------+-----------------+
             |                 |                 |
             v                 v                 v
        +---------+       +---------+       +---------+
        | PE 0    |  ...  | PE 7    |  ...  | PE 15   |
        | LIF     |       | LIF     |       | LIF     |
        | Synapses|       | Synapses|       | Synapses|
        | Traces  |       | Traces  |       | Traces  |
        | Learner |       | Learner |       | Learner |
        +----+----+       +----+----+       +----+----+
             |                 |                 |
             +-----------------+-----------------+
                               |
                         spike vector
                               |
                  per-source pending counters
                                |
                     feedback into event FIFO
```

## EAP-16 rev 0.2 target parameters

| Item | Target |
|---|---:|
| Processing elements | 16 |
| Incoming synapse slots per PE | 16 |
| Maximum stored slots | 256 |
| Maximum directed non-self edges | 240 |
| Synaptic weight | signed INT8 |
| Membrane potential | signed INT24 |
| Candidate pre-trace | 8-bit per possible source |
| Post-trace | 8-bit |
| Neuron/source ID | 4-bit |
| Event FIFO | 64 entries by default |
| Clock target | 50–100 MHz proposed, not measured |
| Arithmetic | integer add/subtract, shifts, compares |

The Tang Nano 9K UART test configuration uses a 13.5 MHz EAP clock derived
from the board's 27 MHz oscillator and UART RX/TX at 115200 baud. The `N=2`,
4/4-bit configuration placed at 1,716/8,640 slices and passed the 13.5 MHz
timing constraint. The default `N=16`, 8/8-bit UART configuration remains too
large in an earlier pre-router build: its last placement estimate was
63,456/8,640 slices. That estimate does not describe the current routed RTL.
These are tool estimates, not measured silicon limits. The earlier fixed demo
did not prove that all 16 PEs fit.

## Parameter and boundary behavior

`eap_dynamic_pe` requires `N >= 2`, `0 <= PE_ID < N`, and `FANIN >= 1`.
Weight width is configurable with `2 <= WEIGHT_W <= 8`; idle-age width is
configurable with `1 <= IDLE_W <= 8`. The Rev 0.2 defaults are 8 bits for both.
Weights saturate symmetrically at `+/- (2^(WEIGHT_W-1)-1)`. Initial weight
defaults scale with signed full scale: +8 at 8 bits, +4 at 7 bits, +2 at
6 bits, and +1 at 2–5 bits. This keeps the default nonzero and approximately
preserves the +8/128 ratio; `INITIAL_WEIGHT` and `FIXED_WEIGHT` remain
overridable.
At `WEIGHT_W=3..5`, the +1 default is below the default `MIN_WEIGHT=+2`, so an
unused connection can be pruned after its idle age reaches `PRUNE_AGE`.
The default prune age is 200 ticks at `IDLE_W=8`, or the maximum representable
age for narrower idle counters.

The default EAP-16 target uses `N=16`, `FANIN=16`; the board and UART command
top can be configured for `2 <= N <= 16`. UART IDs are 4-bit decimal values
and commands with IDs outside the selected `N` are rejected. Connection counts
remain packed as 5 bits per PE for the `FANIN=16` target. The parameter-boundary
simulation checks `N=2`, `FANIN=1`, with 4-bit weights and idle age.

The shared router requires `FIFO_DEPTH >= 2` and defaults to 64 event IDs.
It arbitrates round-robin among the external event input and each PE's queued
feedback spikes, and writes at most one event per cycle. A full FIFO can accept
a new event on the same cycle that its head is consumed. The producer must hold
an external event stable until `event_ready` is asserted. Each PE's feedback
spikes are staged in a counter that can hold up to `FIFO_DEPTH` events; a
further spike from a full counter latches `event_overflow` until reset. This
fault is visible at the board LEDs and means that specific incoming spike
could not be retained.

Candidate and postsynaptic traces saturate at 255. Idle age saturates at
`2^IDLE_W-1`; weights saturate symmetrically at
`+/- (2^(WEIGHT_W-1)-1)`. With the Rev 0.2 defaults, the weight range is
[-127, +127] (the INT8 value -128 is not used). A zero formation threshold
makes every non-self source eligible on a postsynaptic spike; `PRUNE_AGE=0`
makes a weak connection eligible on the first maintenance tick. An event for a
synapse on the same tick refreshes its age and prevents that synapse from
being pruned.

The membrane is signed 24-bit. Because valid source IDs are unique per PE, an
event selects at most one synaptic weight; the leak term keeps the membrane
update within the signed 24-bit range, including at the representable limits.
Reset is synchronous and clears all learning and membrane state. The spike
output is a one-cycle pulse, and a spike resets the membrane to zero.
With `learning_enable=0`, candidate/post traces and all synapse formation,
weight, idle-age, and pruning updates are frozen; LIF integration, event
routing, and spike generation continue. The Tang Nano top ties this control
high. The comparison testbench lowers it only during held-out evaluation.

## Implementation checklist

### Implemented and simulation-tested

- [x] Integer LIF integration with a signed 24-bit membrane and one-cycle spike.
- [x] Up to 16 logical incoming synapse slots per PE, with valid, source,
  signed weight, and idle-age state.
- [x] Per-source candidate traces and a postsynaptic trace, including
  saturation and maintenance-tick decay.
- [x] Self-connection exclusion by `PE_ID`; source ID zero remains valid.
- [x] Unique-source connection formation from active traces and a post spike;
  lowest-ID pending source is allocated at most once per cycle.
- [x] Configurable `PE_COUNT`, `WEIGHT_W`, and `IDLE_W`, with Rev 0.2 defaults
  of 16 PEs, 8-bit weights, and 8-bit idle ages.
- [x] Pair-based STDP-inspired potentiation/depression, explicit simultaneous
  update priority, weight saturation, and weak-idle pruning.
- [x] `learning_enable` freeze control for traces and plastic synapse state,
  while LIF dynamics and event routing continue.
- [x] Shared event FIFO and round-robin arbiter for external and internal
  events, with valid/ready backpressure on external input.
- [x] Per-source spike staging preserves repeated and simultaneous feedback
  events; pending-counter saturation raises a sticky overflow fault.
- [x] UART RX/TX with ASCII `EVENT`, `TEACH`, `TICK`, `READ`, and `HELP`
  commands. `READ` returns connection count and current spike status.
- [x] Icarus tests for reset, parameter boundaries, LIF, learning, router
  ordering/backpressure/overflow, closed-loop feedback, and UART behavior.

### Verified on the Tang Nano 9K

- [x] `PE_COUNT=2`, `WEIGHT_W=4`, `IDLE_W=4` placed at 1,716/8,640 slices,
  passed the 13.5 MHz timing constraint, and was programmed over JTAG before
  the shared router and width-scaled initial-weight default were added; this
  is not validation of the current RTL.
- [ ] Default `PE_COUNT=16`, 8/8-bit UART image: last placement estimate
  63,456/8,640 slices; it does not fit the GW1NR-9C.

### Not implemented

- [ ] Guaranteed lossless operation under unbounded sustained feedback load;
  finite pending counters report overflow rather than silently accepting it.
- [ ] UART readback of per-slot source IDs and weights.
- [ ] Teacher-free task learning, application-scale accuracy, retention, or
  power benchmarks.
- [ ] Refractory behavior, reward modulation, homeostasis, and consolidation.

## Per-PE state

Each PE contains:
- LIF membrane potential.
- Up to 16 synapse entries: valid, source ID, signed weight, idle age.
- 16 candidate pre-traces (one for each possible source).
- One postsynaptic trace.
- A pending-candidate bitmap.
- Spike output and a connection count.

A default synapse entry is conceptually 21 bits (valid + 4-bit source + 8-bit
weight + 8-bit idle age), often padded to 24 bits for implementation. Width
experiments use `1 + 4 + WEIGHT_W + IDLE_W` bits per slot.

Approximate storage:
- Synapse slots: 16 × 16 × 3 bytes = 768 bytes.
- Candidate traces: 16 × 16 bytes = 256 bytes.
- Post traces: 16 bytes.
- Membranes: 16 × 3 bytes = 48 bytes.
- Pending bitmaps: 32 bytes.
- Event FIFO: 64 × 4-bit IDs = 32 bytes for the default 16-PE target.
- Per-source feedback counters: 16 × 7 bits = 14 bytes at the default depth.
- Total: roughly 1.15 KB plus router and control overhead.

These are architecture estimates, not synthesis reports.

## Learning behavior (prototype policy)

1. A presynaptic event increments that source's candidate trace.
2. Candidate traces decay on maintenance ticks, independently of incoming
   event traffic.
3. A postsynaptic spike increments the post trace and marks sufficiently
   active, not-yet-connected sources as pending.
4. The allocator adds the lowest-ID pending source, at most one per cycle, if a
   slot is free.
5. New connections start at the configured initial weight (+8 at the default
   8-bit width; +1 at 4 bits).
6. Existing connections receive a basic pair-based STDP-inspired update:
   - pre-event following recent post activity: depression;
   - post-spike following recent pre activity: potentiation.
7. Weak connections are pruned only after an inactivity timeout, reducing
   unnecessary connection churn.

This is a simplified engineering rule, not a claim of biological fidelity.
Trace eligibility uses the pre-update trace values from that clock edge. If
potentiation and depression are both eligible for the same synapse on a
simultaneous event/spike, potentiation has priority; at +127 it holds rather
than falling back to depression. Candidate/post trace increments take
priority over maintenance decay on the corresponding event/spike. Valid source
IDs are unique within each PE's synapse table.

## LIF update

The intended integer update is:

`V_next = V - (V >>> 4) + synaptic_current`

A spike occurs when `V_next >= THRESHOLD`, or when a teacher spike is injected.
The RTL resets membrane to zero on a spike. A refractory period and richer
neuron dynamics are future work.

## Important limitations / open design questions

- The event router is finite. External events are backpressured, but sustained
  internal feedback can fill a per-source pending counter; `event_overflow`
  then latches and the arriving spike is explicitly not retained.
- The round-robin arbiter serializes simultaneous spike requests, so their
  delivery order is deterministic but not the same as a global timestamp order.
- Teacher spikes are a test/teaching aid, not the final autonomous learning path.
- Pair-based STDP is simplified; reward modulation, homeostasis, anti-forgetting,
  and consolidation are not implemented.
- Candidate traces scale as O(N²); hierarchical routing and sparse candidate
  tracking will be needed at larger sizes.
- The programmed Tang Nano 9K image is the two-PE 4/4-bit experiment; the
  default 16-PE UART top still does not fit.

## Test and benchmark plan

- [x] Simulate reset, parameter boundaries, self-connection exclusion,
  ID-zero connections, multi-source formation/allocation, potentiation,
  depression, simultaneous pre/post priority, saturation, pruning, and LIF
  integration/threshold behavior.
- [x] Simulate UART event/teacher/tick commands and count/spike readback.
- [x] Build and load the two-PE UART image on the Tang Nano 9K.
- [ ] Place the default 16-PE UART design on the target FPGA.
- [x] Measure connection formation and held-out classification on a seeded
  synthetic task; this does not establish application-scale accuracy.
- [ ] Evaluate novel/changing class-feature mappings and learning stability.
- [ ] Test catastrophic forgetting: train A/B, then C; evaluate A/B retention.
- [x] Test closed-loop FIFO/arbiter ordering, external backpressure, simultaneous
  spikes, and explicit overflow behavior.
- [x] Compare an integer software reference, fixed-topology RTL, and adaptive
  EAP-16 RTL on the same generated event workload.

### Held-out classification and synthesis comparison

Run `make benchmark` for eight seeded trials. Each trial uses four labeled
training patterns and eight held-out feature-pair patterns, balanced across
two classes. Class 0 maps input sources 0–3 to PE 14 and class 1 maps sources
4–7 to PE 15. Held-out patterns include an opposite-class confuser and up to
three unconnected distractors. Classification uses the larger output-neuron
spike count; ties are incorrect. `learning_enable` is high during training and
low for evaluation. The threshold is overridden to 100 for this short
simulation; the EAP-16 default remains 1000.

For seeds 1–8, the software fixed-topology reference, fixed-topology RTL, and
adaptive EAP-16 each classify 64/64 held-out patterns (100%; 32/32 per class).
The software reference matches the fixed RTL cycle-by-cycle. EAP-16 learns the
eight expected feature-to-class edges from the four teacher-labeled patterns.

The fixed baseline starts with the correct stable topology. EAP-16 therefore
demonstrates learning but has no task-score advantage in this experiment.
Yosys 0.52 `synth_gowin` maps the fixed network to 1,408 LUT1–4, 474 MUX2_LUT,
1,200 ALU, 543 FF, 4 RAM primitives, and 3,753 mapped cells. The adaptive
network maps to 36,571 LUT1–4, 4,595 MUX2_LUT, 20,489 ALU, 8,351 FF, 4 RAM
primitives, and 70,135 mapped cells. That is about 25.97× the LUT1–4 count
and 15.38× the FF count (2,497% and 1,438% more, respectively). These are
mapped primitive counts, not placed area or timing results; power and energy
are not measured. The adaptive synthesis top keeps `learning_enable` dynamic,
while the board wrapper ties it high, allowing the freeze logic to be optimized
away in that integration. This synthetic task does not establish
application-scale accuracy, generalization, or value on unknown/changing
topologies.

The per-pattern scores, per-trial accuracy, cycle traces, and synthesis
summary are emitted under `build/`. Placement, timing, power, energy,
throughput, retention, and broader learning-quality comparisons remain future
measurements.
