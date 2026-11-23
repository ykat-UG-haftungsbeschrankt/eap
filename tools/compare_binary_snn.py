#!/usr/bin/env python3
#
# Copyright (c) 2026 ykat UG (haftungsbeschraenkt) - All Rights Reserved
#
# Permission for non-commercial use is hereby granted,
# free of charge, without warranty of any kind.

"""Compare fixed, adaptive EAP-16, and binary-LUT SNNs on shared workloads."""

from __future__ import annotations

import argparse
import csv
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from statistics import mean, pstdev

import compare_snn as baseline


N = baseline.N
FIFO_DEPTH = baseline.FIFO_DEPTH
CLASS0_PE, CLASS1_PE = baseline.CLASS_TARGETS
RESULT_FIELDS = (
    "trial",
    "seed",
    "patterns",
    "fixed_rtl_accuracy",
    "eap16_accuracy",
    "binary_lut_accuracy",
    "fixed_class0_accuracy",
    "fixed_class1_accuracy",
    "eap16_class0_accuracy",
    "eap16_class1_accuracy",
    "binary_class0_accuracy",
    "binary_class1_accuracy",
)


@dataclass(frozen=True)
class BinaryCycle:
    cycle: int
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


def parse_binary_output(output: str) -> list[BinaryCycle]:
    config: tuple[int, int] | None = None
    cycles: list[BinaryCycle] = []
    end_cycle: int | None = None

    for line in output.splitlines():
        if line.startswith("BCONFIG,"):
            fields = line.split(",")
            if len(fields) != 3:
                raise RuntimeError(f"malformed BCONFIG record: {line}")
            config = (int(fields[1]), int(fields[2]))
        elif line.startswith("BTRACE,"):
            fields = line.split(",")
            if len(fields) != 14:
                raise RuntimeError(
                    f"malformed BTRACE record with {len(fields)} fields: {line}"
                )
            cycles.append(
                BinaryCycle(
                    cycle=int(fields[1]),
                    action_index=int(fields[2]),
                    evaluation=bool(int(fields[3])),
                    pattern_id=int(fields[4]),
                    label=int(fields[5]),
                    event_valid=bool(int(fields[6])),
                    event_source=int(fields[7]),
                    event_ready=bool(int(fields[8])),
                    event_accepted=bool(int(fields[9])),
                    spikes=int(fields[10], 16),
                    class0_connections=int(fields[11]),
                    class1_connections=int(fields[12]),
                    overflow=bool(int(fields[13])),
                )
            )
        elif line.startswith("BEND,"):
            end_cycle = int(line.split(",")[1])

    if config != (N, FIFO_DEPTH):
        raise RuntimeError(
            f"binary network config {config} does not match {(N, FIFO_DEPTH)}"
        )
    if end_cycle != len(cycles):
        raise RuntimeError(
            f"binary END record {end_cycle} does not match "
            f"{len(cycles)} trace cycles"
        )
    return cycles


def run_binary_trial(
    trial: int,
    seed: int,
    actions: list[baseline.Stimulus],
    patterns: tuple[baseline.EvaluationPattern, ...],
    sim_path: Path,
    build_dir: Path,
    vvp: str,
) -> tuple[dict[int, baseline.ClassificationScore], list[BinaryCycle]]:
    stimulus_path = build_dir / f"snn_binary_classification_seed_{seed}.mem"
    baseline.write_stimulus(stimulus_path, actions)
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
        raise RuntimeError(f"binary trial {trial} (seed {seed}) timed out") from error
    if simulation.returncode != 0:
        sys.stderr.write(simulation.stdout)
        sys.stderr.write(simulation.stderr)
        raise RuntimeError(
            f"binary trial {trial} (seed {seed}) exited "
            f"with code {simulation.returncode}"
        )

    cycles = parse_binary_output(simulation.stdout)
    if len(cycles) > baseline.MAX_SIMULATION_CYCLES:
        raise AssertionError("binary simulation exceeded its cycle bound")
    validate_binary_progress(cycles, actions)
    scores = score_binary_lane(patterns, cycles)
    return scores, cycles


