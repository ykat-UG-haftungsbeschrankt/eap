#!/usr/bin/env python3
# Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
#
# Permission for non-commercial use is hereby granted,
# free of charge, without warranty of any kind.

"""Run seeded held-out classification trials and compare Gowin-mapped RTL."""

from __future__ import annotations

import argparse
import csv
import json
import random
import subprocess
import sys
from collections import deque
from dataclasses import dataclass
from pathlib import Path
from statistics import mean, pstdev


N = 16
FIFO_DEPTH = 64
THRESHOLD = 100
FIXED_WEIGHT = 8
CLASS_TARGETS = (14, 15)
CLASS_FEATURES = {
    0: (0, 1, 2, 3),
    1: (4, 5, 6, 7),
}
TRAINING_PAIRS = {
    0: ((0, 1), (2, 3)),
    1: ((4, 5), (6, 7)),
}
TRACE_REPETITIONS = 8
EVALUATION_REPETITIONS = 16
TRAINING_GAP = 12
EVALUATION_GAP = 24
EVALUATION_TAIL = 2
NOISE_SOURCES = tuple(range(8, 14))
MAX_ACTIONS = 1024
MAX_SIMULATION_CYCLES = 4096
SCORE_PE_MASK = tuple(1 << target for target in CLASS_TARGETS)
FIXED_TOPOLOGY_MASK = sum(
    1 << (target * N + source)
    for label, target in enumerate(CLASS_TARGETS)
    for source in CLASS_FEATURES[label]
)
EXPECTED_EDGES = {
    (target, source)
    for label, target in enumerate(CLASS_TARGETS)
    for source in CLASS_FEATURES[label]
}

TRACE_FIELDS = (
    "trial",
    "seed",
    "cycle",
    "software_action",
    "software_event_valid",
    "software_event_source",
    "software_event_ready",
    "software_event_accepted",
    "software_spikes",
    "software_overflow",
    "fixed_action",
    "fixed_evaluation",
    "fixed_pattern",
    "fixed_label",
    "fixed_event_valid",
    "fixed_event_source",
    "fixed_event_ready",
    "fixed_event_accepted",
    "fixed_spikes",
    "fixed_class0_connections",
    "fixed_class1_connections",
    "fixed_overflow",
    "adaptive_action",
    "adaptive_evaluation",
    "adaptive_pattern",
    "adaptive_label",
    "adaptive_event_valid",
    "adaptive_event_source",
    "adaptive_event_ready",
    "adaptive_event_accepted",
    "adaptive_spikes",
    "adaptive_class0_connections",
    "adaptive_class1_connections",
    "adaptive_overflow",
)

RESULT_FIELDS = (
    "trial",
    "seed",
    "pattern",
    "label",
    "core_features",
    "confuser_source",
    "noise_sources",
    "software_class0_spikes",
    "software_class1_spikes",
    "software_prediction",
    "software_correct",
    "fixed_rtl_class0_spikes",
    "fixed_rtl_class1_spikes",
    "fixed_rtl_prediction",
    "fixed_rtl_correct",
    "eap16_class0_spikes",
    "eap16_class1_spikes",
    "eap16_prediction",
    "eap16_correct",
)

TRIAL_FIELDS = (
    "trial",
    "seed",
    "patterns",
    "software_correct",
    "software_accuracy",
    "fixed_rtl_correct",
    "fixed_rtl_accuracy",
    "eap16_correct",
    "eap16_accuracy",
    "software_class0_accuracy",
    "software_class1_accuracy",
    "fixed_rtl_class0_accuracy",
    "fixed_rtl_class1_accuracy",
    "eap16_class0_accuracy",
    "eap16_class1_accuracy",
)

SYNTHESIS_FIELDS = (
    "model",
    "mapped_cells",
    "lut1_to_lut4",
    "mux2_lut",
    "alu",
    "flip_flops",
    "ram_primitives",
)


@dataclass(frozen=True)
class Stimulus:
    event_valid: bool = False
    event_source: int = 0
    teacher_mask: int = 0
    maintenance_tick: bool = False
    evaluation: bool = False
    pattern_id: int = 0
    label: int = 0


@dataclass(frozen=True)
class EvaluationPattern:
    pattern_id: int
    label: int
    core_features: tuple[int, int]
    confuser_source: int
    noise_sources: tuple[int, ...]


@dataclass(frozen=True)
class ReferenceCycle:
    action_index: int
    stimulus: Stimulus
    event_ready: bool
    event_accepted: bool
    spikes: int
    overflow: bool


@dataclass(frozen=True)
class LaneCycle:
    action_index: int
    evaluation: bool
    pattern_id: int
    label: int
    event_valid: bool
    event_source: int
    event_ready: bool
    event_accepted: bool
    spikes: int
    class0_connections: int
    class1_connections: int
    overflow: bool


@dataclass(frozen=True)
class RtlCycle:
    cycle: int
    fixed: LaneCycle
    adaptive: LaneCycle


@dataclass(frozen=True)
class ClassificationScore:
    spikes: tuple[int, int]
    prediction: int | None
    correct: bool


