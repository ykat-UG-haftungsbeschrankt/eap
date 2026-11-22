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
                 External AER events / teacher signals
                               |
                               v
                    +----------------------+
                    | Event FIFO + Arbiter |  (planned integration block)
                    +----------+-----------+
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
                     feedback into event FIFO
                         (planned; not yet
                          in the top-level shell)
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
| Event FIFO | 64 entries proposed |
| Clock target | 50–100 MHz proposed, not measured |
| Arithmetic | integer add/subtract, shifts, compares |

The current Tang Nano 9K implementation uses a 13.5 MHz EAP clock derived
from the board's 27 MHz oscillator; this is the configured timing target for
the current RTL, not a measured maximum-frequency result. UART RX/TX uses the
same EAP clock at 115200 baud.

## Parameter and boundary behavior

`eap_dynamic_pe` requires `N >= 2`, `0 <= PE_ID < N`, and `FANIN >= 1`.
The EAP-16 integration and board targets use `N=16`, `FANIN=16`; the fixed
4-bit source port and 5-bit packed connection counts are specific to that
configuration. The parameter-boundary simulation also checks the smallest
valid PE configuration, `N=2`, `FANIN=1`.

Candidate and postsynaptic traces saturate at 255, idle age saturates at 255,
and weights saturate at [-127, +127] (the value -128 is not used). A zero
formation threshold makes every non-self source eligible on a postsynaptic
spike; `PRUNE_AGE=0` makes a weak connection eligible on the first maintenance
tick. An event for a synapse on the same tick refreshes its age and prevents
that synapse from being pruned.

The membrane is signed 24-bit. With `FANIN <= 16` and bounded weights, the
maximum synaptic-current magnitude is 2032; the leak term keeps the membrane
update within the signed 24-bit range, including at the representable limits.
Reset is synchronous and clears all learning and membrane state. The spike
output is a one-cycle pulse, and a spike resets the membrane to zero.

## Per-PE state

Each PE contains:
- LIF membrane potential.
- Up to 16 synapse entries: valid, source ID, signed weight, idle age.
- 16 candidate pre-traces (one for each possible source).
- One postsynaptic trace.
- A pending-candidate bitmap.
- Spike output and a connection count.

A synapse entry is conceptually 21 bits (valid + 4-bit source + 8-bit
weight + 8-bit idle age), often padded to 24 bits for implementation.

Approximate storage:
- Synapse slots: 16 × 16 × 3 bytes = 768 bytes.
- Candidate traces: 16 × 16 bytes = 256 bytes.
- Post traces: 16 bytes.
- Membranes: 16 × 3 bytes = 48 bytes.
- Pending bitmaps: 32 bytes.
- Event FIFO: approximately 128–256 bytes depending on metadata.
- Total: roughly 1.2–1.5 KB plus control overhead.

These are architecture estimates, not synthesis reports.

## Learning behavior (prototype policy)

1. A presynaptic event increments that source's candidate trace.
2. Candidate traces decay on maintenance ticks, independently of incoming
   event traffic.
3. A postsynaptic spike increments the post trace and marks sufficiently
   active, not-yet-connected sources as pending.
4. The allocator adds the lowest-ID pending source, at most one per cycle, if a
   slot is free.
5. New connections start at weight +8.
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
priority over maintenance decay on the corresponding event/spike.

## LIF update

The intended integer update is:

`V_next = V - (V >>> 4) + synaptic_current`

A spike occurs when `V_next >= THRESHOLD`, or when a teacher spike is injected.
The RTL resets membrane to zero on a spike. A refractory period and richer
neuron dynamics are future work.

## Important limitations / open design questions

- The top-level is currently an open-loop shell: external events enter the PEs
  and spikes are exposed as a vector. A shared FIFO/arbiter is still needed to
  feed spikes back into the network without loss.
- The simple event interface accepts at most one event per PE per cycle and
  has no ready/backpressure signal.
- Teacher spikes are a test/teaching aid, not the final autonomous learning path.
- Pair-based STDP is simplified; reward modulation, homeostasis, anti-forgetting,
  and consolidation are not implemented.
- Candidate traces scale as O(N²); hierarchical routing and sparse candidate
  tracking will be needed at larger sizes.
- A 16-neuron prototype does not establish that useful structures will emerge
  autonomously. That is the central experimental hypothesis to test.

## Test and benchmark plan

The current self-checking simulation tests reset, the minimum legal PE
parameters, self-connection exclusion, ID-zero connections, multi-source
formation/allocation, potentiation, depression, simultaneous pre/post priority,
signed weight saturation, weak-and-idle pruning, and LIF integration/threshold
behavior. The Tang Nano 9K top accepts UART commands for events, teacher
spikes, maintenance ticks, and connection-table readback.

Remaining experiments:
1. Train several patterns and measure connection creation, weight distribution,
   recognition accuracy and stability.
2. Test catastrophic forgetting: train A/B, then C; evaluate A/B retention.
3. Add closed-loop FIFO/arbiter and test no-loss behavior under simultaneous spikes.
4. Compare software SNN, fixed-topology SNN and EAP-16.

Measure LUT, FF, BRAM, maximum clock, power, events/s, cycles/event,
energy/event, learning convergence, retention and classification accuracy.
These measurements are not yet included; simulation and the board smoke test
do not establish them.
