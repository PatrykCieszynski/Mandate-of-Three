"""Opt-in, isolated headless Godot World simulation/serialization benchmark.

Run: python tests/run-world-capacity.py --godot PATH/TO/GODOT
This does NOT create real connected clients; see docs/development/world-capacity-benchmark.md.
"""
import argparse
import csv
import json
import os
from pathlib import Path
import platform
import re
import socket
import subprocess
import time


def scenarios(value: str) -> list[tuple[int, int]]:
    result = []
    for pair in value.split(","):
        bits = pair.split(":")
        if len(bits) != 2:
            raise argparse.ArgumentTypeError("Use players:mobs[,players:mobs...]")
        try:
            players, mobs = map(int, bits)
        except ValueError as error:
            raise argparse.ArgumentTypeError("Counts must be integers") from error
        if players < 0 or players > 500 or mobs < 0 or mobs > 2000:
            raise argparse.ArgumentTypeError("Players 0..500, mobs 0..2000")
        result.append((players, mobs))
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, required=True, help="Godot 4.7.2 console/editor executable")
    parser.add_argument("--scenarios", type=scenarios, default=scenarios("0:0,100:200,250:500,500:1000"))
    parser.add_argument("--warmup", type=float, default=3.0)
    parser.add_argument("--seconds", type=float, default=12.0)
    parser.add_argument("--repeats", type=int, default=1)
    parser.add_argument("--encode-per-peer", action="store_true", help="Encode full roster once per synthetic peer (CPU proxy, not RPC)")
    parser.add_argument("--no-overlap", action="store_true", help="Ablation: return no overlapping mobs (changes collisions)")
    parser.add_argument("--no-mob-slide", action="store_true", help="Ablation: skip mob move_and_slide (changes gameplay)")
    parser.add_argument("--wide", action="store_true", help="Use a large sparse physics floor instead of the dense arena")
    parser.add_argument("--ai-ms", type=int, default=0, help="Ablation: recompute mob AI every N milliseconds (0=baseline)")
    parser.add_argument("--pack-size", type=int, default=1, help="Mobs per shared pack (1=baseline; max 100)")
    parser.add_argument("--timeout", type=float, default=240.0, help="Per-scenario hard timeout")
    args = parser.parse_args()
    if not args.godot.is_file():
        parser.error("Godot executable not found")
    if (args.warmup < 1 or args.seconds < 3 or args.repeats < 1 or
            args.timeout < args.warmup + args.seconds + 10 or
            not 1 <= args.pack_size <= 100 or not 0 <= args.ai_ms <= 1000):
        parser.error("Invalid duration/repeat/timeout arguments")
    root = Path(__file__).resolve().parents[1]
    logs = root / ".godot" / "verification" / "world-capacity"
    logs.mkdir(parents=True, exist_ok=True)
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 18109))
    environment = os.environ.copy()
    for key, folder in [
        ("APPDATA", "appdata"), ("LOCALAPPDATA", "localappdata"),
        ("XDG_DATA_HOME", "xdg-data"), ("XDG_CONFIG_HOME", "xdg-config"),
        ("XDG_CACHE_HOME", "xdg-cache"),
    ]:
        directory = logs / folder
        directory.mkdir(exist_ok=True)
        environment[key] = str(directory)
    environment["MANDATE_BENCH_WIDE"] = "1" if args.wide else "0"

    results: list[dict] = []
    mode_label = "_".join(
        ["encode" if args.encode_per_peer else "simulation"] +
        (["no_overlap"] if args.no_overlap else []) +
        (["no_mob_slide"] if args.no_mob_slide else []) +
        (["wide"] if args.wide else []) +
        ([f"ai_{args.ai_ms}"] if args.ai_ms else []) +
        ([f"pack_{args.pack_size}"] if args.pack_size != 1 else [])
    )
    for players, mobs in args.scenarios:
        for attempt in range(args.repeats):
            name = f"{mode_label}_players-{players}_mobs-{mobs}_repeat-{attempt + 1}"
            stdout = logs / f"{name}.out.log"
            stderr = logs / f"{name}.err.log"
            command = [
                str(args.godot.resolve()), "--headless", "--path", str(root),
                "--mode=world-server", "res://tests/world_load_bench.tscn",
                f"--bench-players={players}", f"--bench-mobs={mobs}",
                f"--bench-warmup={args.warmup}", f"--bench-seconds={args.seconds}",
                f"--bench-encode-per-peer={int(args.encode_per_peer)}",
                f"--bench-no-overlap={int(args.no_overlap)}",
                f"--bench-no-mob-slide={int(args.no_mob_slide)}",
                f"--bench-wide={int(args.wide)}",
                f"--bench-ai-ms={args.ai_ms}",
                f"--bench-pack-size={args.pack_size}",
            ]
            start = time.monotonic()
            with stdout.open("w", encoding="utf-8") as out, stderr.open("w", encoding="utf-8") as err:
                process = subprocess.Popen(
                    command, stdout=out, stderr=err, cwd=root, env=environment,
                    creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
                )
                try:
                    code = process.wait(timeout=args.timeout)
                except subprocess.TimeoutExpired as error:
                    process.kill()
                    process.wait(timeout=10)
                    raise RuntimeError(f"World benchmark hung in {name}; see {logs}") from error
            output = stdout.read_text(encoding="utf-8", errors="replace")
            errors = stderr.read_text(encoding="utf-8", errors="replace")
            if code != 0 or re.search(r"SCRIPT ERROR|Parse Error|WORLD_LOAD_BENCH_FAILED", output + errors):
                raise RuntimeError(f"World benchmark failed in {name} (exit {code}); see {logs}")
            records = [line.split(" ", 1)[1] for line in output.splitlines() if line.startswith("WORLD_LOAD_RESULT ")]
            if len(records) != 1:
                raise RuntimeError(f"Expected exactly one benchmark result in {name}; see {logs}")
            record = json.loads(records[0])
            if record["players"] != players or record["physics_work"]["n"] < 5:
                raise RuntimeError(f"Invalid workload/samples in {name}; see {logs}")
            record.update({"repeat": attempt + 1, "scenario": name, "wall_run_seconds": round(time.monotonic() - start, 3)})
            results.append(record)
            print(f"{name}: physics p95={record['physics_work']['p95_ms']} ms, "
                  f"tick p99={record['tick_interval']['p99_ms']} ms, "
                  f"observed={record['observed_ticks_per_second']:.1f} ticks/s")
            time.sleep(0.3)

    report = {
        "benchmark": "synthetic-headless-world-not-network-client-capacity",
        "host": {"platform": platform.platform(), "machine": platform.machine(),
                 "logical_cpu_count": os.cpu_count(), "godot": str(args.godot.resolve())},
        "settings": {"warmup": args.warmup, "seconds": args.seconds,
                     "repeats": args.repeats, "encode_per_peer": args.encode_per_peer,
                     "no_overlap": args.no_overlap, "no_mob_slide": args.no_mob_slide,
                     "wide": args.wide, "ai_ms": args.ai_ms, "pack_size": args.pack_size},
        "cases": results,
    }
    (logs / f"results-{mode_label}.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    columns = ["scenario", "players", "mobs", "repeat", "observed_ticks_per_second",
               "static_memory_mib", "estimated_outbound_mib_per_second",
               "overlap_query_ms_total", "player_simulate_ms_total",
               "mob_motion_ms_total", "mob_tick_ms_total",
               "physics_p50_ms", "physics_p95_ms", "physics_p99_ms",
               "interval_p95_ms", "interval_p99_ms", "samples_over_budget"]
    with (logs / f"results-{mode_label}.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=columns)
        writer.writeheader()
        for case in results:
            writer.writerow({
                **{name: case.get(name, "") for name in columns},
                "physics_p50_ms": case["physics_work"]["p50_ms"],
                "physics_p95_ms": case["physics_work"]["p95_ms"],
                "physics_p99_ms": case["physics_work"]["p99_ms"],
                "interval_p95_ms": case["tick_interval"]["p95_ms"],
                "interval_p99_ms": case["tick_interval"]["p99_ms"],
                "samples_over_budget": case["physics_samples_over_16_67_ms"],
                "overlap_query_ms_total": case["profile"]["overlap_query_ms_total"],
                "player_simulate_ms_total": case["profile"]["player_simulate_ms_total"],
                "mob_motion_ms_total": case["profile"]["mob_motion_ms_total"],
                "mob_tick_ms_total": case["profile"]["mob_tick_ms_total"],
            })
    print(f"Saved: {logs / f'results-{mode_label}.json'} and {logs / f'results-{mode_label}.csv'}")


if __name__ == "__main__":
    main()