@dataclass(frozen=True)
class TrialResult:
    trial: int
    seed: int
    patterns: tuple[EvaluationPattern, ...]
    software_scores: dict[int, ClassificationScore]
    fixed_scores: dict[int, ClassificationScore]
    adaptive_scores: dict[int, ClassificationScore]
    reference_cycles: tuple[ReferenceCycle, ...]
    rtl_cycles: tuple[RtlCycle, ...]
    adaptive_edges: dict[tuple[int, int], int]


@dataclass(frozen=True)
class SynthesisMetrics:
    mapped_cells: int
    lut1_to_lut4: int
    mux2_lut: int
    alu: int
    flip_flops: int
    ram_primitives: int


class FixedTopologyReference:
    """Integer cycle model of the fixed graph and the shared event router."""

    def __init__(self) -> None:
        self.membrane = [0] * N
        self.spikes = 0
        self.event_fifo: deque[int] = deque()
        self.pending_spikes = [0] * N
        self.last_grant = N
        self.overflow = False

    def step(self, stimulus: Stimulus, action_index: int) -> ReferenceCycle:
        routed_valid = bool(self.event_fifo)
        routed_source = self.event_fifo[0] if routed_valid else 0
        fifo_pop = routed_valid
        fifo_can_push = len(self.event_fifo) < FIFO_DEPTH or fifo_pop

        requests = [stimulus.event_valid]
        requests.extend(count != 0 for count in self.pending_spikes)
        grant: int | None = None
        port_count = N + 1
        for offset in range(1, port_count + 1):
            candidate = (self.last_grant + offset) % port_count
            if requests[candidate]:
                grant = candidate
                break

        any_feedback_pending = any(self.pending_spikes)
        event_ready = fifo_can_push and (
            grant == 0 or not any_feedback_pending
        )
        event_accepted = stimulus.event_valid and event_ready
        external_push = (
            stimulus.event_valid and event_ready and grant == 0
        )
        spike_grants = [
            fifo_can_push and grant == source + 1
            for source in range(N)
        ]
        fifo_push = external_push or any(spike_grants)
        if external_push:
            pushed_source = stimulus.event_source
        elif any(spike_grants):
            pushed_source = next(
                source
                for source, granted in enumerate(spike_grants)
                if granted
            )
        else:
            pushed_source = 0

        next_membrane = self.membrane.copy()
        next_spikes = 0
        for pe in range(N):
            connected = any(
                pe == CLASS_TARGETS[label]
                and routed_source in CLASS_FEATURES[label]
                for label in (0, 1)
            )
            synaptic_current = FIXED_WEIGHT if routed_valid and connected else 0
            membrane_next = (
                self.membrane[pe]
                - (self.membrane[pe] >> 4)
                + synaptic_current
            )
            will_spike = bool(stimulus.teacher_mask & (1 << pe)) or (
                routed_valid and membrane_next >= THRESHOLD
            )
            if will_spike:
                next_spikes |= 1 << pe
                next_membrane[pe] = 0
            else:
                next_membrane[pe] = membrane_next

        old_spikes = self.spikes
        if fifo_pop:
            self.event_fifo.popleft()
        if fifo_push:
            self.event_fifo.append(pushed_source)

        for source in range(N):
            incoming_spike = bool(old_spikes & (1 << source))
            granted_spike = spike_grants[source]
            if incoming_spike and not granted_spike:
                if self.pending_spikes[source] == FIFO_DEPTH:
                    self.overflow = True
                else:
                    self.pending_spikes[source] += 1
            elif granted_spike and not incoming_spike:
                if self.pending_spikes[source] == 0:
                    raise AssertionError("arbiter granted an empty counter")
                self.pending_spikes[source] -= 1

        if fifo_push:
            if grant is None:
                raise AssertionError("FIFO push had no arbiter grant")
            self.last_grant = grant

        self.membrane = next_membrane
        self.spikes = next_spikes
        return ReferenceCycle(
            action_index=action_index,
            stimulus=stimulus,
            event_ready=event_ready,
            event_accepted=event_accepted,
            spikes=self.spikes,
            overflow=self.overflow,
        )


