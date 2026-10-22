"""Player-paced MMO integration/load case; shares the owned PG runner, not stress scenarios."""
import argparse
import json
import math
import os
from pathlib import Path
import platform
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
PRESETS = {"integration": (24, 180), "load": (100, 600), "soak": (100, 1800), "representative": (40, 1800)}


def compare(previous, current):
    """Observations only: no arbitrary performance gate or silent baseline update."""
    keys = ("case", "schema", "metrics_version", "scenario_version", "seed", "requested_players", "admitted_players", "duration_seconds", "environment", "workload_configuration")
    mismatch = [key for key in keys if previous.get(key) != current.get(key)]
    changes = {}
    tails = {}
    for key, value in current["timings"].items():
        old = previous.get("timings", {}).get(key, {})
        if old.get("samples", 0) and value.get("samples", 0):
            before, after = old["p95_ms"], value["p95_ms"]
            changes[key] = {"old_p95_ms": before, "new_p95_ms": after,
                            "delta_percent": None if not before else (after / before - 1) * 100}
            tails[key] = {quantile: {"old_ms": old[quantile], "new_ms": value[quantile]}
                          for quantile in ("p50_ms", "p99_ms", "max_ms")}
    def outcomes(report):
        stats = report["stats"]
        return {"story_completion_share": stats["stories_completed"] / max(stats["stories_started"], 1),
                "successful_actions_per_window_second": report["successful_actions_in_window"] / report["duration_seconds"],
                "admission_rejected": stats["admission_rejected"], "recoveries": stats["recoveries"]}
    return {"comparable_configuration": not mismatch, "mismatched_fields": mismatch,
            "p95_changes": changes, "other_latency_observations": tails,
            "outcomes": {"old": outcomes(previous), "new": outcomes(current)},
            "performance_thresholds": None}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pg-bin", type=Path, required=True)
    parser.add_argument("--godot", type=Path, default=ROOT / ".godot/Godot_v4.7.2-stable_win64_console.exe")
    parser.add_argument("--profile", choices=PRESETS, default="integration")
    parser.add_argument("--players", type=int)
    parser.add_argument("--seconds", type=int)
    parser.add_argument("--seed", type=int, default=1729)
    parser.add_argument("--accounts", type=int, default=300, help="Total economic accounts, including offline sellers (representative only)")
    parser.add_argument("--peak-every", type=int, default=450)
    parser.add_argument("--peak-seconds", type=int, default=45)
    parser.add_argument("--peak-multiplier", type=float, default=3.0)
    parser.add_argument("--compare", type=Path, help="Previous realm-workload.json; read only")
    args = parser.parse_args()
    players = args.players if args.players is not None else PRESETS[args.profile][0]
    seconds = args.seconds if args.seconds is not None else PRESETS[args.profile][1]
    if players < 1 or seconds < 1:
        parser.error("players and seconds must be positive; there is no harness population/performance cap")
    representative = args.profile == "representative"
    if representative and (args.accounts <= players or not 0 < args.peak_seconds < args.peak_every or
                           not math.isfinite(args.peak_multiplier) or args.peak_multiplier <= 1):
        parser.error("representative requires offline sellers, non-overlapping positive peaks and finite multiplier > 1")
    # The owner bounds native work and always stops its cluster in finally.
    # Do not kill that owner via an outer timeout.
    result = subprocess.run([sys.executable, str(ROOT / "tools/postgres/run_readiness.py"),
                             "--pg-bin", str(args.pg_bin), "--godot", str(args.godot),
                             "--suite", "realm-workload", "--realm-players", str(players),
                             "--realm-seconds", str(seconds), "--realm-seed", str(args.seed),
                             "--realm-case", "representative" if representative else "stories",
                             "--economy-accounts", str(args.accounts),
                             "--economy-peak-every", str(args.peak_every),
                             "--economy-peak-seconds", str(args.peak_seconds),
                             "--economy-peak-multiplier", str(args.peak_multiplier)],
                            cwd=ROOT, capture_output=True, text=True, encoding="utf-8",
                            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
    print(result.stdout, end="", flush=True)
    if result.stderr:
        print(result.stderr, file=sys.stderr, end="")
    if result.returncode:
        raise SystemExit(result.returncode)
    match = re.search(r"POSTGRES_REALM_WORKLOAD_PASS (.+)", result.stdout)
    if not match:
        raise RuntimeError("Missing realm PASS marker")
    directory = (ROOT / match[1].strip()).resolve()
    if not directory.is_relative_to((ROOT / ".godot/verification/postgres-readiness").resolve()):
        raise RuntimeError("Unexpected fixture path")
    report = json.loads((directory / "realm-workload.json").read_text(encoding="utf-8"))
    summary = json.loads((directory / "summary.json").read_text(encoding="utf-8"))
    if report["invariants"] != "PASS" or not report["workers_stopped"] or not summary["stopped"]:
        raise RuntimeError("Missing integrity/worker/cluster closure proof")
    report["host"] = {"platform": platform.platform(), "processor": platform.processor(),
                      "logical_cpus": os.cpu_count(), "soci": summary["soci"]}
    if args.compare:
        previous = json.loads(args.compare.read_text(encoding="utf-8"))
        report["comparison"] = compare(previous, report)
        if previous.get("host") != report["host"]:
            report["comparison"]["comparable_configuration"] = False
            report["comparison"]["mismatched_fields"].append("host")
        comparison = report["comparison"]
        largest = sorted(comparison["p95_changes"].items(),
                         key=lambda entry: entry[1]["delta_percent"] or 0, reverse=True)[:5]
        print("COMPARISON", json.dumps({"comparable_configuration": comparison["comparable_configuration"],
                                         "mismatched_fields": comparison["mismatched_fields"],
                                         "largest_p95_increases": dict(largest),
                                         "outcomes": comparison["outcomes"]}), flush=True)
    (directory / "realm-workload.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: report[key] for key in ("requested_players", "admitted_players", "roles", "active_economic_accounts", "stats", "action_successes", "exchange_outcomes")}, indent=2))
    print("REALM_WORKLOAD_REPORT", directory.relative_to(ROOT) / "realm-workload.json", flush=True)


if __name__ == "__main__":
    main()
