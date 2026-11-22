# EAP-16 — Experience-Adaptive Processor

EAP-16 is an integer-only, event-driven spiking-network RTL prototype. Its
synaptic graph is stored in mutable registers; the FPGA fabric does not
physically reconfigure itself during learning.

## Run the tests

Install Icarus Verilog (`iverilog` and `vvp`) and GNU Make, then run:

```sh
make test
```

The self-checking tests cover reset, the minimum legal PE parameters
(`N=2`, `FANIN=1`), self-connection exclusion, source ID zero, connection
formation and queued allocation, potentiation, depression, simultaneous
pre/post priority, signed weight saturation, pruning, LIF integration and
threshold behavior, and the Tang Nano 9K demonstration sequence.

## Build and program the Tang Nano 9K

The open-source FPGA flow needs Yosys with `synth_gowin`, `nextpnr-gowin`,
`gowin_pack`, and `openFPGALoader`:

```sh
make bitstream
make program
```

`make bitstream` writes `build/eap16_tangnano9k.fs`. `make program` loads that
bitstream into the FPGA over JTAG; it is volatile and must be loaded again
after power is removed. The programmer must be able to access the board's USB
JTAG interface. Close the serial terminal before programming the board.

The 27 MHz board clock is divided by two for the EAP core (13.5 MHz), below
the routed design's timing limit. The UART uses 115200 baud, 8 data bits, no
parity, and one stop bit (8N1). Connect to the Tang Nano 9K's USB serial port,
then send one command at a time and wait for its response:

```text
EVENT 03
EVENT 03
... repeat until eight EVENT commands have been acknowledged ...
TEACH 07
READ 07
```

`EVENT nn` injects one source event, `TEACH nn` injects a teacher spike at a
PE, `TICK` advances maintenance by one cycle, `READ nn` reports that PE's
connection count and valid synapse slots, and `HELP` lists the commands.
IDs are decimal from 00 through 15. `READ` reports each valid slot's source,
weight, and idle age; weight and idle-age bytes are shown in hexadecimal, with
weights in signed 8-bit two's-complement form. For example, `W 08` is +8 and
`W F9` is -7.

The eight source-3 events followed by `TEACH 07` form connection 3 -> 7 with
initial weight +8. A later teacher spike can potentiate it while its candidate
trace remains active. A `TICK` decays traces and ages connections. The host
should wait for each text reply before sending another command; an overlapping
command is discarded and reported as `ERR BUSY`.

- LED 0 blinks as a heartbeat.
- LED 1 turns on when the most recently selected PE has at least one incoming
  connection.
- LEDs 5:2 show the low four bits of that PE's connection count.
- LEDs are active-low.

The board uses UART TX on pin 17 and RX on pin 18, plus its 27 MHz oscillator,
active-low reset, and six LEDs. Pin assignments are in
[`constraints/tangnano9k.cst`](constraints/tangnano9k.cst).

## Project layout

- [`rtl/eap_dynamic_pe.sv`](rtl/eap_dynamic_pe.sv) — LIF state, synapses,
  candidate traces, learning, formation, and pruning for one PE.
- [`rtl/eap16_top.sv`](rtl/eap16_top.sv) — open-loop 16-PE integration shell.
- [`rtl/eap16_tangnano9k_top.sv`](rtl/eap16_tangnano9k_top.sv) — board
  smoke-test stimulus and LED status.
- [`tb/`](tb) — self-checking SystemVerilog testbenches.
- [`docs/DESIGN.md`](docs/DESIGN.md) — architecture and limitations.

## Current limitations

The UART provides command-level event input and synapse readback, but the
network remains open-loop: there is no shared event FIFO or spike-feedback
router, and `event_ready` is currently always asserted. Teacher spikes are
still a training aid. Simulation passing does not establish convergence,
resource utilization, timing, power, or application accuracy; those need
separate measurements.

## Validation report

Validated in this workspace:

- The PE, parameter-boundary, UART command/readback, and board tests pass with
  Icarus Verilog 12.0-2+b1.
- The previous non-UART image was built with Yosys 0.52-2, nextpnr-gowin
  0.7-1+b2, and Apycula 0.17+dfsg1-1, and loaded to the attached GW1N(R)-9C
  using openFPGALoader 0.13.1-1. Rebuild and reprogram after UART integration.