def build_workload(seed: int) -> tuple[list[Stimulus], tuple[EvaluationPattern, ...]]:
    rng = random.Random(seed)
    actions: list[Stimulus] = []

    training_examples = [
        (label, pair)
        for label, pairs in TRAINING_PAIRS.items()
        for pair in pairs
    ]
    rng.shuffle(training_examples)
    for label, pair in training_examples:
        events = [source for source in pair for _ in range(TRACE_REPETITIONS)]
        rng.shuffle(events)
        actions.extend(
            Stimulus(event_valid=True, event_source=source)
            for source in events
        )
        actions.append(Stimulus())
        actions.append(Stimulus(teacher_mask=1 << CLASS_TARGETS[label]))
        actions.extend(
            Stimulus(maintenance_tick=True) for _ in range(TRAINING_GAP)
        )

    training_pair_sets = {
        label: {tuple(sorted(pair)) for pair in pairs}
        for label, pairs in TRAINING_PAIRS.items()
    }
    evaluation_examples: list[tuple[int, tuple[int, int]]] = []
    for label, features in CLASS_FEATURES.items():
        for first_index, first in enumerate(features):
            for second in features[first_index + 1 :]:
                pair = (first, second)
                if pair not in training_pair_sets[label]:
                    evaluation_examples.append((label, pair))
    rng.shuffle(evaluation_examples)

    evaluation_patterns: list[EvaluationPattern] = []
    for pattern_id, (label, pair) in enumerate(evaluation_examples):
        opposite_features = CLASS_FEATURES[1 - label]
        confuser = rng.choice(opposite_features)
        confuser_repetitions = rng.randint(1, 3)
        noise_sources = tuple(
            sorted(rng.sample(NOISE_SOURCES, rng.randint(0, 3)))
        )
        event_sources = [
            source for source in pair for _ in range(EVALUATION_REPETITIONS)
        ]
        event_sources.extend([confuser] * confuser_repetitions)
        event_sources.extend(noise_sources)
        rng.shuffle(event_sources)

        evaluation_patterns.append(
            EvaluationPattern(
                pattern_id=pattern_id,
                label=label,
                core_features=pair,
                confuser_source=confuser,
                noise_sources=noise_sources,
            )
        )
        actions.extend(
            Stimulus(
                event_valid=True,
                event_source=source,
                evaluation=True,
                pattern_id=pattern_id,
                label=label,
            )
            for source in event_sources
        )
        actions.extend(
            Stimulus(
                evaluation=True,
                pattern_id=pattern_id,
                label=label,
            )
            for _ in range(EVALUATION_TAIL)
        )
        actions.extend(
            Stimulus(maintenance_tick=True)
            for _ in range(EVALUATION_GAP)
        )

    if len(actions) > MAX_ACTIONS:
        raise RuntimeError(
            f"generated {len(actions)} actions; testbench limit is {MAX_ACTIONS}"
        )
    return actions, tuple(evaluation_patterns)


def encode_stimulus(stimulus: Stimulus) -> int:
    if not 0 <= stimulus.event_source < N:
        raise ValueError(f"source ID outside [0, {N - 1}]")
    if not 0 <= stimulus.teacher_mask < (1 << N):
        raise ValueError("teacher mask does not fit the network")
    if not 0 <= stimulus.pattern_id < 16:
        raise ValueError("pattern ID does not fit the stimulus format")
    if stimulus.label not in (0, 1):
        raise ValueError("class label must be 0 or 1")
    return (
        int(stimulus.maintenance_tick)
        | (int(stimulus.event_valid) << 1)
        | (stimulus.event_source << 2)
        | (stimulus.teacher_mask << 6)
        | (int(stimulus.evaluation) << 22)
        | (stimulus.pattern_id << 23)
        | (stimulus.label << 27)
    )


def write_stimulus(path: Path, actions: list[Stimulus]) -> None:
    with path.open("w", encoding="ascii") as stimulus_file:
        for stimulus in actions:
            stimulus_file.write(f"{encode_stimulus(stimulus):07x}\n")


def parse_lane(fields: list[str], start: int) -> LaneCycle:
    return LaneCycle(
        action_index=int(fields[start]),
        evaluation=bool(int(fields[start + 1])),
        pattern_id=int(fields[start + 2]),
        label=int(fields[start + 3]),
        event_valid=bool(int(fields[start + 4])),
        event_source=int(fields[start + 5]),
        event_ready=bool(int(fields[start + 6])),
        event_accepted=bool(int(fields[start + 7])),
        spikes=int(fields[start + 8], 16),
        class0_connections=int(fields[start + 9]),
        class1_connections=int(fields[start + 10]),
        overflow=bool(int(fields[start + 11])),
    )


def parse_simulation_output(
    output: str,
) -> tuple[tuple[int, int, int, int], list[RtlCycle], dict[tuple[int, int], int]]:
    config: tuple[int, int, int, int] | None = None
    cycles: list[RtlCycle] = []
    adaptive_edges: dict[tuple[int, int], int] = {}
    end_cycle: int | None = None

    for line in output.splitlines():
        if line.startswith("CONFIG,"):
            fields = line.split(",")
            if len(fields) != 5:
                raise RuntimeError(f"malformed CONFIG line: {line}")
            config = (
                int(fields[1]),
                int(fields[2], 16),
                int(fields[3]),
                int(fields[4]),
            )
        elif line.startswith("TRACE,"):
            fields = line.split(",")
            if len(fields) != 26:
                raise RuntimeError(
                    f"malformed TRACE record with {len(fields)} fields: {line}"
                )
            cycles.append(
                RtlCycle(
                    cycle=int(fields[1]),
                    fixed=parse_lane(fields, 2),
                    adaptive=parse_lane(fields, 14),
                )
            )
        elif line.startswith("EDGE,"):
            _, target, source, weight = line.split(",")
            key = (int(target), int(source))
            if key in adaptive_edges:
                raise RuntimeError(f"duplicate learned edge {key}")
            adaptive_edges[key] = int(weight)
        elif line.startswith("END,"):
            end_cycle = int(line.split(",")[1])

    if config is None:
        raise RuntimeError("simulation produced no CONFIG record")
    if end_cycle != len(cycles):
        raise RuntimeError(
            f"simulation END record {end_cycle} does not match "
            f"{len(cycles)} trace cycles"
        )
    return config, cycles, adaptive_edges


def action_or_idle(actions: list[Stimulus], index: int) -> Stimulus:
    if index < len(actions):
        return actions[index]
    return Stimulus()


