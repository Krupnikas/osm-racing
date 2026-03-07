#!/usr/bin/env python3

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path


MEAN_RE = re.compile(r"mean_volume:\s*(-?\d+(?:\.\d+)?) dB")
MAX_RE = re.compile(r"max_volume:\s*(-?\d+(?:\.\d+)?) dB")
SUPPORTED_SUFFIXES = {".wav", ".ogg", ".mp3", ".flac"}
LOOP_HINTS = {
    "idle",
    "low_on",
    "low_off",
    "med_on",
    "med_off",
    "high_on",
    "high_off",
    "maxrpm",
    "int_idle",
    "int_low_on",
    "int_low_off",
    "int_med_on",
    "int_med_off",
    "int_high_on",
    "int_high_off",
    "int_maxrpm",
    "intake",
    "whine",
}
EVENT_HINTS = {
    "startup",
    "start",
    "gearup",
    "geardown",
    "shift",
    "upshift",
    "downshift",
    "limiter",
    "backfire",
    "stab",
}


def find_audio_files(paths: list[str]) -> list[Path]:
    files: list[Path] = []
    for raw_path in paths:
        path = Path(raw_path)
        if path.is_file() and path.suffix.lower() in SUPPORTED_SUFFIXES:
            files.append(path)
            continue
        if path.is_dir():
            for candidate in sorted(path.rglob("*")):
                if candidate.is_file() and candidate.suffix.lower() in SUPPORTED_SUFFIXES:
                    files.append(candidate)
    return files


def detect_profile(path: Path) -> str:
    name = path.stem.lower()
    if "loop" in name or any(hint in name for hint in LOOP_HINTS):
        return "loop"
    if any(hint in name for hint in EVENT_HINTS):
        return "event"
    return "event"


def analyze_file(path: Path) -> tuple[float, float]:
    command = [
        "ffmpeg",
        "-hide_banner",
        "-nostats",
        "-i",
        str(path),
        "-af",
        "volumedetect",
        "-f",
        "null",
        "-",
    ]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    output = result.stdout + result.stderr

    mean_match = MEAN_RE.search(output)
    max_match = MAX_RE.search(output)
    if result.returncode != 0 or not mean_match or not max_match:
        raise RuntimeError(f"Could not analyze {path}")

    return float(mean_match.group(1)), float(max_match.group(1))


def recommend_gain(mean_db: float, max_db: float, target_mean_db: float, peak_ceiling_db: float) -> float:
    return min(target_mean_db - mean_db, peak_ceiling_db - max_db)


def main() -> int:
    parser = argparse.ArgumentParser(description="Analyze vehicle audio clip levels and recommend gain trims.")
    parser.add_argument("paths", nargs="+", help="Audio files or directories to analyze.")
    parser.add_argument("--loop-target", type=float, default=-28.0, help="Target mean volume for loop clips.")
    parser.add_argument("--event-target", type=float, default=-23.0, help="Target mean volume for event clips.")
    parser.add_argument("--peak-ceiling", type=float, default=-3.0, help="Maximum allowed peak after gain is applied.")
    parser.add_argument("--json", dest="json_path", help="Optional path to write the analysis as JSON.")
    args = parser.parse_args()

    if shutil.which("ffmpeg") is None:
        print("ffmpeg not found in PATH", file=sys.stderr)
        return 2

    files = find_audio_files(args.paths)
    if not files:
        print("No audio files found.", file=sys.stderr)
        return 1

    rows = []
    for path in files:
        mean_db, max_db = analyze_file(path)
        profile = detect_profile(path)
        target_mean_db = args.loop_target if profile == "loop" else args.event_target
        gain_db = recommend_gain(mean_db, max_db, target_mean_db, args.peak_ceiling)
        rows.append(
            {
                "file": str(path),
                "profile": profile,
                "mean_db": round(mean_db, 1),
                "max_db": round(max_db, 1),
                "target_mean_db": round(target_mean_db, 1),
                "suggested_gain_db": round(gain_db, 1),
                "result_mean_db": round(mean_db + gain_db, 1),
                "result_peak_db": round(max_db + gain_db, 1),
            }
        )

    header = f"{'File':44} {'Type':6} {'Mean':>7} {'Peak':>7} {'Gain':>7} {'Result':>14}"
    print(header)
    print("-" * len(header))
    for row in rows:
        file_name = Path(row["file"]).name
        result_str = f"{row['result_mean_db']:>5.1f}/{row['result_peak_db']:>5.1f}"
        print(
            f"{file_name:44} {row['profile']:6} "
            f"{row['mean_db']:>7.1f} {row['max_db']:>7.1f} {row['suggested_gain_db']:>7.1f} {result_str:>14}"
        )

    if args.json_path:
        output_path = Path(args.json_path)
        output_path.write_text(json.dumps(rows, indent=2) + "\n", encoding="utf-8")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
