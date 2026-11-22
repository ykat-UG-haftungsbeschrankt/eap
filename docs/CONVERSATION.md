# Conversation record — current EAP design discussion

This is a concise reconstruction of the design discussion available at the time
this archive was requested. It is not a verbatim export of every chat message.

## Motivation
The discussion began with AI hardware: Tensor Cores, matrix multiplication,
and whether useful AI computation could move beyond conventional dense matrix
operations. The user then compared pretrained/frozen models with students who
learn and subsequently work, prompting discussion of continual learning.

## Proposed processor direction
The proposed architecture was a memory-centric, heterogeneous AI processor
with inference, adaptive learning, associative/episodic memory and control.
Adaptive computational units (ACUs) were discussed as small programmable
processing elements with locally modifiable parameters. FPGA was considered
for prototyping, CGRA as a potentially efficient architecture, and neuromorphic
event-driven hardware as the chosen direction.

## User-selected direction
The user selected:
- neuromorphic architecture;
- online learning;
- integer arithmetic;
- self-organizing hardware.

## EAP-16 rev 0.1
The first prototype proposal used:
- 16 digital spiking neurons;
- LIF neuron dynamics;
- AER event routing;
- INT8 synaptic weights;
- INT24 membrane potential;
- 8-bit traces;
- pair-based STDP;
- local memory and FPGA implementation.

## EAP-16 rev 0.2
The design was revised to allow the logical synaptic graph to self-organize:
- each PE has up to 16 incoming synapse slots;
- each slot stores valid, source ID, weight and idle age;
- candidate pre-traces track repeated activity from possible sources;
- a post-spike can mark sufficiently active sources as pending;
- an allocator creates connections from pending candidates;
- weak, inactive connections can be pruned.

Clarification: this is dynamic graph connectivity stored in memory. The FPGA
fabric itself is not physically rewired.

## RTL caveats identified in discussion
Three corrections were highlighted:
1. Parameterize each PE with `PE_ID` and exclude self-connections by comparing
   source IDs to `PE_ID`; do not reserve neuron ID zero.
2. Decay candidate traces for all non-event sources on maintenance ticks,
   even when events continue arriving.
3. Decay the post trace independently of membrane integration and event traffic.

Other caveats:
- simultaneous pre/post update priority needs explicit definition;
- event FIFO/arbiter is required for closed-loop operation;
- event backpressure and overflow handling are not yet implemented;
- teacher spikes are only a test aid;
- reward modulation, anti-forgetting and consolidation remain future work;
- RTL is a starting point, not a verified FPGA bitstream.

## Validation plan
Use Verilator and Cocotb (or an equivalent simulator) for:
- connection formation;
- potentiation/depression;
- saturation;
- pruning;
- self-organization across patterns;
- catastrophic-forgetting/retention tests;
- closed-loop event handling.

Then synthesize to FPGA and measure resource use, clock rate, power,
events/s, cycles/event, energy/event and learning performance.

## Next milestone
Demonstrate that a useful connection structure can emerge from experience
without the target graph being manually specified in advance.