def build_reference_trace(
    actions: list[Stimulus], cycle_count: int
) -> tuple[ReferenceCycle, ...]:
    reference = FixedTopologyReference()
    action_index = 0
    result: list[ReferenceCycle] = []
    for _ in range(cycle_count):
        stimulus = action_or_idle(actions, action_index)
        cycle = reference.step(stimulus, action_index)
        result.append(cycle)
        if action_index < len(actions) and (
            not stimulus.event_valid or cycle.event_ready
        ):
            action_index += 1
    if action_index != len(actions):
        raise AssertionError(
            f"software reference accepted {action_index}/{len(actions)} actions"
        )
    return tuple(result)


def validate_lane_progress(
    lane_name: str,
    lane_cycles: list[LaneCycle],
    actions: list[Stimulus],
) -> None:
    action_index = 0
    for cycle_number, lane in enumerate(lane_cycles):
        stimulus = action_or_idle(actions, action_index)
        expected = (
            action_index,
            stimulus.evaluation,
            stimulus.pattern_id,
            stimulus.label,
            stimulus.event_valid,
            stimulus.event_source,
        )
        actual = (
            lane.action_index,
            lane.evaluation,
            lane.pattern_id,
            lane.label,
            lane.event_valid,
            lane.event_source,
        )
        if actual != expected:
            raise AssertionError(
                f"{lane_name} stimulus mismatch at cycle {cycle_number}: "
                f"{actual} != {expected}"
            )
        if lane.event_accepted != (lane.event_valid and lane.event_ready):
            raise AssertionError(
                f"{lane_name} reported an invalid event handshake at cycle "
                f"{cycle_number}"
            )
        if action_index < len(actions) and (
            not lane.event_valid or lane.event_ready
        ):
            action_index += 1
    if action_index != len(actions):
        raise AssertionError(
            f"{lane_name} accepted {action_index}/{len(actions)} actions"
        )


def validate_fixed_reference(
    actions: list[Stimulus],
    rtl_cycles: list[RtlCycle],
    reference_cycles: tuple[ReferenceCycle, ...],
) -> None:
    if len(reference_cycles) != len(rtl_cycles):
        raise AssertionError("software reference and RTL cycle counts differ")

    for cycle_index, (actual, expected) in enumerate(
        zip(rtl_cycles, reference_cycles, strict=True)
    ):
        if actual.cycle != cycle_index:
            raise AssertionError(
                f"trace cycle {actual.cycle} appeared at index {cycle_index}"
            )
        lane = actual.fixed
        stimulus = expected.stimulus
        if lane.action_index != expected.action_index:
            raise AssertionError(
                f"fixed RTL action index mismatch at cycle {actual.cycle}"
            )
        if lane.event_valid != stimulus.event_valid:
            raise AssertionError(
                f"fixed RTL valid mismatch at cycle {actual.cycle}"
            )
        if lane.event_source != stimulus.event_source:
            raise AssertionError(
                f"fixed RTL source mismatch at cycle {actual.cycle}"
            )
        if lane.evaluation != stimulus.evaluation:
            raise AssertionError(
                f"fixed RTL evaluation tag mismatch at cycle {actual.cycle}"
            )
        if lane.pattern_id != stimulus.pattern_id or lane.label != stimulus.label:
            raise AssertionError(
                f"fixed RTL pattern tag mismatch at cycle {actual.cycle}"
            )
        if lane.event_ready != expected.event_ready:
            raise AssertionError(
                f"fixed RTL ready mismatch at cycle {actual.cycle}"
            )
        if lane.event_accepted != expected.event_accepted:
            raise AssertionError(
                f"fixed RTL handshake mismatch at cycle {actual.cycle}"
            )
        if lane.spikes != expected.spikes:
            raise AssertionError(
                f"fixed RTL/software spike mismatch at cycle {actual.cycle}: "
                f"{lane.spikes:04x} != {expected.spikes:04x}"
            )
        if lane.overflow != expected.overflow:
            raise AssertionError(
                f"fixed RTL/software overflow mismatch at cycle {actual.cycle}"
            )
        if (
            lane.class0_connections != len(CLASS_FEATURES[0])
            or lane.class1_connections != len(CLASS_FEATURES[1])
        ):
            raise AssertionError("fixed baseline topology changed")

    validate_lane_progress(
        "adaptive EAP-16",
        [cycle.adaptive for cycle in rtl_cycles],
        actions,
    )
    for cycle in rtl_cycles:
        if cycle.fixed.overflow or cycle.adaptive.overflow:
            raise AssertionError(f"unexpected event overflow at cycle {cycle.cycle}")


def classify_spikes(spike_counts: tuple[int, int], label: int) -> ClassificationScore:
    if spike_counts[0] > spike_counts[1]:
        prediction: int | None = 0
    elif spike_counts[1] > spike_counts[0]:
        prediction = 1
    else:
        prediction = None
    return ClassificationScore(
        spikes=spike_counts,
        prediction=prediction,
        correct=prediction == label,
    )