def validate_binary_progress(
    cycles: list[BinaryCycle], actions: list[baseline.Stimulus]
) -> None:
    action_index = 0
    topology_checked = False

    for cycle_number, lane in enumerate(cycles):
        if lane.cycle != cycle_number:
            raise AssertionError(
                f"binary trace cycle {lane.cycle} appeared at index "
                f"{cycle_number}"
            )
        stimulus = baseline.action_or_idle(actions, action_index)
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
                f"binary stimulus mismatch at cycle {cycle_number}: "
                f"{actual} != {expected}"
            )
        if lane.event_accepted != (lane.event_valid and lane.event_ready):
            raise AssertionError(
                f"binary lane reported an invalid handshake at cycle "
                f"{cycle_number}"
            )
        if lane.overflow:
            raise AssertionError(
                f"binary event router overflowed at cycle {cycle_number}"
            )
        if lane.evaluation and not topology_checked:
            if (
                lane.class0_connections != len(baseline.CLASS_FEATURES[0])
                or lane.class1_connections != len(baseline.CLASS_FEATURES[1])
            ):
                raise AssertionError(
                    "binary learner did not form the expected feature edges"
                )
            topology_checked = True

        if action_index < len(actions) and (
            not lane.event_valid or lane.event_ready
        ):
            action_index += 1

    if action_index != len(actions):
        raise AssertionError(
            f"binary lane accepted {action_index}/{len(actions)} actions"
        )
    if not topology_checked:
        raise AssertionError("binary simulation reached no held-out evaluation")


def score_binary_lane(
    patterns: tuple[baseline.EvaluationPattern, ...],
    cycles: list[BinaryCycle],
) -> dict[int, baseline.ClassificationScore]:
    counts = {pattern.pattern_id: [0, 0] for pattern in patterns}
    labels = {pattern.pattern_id: pattern.label for pattern in patterns}
    output_bits = (1 << CLASS0_PE, 1 << CLASS1_PE)

    for cycle in cycles:
        if not cycle.evaluation:
            continue
        if cycle.pattern_id not in counts:
            raise AssertionError(
                f"binary trace has unknown pattern {cycle.pattern_id}"
            )
        if cycle.label != labels[cycle.pattern_id]:
            raise AssertionError(
                f"binary trace mislabeled pattern {cycle.pattern_id}"
            )
        for output, bit in enumerate(output_bits):
            counts[cycle.pattern_id][output] += int(bool(cycle.spikes & bit))

    return {
        pattern_id: baseline.classify_spikes(
            (pattern_counts[0], pattern_counts[1]),
            labels[pattern_id],
        )
        for pattern_id, pattern_counts in counts.items()
    }


def class_accuracy(
    scores: dict[int, baseline.ClassificationScore],
    patterns: tuple[baseline.EvaluationPattern, ...],
    label: int,
) -> float:
    ids = [
        pattern.pattern_id for pattern in patterns if pattern.label == label
    ]
    return sum(scores[pattern_id].correct for pattern_id in ids) / len(ids)


def write_trial_results(
    path: Path,
    trials: list[
        tuple[
            baseline.TrialResult,
            dict[int, baseline.ClassificationScore],
            list[BinaryCycle],
        ]
    ],
) -> None:
    with path.open("w", newline="", encoding="ascii") as output_file:
        writer = csv.DictWriter(output_file, fieldnames=RESULT_FIELDS)
        writer.writeheader()
        for result, binary_scores, _ in trials:
            writer.writerow(
                {
                    "trial": result.trial,
                    "seed": result.seed,
                    "patterns": len(result.patterns),
                    "fixed_rtl_accuracy": (
                        f"{baseline.overall_accuracy(result.fixed_scores):.6f}"
                    ),
                    "eap16_accuracy": (
                        f"{baseline.overall_accuracy(result.adaptive_scores):.6f}"
                    ),
                    "binary_lut_accuracy": (
                        f"{baseline.overall_accuracy(binary_scores):.6f}"
                    ),
                    "fixed_class0_accuracy": (
                        f"{class_accuracy(result.fixed_scores, result.patterns, 0):.6f}"
                    ),
                    "fixed_class1_accuracy": (
                        f"{class_accuracy(result.fixed_scores, result.patterns, 1):.6f}"
                    ),
                    "eap16_class0_accuracy": (
                        f"{class_accuracy(result.adaptive_scores, result.patterns, 0):.6f}"
                    ),
                    "eap16_class1_accuracy": (
                        f"{class_accuracy(result.adaptive_scores, result.patterns, 1):.6f}"
                    ),
                    "binary_class0_accuracy": (
                        f"{class_accuracy(binary_scores, result.patterns, 0):.6f}"
                    ),
                    "binary_class1_accuracy": (
                        f"{class_accuracy(binary_scores, result.patterns, 1):.6f}"
                    ),
                }
            )


