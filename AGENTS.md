# AGENTS.md — EAP-16 development rules

## Project goal
Develop EAP (Experience-Adaptive Processor), a digital neuromorphic prototype
with online learning and dynamically created/pruned logical synaptic
connections. The current target is EAP-16, revision 0.2.

## Non-negotiable design constraints
- Integer arithmetic only in the initial prototype.
- Synaptic weights are signed 8-bit values, saturated to [-127, +127].
- Membrane state is signed 24-bit.
- Event source and neuron IDs are 4-bit for the 16-neuron prototype.
- Do not reserve neuron ID zero. Self-connections are excluded by comparing
  source ID against the PE's `PE_ID` parameter.
- Connectivity is logical and stored in registers/BRAM. Do not claim that the
  FPGA fabric physically rewires itself.
- Keep learning state local to each PE where practical.
- Make all overflow, saturation, reset and simultaneous-event behavior explicit.

## Engineering rules
1. Preserve synthesizability. Avoid dynamic allocation, unsized arithmetic,
   simulation-only constructs in synthesizable RTL, and accidental latches.
2. Use explicit widths and signedness for arithmetic.
3. Add tests for every behavior change.
4. Run lint and simulation before describing RTL as verified.
5. Never invent synthesis, timing, area, power, or benchmark results.
6. Document parameter constraints and behavior at boundary values.
7. For simultaneous events, define deterministic priority or explicitly
   combine deltas; do not rely on nonblocking assignment ordering by accident.
8. Use explicit `event_ready`/backpressure for external event sources.
9. Internal spikes must be queued; do not silently drop events.
10. Keep a clear distinction between implemented behavior and planned behavior.

## Current architecture
- 16 PEs, each with up to 16 incoming synapse slots.
- AER-like source-ID event interface.
- LIF membrane integration and spike output.
- Candidate pre-traces and a postsynaptic trace.
- Basic pair-based STDP-inspired weight adjustment.
- Connection formation after repeated co-activity.
- Weak-and-idle pruning.
- A shared 64-entry event FIFO and round-robin arbiter for closed-loop
  operation, with external backpressure and sticky feedback overflow status.

## Required validation before merge
- Compile/lint with at least one SystemVerilog tool.
- Reset and parameter-boundary tests.
- Formation, potentiation, depression, saturation and pruning tests.
- Simultaneous event/post-spike tests.
- No self-connections and ID-zero correctness tests.
- Closed-loop event FIFO ordering, overflow, and backpressure tests.
- Learning-disable tests showing plastic state freezes while LIF and routing
  continue.
- Common-workload software/fixed-topology/EAP-16 simulation comparison after
  changing the benchmarked neuron or routing behavior.
- Record tool versions and commands in the commit or test report.