def score_reference(
    patterns: tuple[EvaluationPattern, ...],
    cycles: tuple[ReferenceCycle, ...],
) -> dict[int, ClassificationScore]:
    counts = {pattern.pattern_id: [0, 0] for pattern in patterns}
    labels = {pattern.pattern_id: pattern.label for pattern in patterns}
    for cycle in cycles:
        stimulus = cycle.stimulus
        if stimulus.evaluation:
            if stimulus.pattern_id not in counts:
                raise AssertionError("software trace has an unknown test pattern")
            if stimulus.label != labels[stimulus.pattern_id]:
                raise AssertionError("software trace has a mislabeled pattern")
            for output, bit in enumerate(SCORE_PE_MASK):
                counts[stimulus.pattern_id][output] += int(
                    bool(cycle.spikes & bit)
                )
    return {
        pattern_id: classify_spikes(
            (pattern_counts[0], pattern_counts[1]),
            labels[pattern_id],
        )
        for pattern_id, pattern_counts in counts.items()
    }


def score_rtl_lane(
    patterns: tuple[EvaluationPattern, ...],
    cycles: list[RtlCycle],
    lane_name: str,
) -> dict[int, ClassificationScore]:
    counts = {pattern.pattern_id: [0, 0] for pattern in patterns}
    labels = {pattern.pattern_id: pattern.label for pattern in patterns}
    for cycle in cycles:
        lane = getattr(cycle, lane_name)
        if lane.evaluation:
            if lane.pattern_id not in counts:
                raise AssertionError(f"{lane_name} trace has an unknown pattern")
            if lane.label != labels[lane.pattern_id]:
                raise AssertionError(f"{lane_name} trace has a mislabeled pattern")
            for output, bit in enumerate(SCORE_PE_MASK):
                counts[lane.pattern_id][output] += int(
                    bool(lane.spikes & bit)
                )
    return {
        pattern_id: classify_spikes(
            (pattern_counts[0], pattern_counts[1]),
            labels[pattern_id],
        )
        for pattern_id, pattern_counts in counts.items()
    }


def validate_pattern_scores(
    patterns: tuple[EvaluationPattern, ...],
    software_scores: dict[int, ClassificationScore],
    fixed_scores: dict[int, ClassificationScore],
    adaptive_scores: dict[int, ClassificationScore],
) -> None:
    expected_ids = {pattern.pattern_id for pattern in patterns}
    for name, scores in (
        ("software", software_scores),
        ("fixed RTL", fixed_scores),
        ("adaptive", adaptive_scores),
    ):
        if set(scores) != expected_ids:
            raise AssertionError(
                f"{name} scored {len(scores)}/{len(expected_ids)} held-out patterns"
            )
    if software_scores != fixed_scores:
        raise AssertionError(
            "software reference and fixed RTL classification scores differ"
        )


def run_trial(
    trial: int,
    seed: int,
    sim_path: Path,
    build_dir: Path,
    vvp: str,
) -> TrialResult:
    actions, patterns = build_workload(seed)
    stimulus_path = build_dir / f"snn_classification_seed_{seed}.mem"
    write_stimulus(stimulus_path, actions)

    command = [
        vvp,
        str(sim_path.resolve()),
        f"+STIM={stimulus_path.resolve()}",
        f"+ACTIONS={len(actions)}",
    ]
    try:
        simulation = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=180,
        )
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"trial {trial} (seed {seed}) timed out") from error
    if simulation.returncode != 0:
        sys.stderr.write(simulation.stdout)
        sys.stderr.write(simulation.stderr)
        raise RuntimeError(
            f"trial {trial} (seed {seed}) simulation exited "
            f"{simulation.returncode}"
        )

    config, rtl_cycles, adaptive_edges = parse_simulation_output(
        simulation.stdout
    )
    expected_config = (N, FIXED_TOPOLOGY_MASK, THRESHOLD, FIXED_WEIGHT)
    if config != expected_config:
        raise RuntimeError(
            f"RTL config {config} does not match {expected_config}"
        )
    if len(rtl_cycles) > MAX_SIMULATION_CYCLES:
        raise AssertionError("simulation exceeded its cycle bound")

    validate_lane_progress(
        "fixed topology",
        [cycle.fixed for cycle in rtl_cycles],
        actions,
    )
    reference_cycles = build_reference_trace(actions, len(rtl_cycles))
    validate_fixed_reference(actions, rtl_cycles, reference_cycles)
    first_evaluation_cycle = next(
        cycle
        for cycle in rtl_cycles
        if cycle.fixed.evaluation or cycle.adaptive.evaluation
    )
    if (
        first_evaluation_cycle.adaptive.class0_connections
        != len(CLASS_FEATURES[0])
        or first_evaluation_cycle.adaptive.class1_connections
        != len(CLASS_FEATURES[1])
    ):
        raise AssertionError(
            "EAP-16 did not learn all expected class-feature connections"
        )
    if set(adaptive_edges) != EXPECTED_EDGES:
        raise AssertionError(
            f"EAP-16 learned edges {sorted(adaptive_edges)}; "
            f"expected {sorted(EXPECTED_EDGES)}"
        )
    if any(weight != FIXED_WEIGHT for weight in adaptive_edges.values()):
        raise AssertionError(
            "EAP-16 evaluation changed weights while learning was disabled"
        )

    software_scores = score_reference(patterns, reference_cycles)
    fixed_scores = score_rtl_lane(patterns, rtl_cycles, "fixed")
    adaptive_scores = score_rtl_lane(patterns, rtl_cycles, "adaptive")
    validate_pattern_scores(
        patterns, software_scores, fixed_scores, adaptive_scores
    )
    return TrialResult(
        trial=trial,
        seed=seed,
        patterns=patterns,
        software_scores=software_scores,
        fixed_scores=fixed_scores,
        adaptive_scores=adaptive_scores,
        reference_cycles=reference_cycles,
        rtl_cycles=tuple(rtl_cycles),
        adaptive_edges=adaptive_edges,
    )