def print_comparison(
    trials: list[
        tuple[
            baseline.TrialResult,
            dict[int, baseline.ClassificationScore],
            list[BinaryCycle],
        ]
    ],
    fixed_metrics: baseline.SynthesisMetrics,
    adaptive_metrics: baseline.SynthesisMetrics,
    binary_metrics: baseline.SynthesisMetrics,
) -> None:
    total_patterns = sum(len(result.patterns) for result, _, _ in trials)
    score_sets = (
        (
            "Fixed-topology SNN (RTL)",
            [result.fixed_scores for result, _, _ in trials],
        ),
        (
            "Adaptive EAP-16",
            [result.adaptive_scores for result, _, _ in trials],
        ),
        (
            "Binary-LUT BLM",
            [scores for _, scores, _ in trials],
        ),
    )

    print(
        f"Task: seeded binary event-pattern classification; {len(trials)} "
        f"trials, {total_patterns} held-out patterns."
    )
    print(
        "All models receive the same training/evaluation actions per seed; "
        "plasticity is frozen during evaluation."
    )
    print(
        "Fixed-topology SNN is an oracle baseline with the correct 8 edges "
        "wired in advance; EAP-16 and BLM learn those edges from teacher spikes."
    )
    print("Classifier: larger spike count at PE 14/15 wins; ties count as wrong.")
    print("  Model                         Correct   Accuracy   Mean/trial +/- SD")

    for name, per_trial_scores in score_sets:
        all_scores = [
            score
            for scores in per_trial_scores
            for score in scores.values()
        ]
        accuracies = [
            baseline.overall_accuracy(scores) for scores in per_trial_scores
        ]
        correct = sum(score.correct for score in all_scores)
        print(
            f"  {name:<29} {correct:>3}/{total_patterns:<3} "
            f"{100 * correct / total_patterns:>7.2f}% "
            f"{100 * mean(accuracies):>7.2f}% +/- "
            f"{100 * pstdev(accuracies):.2f}%"
        )

    print("Gowin-mapped network primitive counts (synthesis only):")
    print("  Model                         LUT1-4  MUX2_LUT   ALU   FFs   RAM  Cells")
    for name, metrics in (
        ("Fixed-topology SNN", fixed_metrics),
        ("Adaptive EAP-16", adaptive_metrics),
        ("Binary-LUT BLM", binary_metrics),
    ):
        print(
            f"  {name:<29} {metrics.lut1_to_lut4:>6} "
            f"{metrics.mux2_lut:>9} {metrics.alu:>5} "
            f"{metrics.flip_flops:>5} {metrics.ram_primitives:>5} "
            f"{metrics.mapped_cells:>6}"
        )
    print(
        "Primitive counts are not placement, timing, power, or area results. "
        "No physical event-rate or application-scale claim is made."
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sim", type=Path, required=True)
    parser.add_argument("--binary-sim", type=Path, required=True)
    parser.add_argument("--fixed-netlist", type=Path, required=True)
    parser.add_argument("--adaptive-netlist", type=Path, required=True)
    parser.add_argument("--binary-netlist", type=Path, required=True)
    parser.add_argument("--build-dir", type=Path, default=Path("build"))
    parser.add_argument("--vvp", default="vvp")
    parser.add_argument("--trials", type=int, default=8)
    parser.add_argument("--seed", type=int, default=1)
    arguments = parser.parse_args()

    if not 1 <= arguments.trials <= 100:
        parser.error("--trials must be in [1, 100]")
    arguments.build_dir.mkdir(parents=True, exist_ok=True)

    trial_results: list[
        tuple[
            baseline.TrialResult,
            dict[int, baseline.ClassificationScore],
            list[BinaryCycle],
        ]
    ] = []
    for trial_index in range(arguments.trials):
        seed = arguments.seed + trial_index
        result = baseline.run_trial(
            trial=trial_index + 1,
            seed=seed,
            sim_path=arguments.sim,
            build_dir=arguments.build_dir,
            vvp=arguments.vvp,
        )
        actions, patterns = baseline.build_workload(seed)
        binary_scores, binary_cycles = run_binary_trial(
            trial=trial_index + 1,
            seed=seed,
            actions=actions,
            patterns=patterns,
            sim_path=arguments.binary_sim,
            build_dir=arguments.build_dir,
            vvp=arguments.vvp,
        )
        if len(result.patterns) != len(patterns):
            raise AssertionError("comparison lanes received different patterns")
        trial_results.append((result, binary_scores, binary_cycles))

    fixed_metrics = baseline.read_synthesis_metrics(
        arguments.fixed_netlist, "eap16_fixed_topology_top"
    )
    adaptive_metrics = baseline.read_synthesis_metrics(
        arguments.adaptive_netlist, "eap16_top"
    )
    binary_metrics = baseline.read_synthesis_metrics(
        arguments.binary_netlist, "binary_lut_array"
    )

    output_path = arguments.build_dir / "snn_binary_comparison_trials.csv"
    write_trial_results(output_path, trial_results)
    print_comparison(
        trial_results,
        fixed_metrics,
        adaptive_metrics,
        binary_metrics,
    )
    print(f"Per-trial results: {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
