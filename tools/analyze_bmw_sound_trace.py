#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
from collections import Counter, defaultdict
from pathlib import Path


LOOP_ORDER = [
    "idle",
    "low_on",
    "med_on",
    "high_on",
    "low_off",
    "med_off",
    "high_off",
    "max_rpm",
]


def f(row: dict[str, str], key: str, default: float = 0.0) -> float:
    try:
        return float(row.get(key, default))
    except (TypeError, ValueError):
        return default


def i(row: dict[str, str], key: str, default: int = 0) -> int:
    try:
        return int(float(row.get(key, default)))
    except (TypeError, ValueError):
        return default


def load_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def dominant_loop(row: dict[str, str]) -> str:
    best_loop = LOOP_ORDER[0]
    best_weight = -1.0
    for loop_id in LOOP_ORDER:
        weight = f(row, f"{loop_id}_weight")
        if weight > best_weight:
            best_loop = loop_id
            best_weight = weight
    return best_loop


def first_speed_for(rows: list[dict[str, str]], column: str, threshold: float) -> float | None:
    for row in rows:
        if f(row, column) >= threshold:
            return f(row, "speed_kmh")
    return None


def pct(part: int, whole: int) -> float:
    if whole <= 0:
        return 0.0
    return (part / whole) * 100.0


def main() -> int:
    parser = argparse.ArgumentParser(description="Summarize a BMW engine sound trace CSV.")
    parser.add_argument("trace_csv", help="Path to user://bmw_engine_sound_trace.csv copied to the filesystem")
    args = parser.parse_args()

    trace_path = Path(args.trace_csv).expanduser().resolve()
    if not trace_path.exists():
        raise SystemExit(f"Trace file not found: {trace_path}")

    rows = load_rows(trace_path)
    if not rows:
        raise SystemExit(f"Trace file is empty: {trace_path}")

    duration_s = max(f(rows[-1], "time_s") - f(rows[0], "time_s"), 0.0)
    dominant_counts = Counter(dominant_loop(row) for row in rows)

    avg_rpm_by_gear: dict[int, list[float]] = defaultdict(list)
    for row in rows:
        gear = i(row, "gear")
        if gear > 0:
            avg_rpm_by_gear[gear].append(f(row, "rpm"))

    high_on_early = [row for row in rows if f(row, "speed_kmh") < 120.0 and f(row, "high_on_weight") > 0.35]
    max_rpm_early = [row for row in rows if f(row, "speed_kmh") < 160.0 and f(row, "max_rpm_weight") > 0.18]
    revvy_low_speed = [row for row in rows if f(row, "speed_kmh") < 80.0 and f(row, "rpm") > 5500.0]

    earliest_high_on = first_speed_for(rows, "high_on_weight", 0.25)
    earliest_max_rpm = first_speed_for(rows, "max_rpm_weight", 0.10)

    print(f"Trace: {trace_path}")
    print(f"Samples: {len(rows)}")
    print(f"Duration: {duration_s:.1f} s")
    print(f"Max speed: {max(f(row, 'speed_kmh') for row in rows):.1f} km/h")
    print(f"Max rpm: {max(f(row, 'rpm') for row in rows):.0f}")
    print()

    print("Dominant loop share:")
    for loop_id in LOOP_ORDER:
        count = dominant_counts.get(loop_id, 0)
        print(f"  {loop_id:<8} {pct(count, len(rows)):5.1f}%")
    print()

    print("Average RPM by gear:")
    for gear in sorted(avg_rpm_by_gear):
        samples = avg_rpm_by_gear[gear]
        print(f"  gear {gear}: {sum(samples) / len(samples):.0f} rpm")
    print()

    print("Early high-band checks:")
    print(f"  high_on >= 0.25 first appears at: {earliest_high_on:.1f} km/h" if earliest_high_on is not None else "  high_on never reached 0.25")
    print(f"  max_rpm >= 0.10 first appears at: {earliest_max_rpm:.1f} km/h" if earliest_max_rpm is not None else "  max_rpm never reached 0.10")
    print(f"  high_on > 0.35 below 120 km/h: {pct(len(high_on_early), len(rows)):.1f}% of samples")
    print(f"  max_rpm > 0.18 below 160 km/h: {pct(len(max_rpm_early), len(rows)):.1f}% of samples")
    print(f"  rpm > 5500 below 80 km/h: {pct(len(revvy_low_speed), len(rows)):.1f}% of samples")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