def read_synthesis_metrics(path: Path, top: str) -> SynthesisMetrics:
    with path.open("r", encoding="utf-8") as netlist_file:
        netlist = json.load(netlist_file)

    modules = netlist.get("modules")
    if not isinstance(modules, dict):
        raise RuntimeError(
            f"{path} does not contain a synthesized module table"
        )

    module = modules.get(top)
    if module is None:
        top_modules = [
            candidate
            for candidate in modules.values()
            if str(
                candidate.get("attributes", {}).get("top", "")
            ).lstrip("0") == "1"
        ]
        if len(top_modules) != 1:
            raise RuntimeError(
                f"{path} does not contain a unique synthesized top module "
                f"for {top}"
            )
        module = top_modules[0]

    cells = module.get("cells")
    if not isinstance(cells, dict):
        raise RuntimeError(
            f"{path} has no synthesized cells for top module {top}"
        )

    counts: dict[str, int] = {}
    for cell in cells.values():
        cell_type = cell["type"]
        counts[cell_type] = counts.get(cell_type, 0) + 1
    mapped_cells = sum(
        count for cell_type, count in counts.items()
        if cell_type != "$scopeinfo"
    )
    return SynthesisMetrics(
        mapped_cells=mapped_cells,
        lut1_to_lut4=sum(
            count
            for cell_type, count in counts.items()
            if cell_type in {"LUT1", "LUT2", "LUT3", "LUT4"}
        ),
        mux2_lut=sum(
            count
            for cell_type, count in counts.items()
            if cell_type.startswith("MUX2_LUT")
        ),
        alu=counts.get("ALU", 0),
        flip_flops=sum(
            count
            for cell_type, count in counts.items()
            if cell_type.startswith("DFF")
        ),
        ram_primitives=sum(
            count
            for cell_type, count in counts.items()
            if cell_type.startswith(("RAM", "BSRAM"))
        ),
    )


def ratio_delta(adaptive: int, fixed: int) -> str:
    if fixed == 0:
        return "n/a"
    return f"{(adaptive - fixed) * 100.0 / fixed:+.1f}%"


def class_accuracy(
    scores: dict[int, ClassificationScore],
    patterns: tuple[EvaluationPattern, ...],
    label: int,
) -> float:
    ids = [
        pattern.pattern_id
        for pattern in patterns
        if pattern.label == label
    ]
    return sum(scores[pattern_id].correct for pattern_id in ids) / len(ids)


def overall_accuracy(scores: dict[int, ClassificationScore]) -> float:
    if not scores:
        raise ValueError("cannot score an empty pattern set")
    return sum(score.correct for score in scores.values()) / len(scores)


def write_results(
    build_dir: Path, trials: list[TrialResult]
) -> None:
    detailed_path = build_dir / "snn_classification_results.csv"
    with detailed_path.open("w", newline="", encoding="ascii") as result_file:
        writer = csv.DictWriter(result_file, fieldnames=RESULT_FIELDS)
        writer.writeheader()
        for result in trials:
            patterns = {
                pattern.pattern_id: pattern for pattern in result.patterns
            }
            for pattern_id, pattern in patterns.items():
                software = result.software_scores[pattern_id]
                fixed = result.fixed_scores[pattern_id]
                adaptive = result.adaptive_scores[pattern_id]
                writer.writerow(
                    {
                        "trial": result.trial,
                        "seed": result.seed,
                        "pattern": pattern_id,
                        "label": pattern.label,
                        "core_features": " ".join(
                            str(source) for source in pattern.core_features
                        ),
                        "confuser_source": pattern.confuser_source,
                        "noise_sources": " ".join(
                            str(source) for source in pattern.noise_sources
                        ),
                        "software_class0_spikes": software.spikes[0],
                        "software_class1_spikes": software.spikes[1],
                        "software_prediction": (
                            "tie" if software.prediction is None
                            else software.prediction
                        ),
                        "software_correct": int(software.correct),
                        "fixed_rtl_class0_spikes": fixed.spikes[0],
                        "fixed_rtl_class1_spikes": fixed.spikes[1],
                        "fixed_rtl_prediction": (
                            "tie" if fixed.prediction is None else fixed.prediction
                        ),
                        "fixed_rtl_correct": int(fixed.correct),
                        "eap16_class0_spikes": adaptive.spikes[0],
                        "eap16_class1_spikes": adaptive.spikes[1],
                        "eap16_prediction": (
                            "tie" if adaptive.prediction is None
                            else adaptive.prediction
                        ),
                        "eap16_correct": int(adaptive.correct),
                    }
                )

    trial_path = build_dir / "snn_classification_trials.csv"
    with trial_path.open("w", newline="", encoding="ascii") as trial_file:
        writer = csv.DictWriter(trial_file, fieldnames=TRIAL_FIELDS)
        writer.writeheader()
        for result in trials:
            writer.writerow(
                {
                    "trial": result.trial,
                    "seed": result.seed,
                    "patterns": len(result.patterns),
                    "software_correct": sum(
                        score.correct
                        for score in result.software_scores.values()
                    ),
                    "software_accuracy": (
                        f"{overall_accuracy(result.software_scores):.6f}"
                    ),
                    "fixed_rtl_correct": sum(
                        score.correct for score in result.fixed_scores.values()
                    ),
                    "fixed_rtl_accuracy": (
                        f"{overall_accuracy(result.fixed_scores):.6f}"
                    ),
                    "eap16_correct": sum(
                        score.correct
                        for score in result.adaptive_scores.values()
                    ),
                    "eap16_accuracy": (
                        f"{overall_accuracy(result.adaptive_scores):.6f}"
                    ),
                    "software_class0_accuracy": (
                        f"{class_accuracy(result.software_scores, result.patterns, 0):.6f}"
                    ),
                    "software_class1_accuracy": (
                        f"{class_accuracy(result.software_scores, result.patterns, 1):.6f}"
                    ),
                    "fixed_rtl_class0_accuracy": (
                        f"{class_accuracy(result.fixed_scores, result.patterns, 0):.6f}"
                    ),
                    "fixed_rtl_class1_accuracy": (
                        f"{class_accuracy(result.fixed_scores, result.patterns, 1):.6f}"
                    ),
                    "eap16_class0_accuracy": (
                        f"{class_accuracy(result.adaptive_scores, result.patterns, 0):.6f}"
                    ),
                    "eap16_class1_accuracy": (
                        f"{class_accuracy(result.adaptive_scores, result.patterns, 1):.6f}"
                    ),
                }
            )

    trace_path = build_dir / "snn_classification_cycle_trace.csv"
    with trace_path.open("w", newline="", encoding="ascii") as trace_file:
        writer = csv.DictWriter(trace_file, fieldnames=TRACE_FIELDS)
        writer.writeheader()
        for result in trials:
            for reference, actual in zip(
                result.reference_cycles, result.rtl_cycles, strict=True
            ):
                fixed = actual.fixed
                adaptive = actual.adaptive
                writer.writerow(
                    {
                        "trial": result.trial,
                        "seed": result.seed,
                        "cycle": actual.cycle,
                        "software_action": reference.action_index,
                        "software_event_valid": int(
                            reference.stimulus.event_valid
                        ),
                        "software_event_source": (
                            reference.stimulus.event_source
                        ),
                        "software_event_ready": int(reference.event_ready),
                        "software_event_accepted": int(
                            reference.event_accepted
                        ),
                        "software_spikes": f"{reference.spikes:04x}",
                        "software_overflow": int(reference.overflow),
                        "fixed_action": fixed.action_index,
                        "fixed_evaluation": int(fixed.evaluation),
                        "fixed_pattern": fixed.pattern_id,
                        "fixed_label": fixed.label,
                        "fixed_event_valid": int(fixed.event_valid),
                        "fixed_event_source": fixed.event_source,
                        "fixed_event_ready": int(fixed.event_ready),
                        "fixed_event_accepted": int(fixed.event_accepted),
                        "fixed_spikes": f"{fixed.spikes:04x}",
                        "fixed_class0_connections": fixed.class0_connections,
                        "fixed_class1_connections": fixed.class1_connections,
                        "fixed_overflow": int(fixed.overflow),
                        "adaptive_action": adaptive.action_index,
                        "adaptive_evaluation": int(adaptive.evaluation),
                        "adaptive_pattern": adaptive.pattern_id,
                        "adaptive_label": adaptive.label,
                        "adaptive_event_valid": int(adaptive.event_valid),
                        "adaptive_event_source": adaptive.event_source,
                        "adaptive_event_ready": int(adaptive.event_ready),
                        "adaptive_event_accepted": int(adaptive.event_accepted),
                        "adaptive_spikes": f"{adaptive.spikes:04x}",
                        "adaptive_class0_connections": adaptive.class0_connections,
                        "adaptive_class1_connections": adaptive.class1_connections,
                        "adaptive_overflow": int(adaptive.overflow),
                    }
                )


def write_synthesis_summary(
    build_dir: Path,
    fixed: SynthesisMetrics,
    adaptive: SynthesisMetrics,
) -> None:
    path = build_dir / "snn_synthesis_summary.csv"
    with path.open("w", newline="", encoding="ascii") as summary_file:
        writer = csv.DictWriter(summary_file, fieldnames=SYNTHESIS_FIELDS)
        writer.writeheader()
        for model, metrics in (
            ("fixed-topology", fixed),
            ("adaptive-eap16", adaptive),
        ):
            writer.writerow({"model": model, **metrics.__dict__})


def print_results(
    trials: list[TrialResult],
    fixed_synthesis: SynthesisMetrics,
    adaptive_synthesis: SynthesisMetrics,
) -> None:
    total_patterns = sum(len(result.patterns) for result in trials)
    model_scores = {
        "Software fixed": [
            score
            for result in trials
            for score in result.software_scores.values()
        ],
        "Fixed RTL": [
            score
            for result in trials
            for score in result.fixed_scores.values()
        ],
        "Adaptive EAP-16": [
            score
            for result in trials
            for score in result.adaptive_scores.values()
        ],
    }
    print(
        f"Task: binary event-pattern classification; {len(trials)} seeded "
        f"trials x {len(trials[0].patterns)} held-out patterns "
        f"({total_patterns} total)."
    )
    print(
        "Training: 4 labeled feature-pair patterns per trial; evaluation uses "
        "the other within-class feature pairs, an opposite-class confuser, "
        "and 0-3 unconnected distractors."
    )
    print(
        "Plasticity is enabled during training and frozen during evaluation."
    )
    print("Classifier: larger spike count at PE 14/15 wins; ties count as wrong.")
    print("Scores (each trial is balanced: 4 examples per class):")
    print("  Model                 Correct   Accuracy   Mean/trial +/- population SD")
    for name, scores in model_scores.items():
        correct = sum(score.correct for score in scores)
        trial_accuracies = [
            overall_accuracy(
                result.software_scores
                if name == "Software fixed"
                else result.fixed_scores
                if name == "Fixed RTL"
                else result.adaptive_scores
            )
            for result in trials
        ]
        print(
            f"  {name:<21} {correct:>3}/{total_patterns:<3} "
            f"{100 * correct / total_patterns:>7.2f}% "
            f"{100 * mean(trial_accuracies):>7.2f}% +/- "
            f"{100 * pstdev(trial_accuracies):.2f}%"
        )
    print("  Per-trial accuracy:")
    print("    trial  seed  software  fixed-RTL  EAP-16")
    for result in trials:
        print(
            f"    {result.trial:>5}  {result.seed:>4}  "
            f"{100 * overall_accuracy(result.software_scores):>7.2f}%  "
            f"{100 * overall_accuracy(result.fixed_scores):>9.2f}%  "
            f"{100 * overall_accuracy(result.adaptive_scores):>6.2f}%"
        )

    print(
        "Gowin-mapped network primitive counts (Yosys synth_gowin; "
        "not placed or timing-closed):"
    )
    print(
        "The adaptive netlist keeps learning_enable as a runtime input; the "
        "board wrapper ties it high."
    )
    print("  Model              LUT1-4  MUX2_LUT  ALU  FFs   RAM  Mapped cells")
    for name, metrics in (
        ("Fixed topology", fixed_synthesis),
        ("Adaptive EAP-16", adaptive_synthesis),
    ):
        print(
            f"  {name:<18} {metrics.lut1_to_lut4:>6} "
            f"{metrics.mux2_lut:>9} {metrics.alu:>4} "
            f"{metrics.flip_flops:>5} {metrics.ram_primitives:>5} "
            f"{metrics.mapped_cells:>13}"
        )
    print(
        "  Adaptive overhead: "
        f"LUT1-4 {ratio_delta(adaptive_synthesis.lut1_to_lut4, fixed_synthesis.lut1_to_lut4)}, "
        f"FF {ratio_delta(adaptive_synthesis.flip_flops, fixed_synthesis.flip_flops)}, "
        f"mapped cells {ratio_delta(adaptive_synthesis.mapped_cells, fixed_synthesis.mapped_cells)}."
    )
    print(
        "This workload uses an oracle fixed topology; score parity does not "
        "measure whether online learning beats a baseline that lacks the "
        "correct topology."
    )
    print(
        "No placement, timing, power, energy, or application-scale accuracy "
        "claim is made."
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sim", type=Path, required=True)
    parser.add_argument("--fixed-netlist", type=Path, required=True)
    parser.add_argument("--adaptive-netlist", type=Path, required=True)
    parser.add_argument("--build-dir", type=Path, default=Path("build"))
    parser.add_argument("--vvp", default="vvp")
    parser.add_argument("--trials", type=int, default=8)
    parser.add_argument("--seed", type=int, default=1)
    arguments = parser.parse_args()

    if not 1 <= arguments.trials <= 100:
        parser.error("--trials must be in [1, 100]")
    arguments.build_dir.mkdir(parents=True, exist_ok=True)

    trial_results: list[TrialResult] = []
    for trial_index in range(arguments.trials):
        seed = arguments.seed + trial_index
        trial = run_trial(
            trial=trial_index + 1,
            seed=seed,
            sim_path=arguments.sim,
            build_dir=arguments.build_dir,
            vvp=arguments.vvp,
        )
        trial_results.append(trial)

    fixed_synthesis = read_synthesis_metrics(
        arguments.fixed_netlist, "eap16_fixed_topology_top"
    )
    adaptive_synthesis = read_synthesis_metrics(
        arguments.adaptive_netlist, "eap16_top"
    )
    write_results(arguments.build_dir, trial_results)
    write_synthesis_summary(
        arguments.build_dir, fixed_synthesis, adaptive_synthesis
    )
    print_results(trial_results, fixed_synthesis, adaptive_synthesis)
    print(
        "Detailed pattern results: "
        f"{arguments.build_dir / 'snn_classification_results.csv'}"
    )
    print(
        "Per-trial results: "
        f"{arguments.build_dir / 'snn_classification_trials.csv'}"
    )
    print(
        "Cycle trace: "
        f"{arguments.build_dir / 'snn_classification_cycle_trace.csv'}"
    )
    print(
        "Synthesis summary: "
        f"{arguments.build_dir / 'snn_synthesis_summary.csv'}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
