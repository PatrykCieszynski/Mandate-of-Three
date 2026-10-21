"""W0 opt-in current-code baseline. Synthetic movement/cache costs, not MMO capacity."""
import argparse
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess
import time
from support.world_profile_source import build as build_profile

ROOT = Path(__file__).resolve().parents[1]


def native_usage(process):
    """Windows process CPU seconds and peak working set; None elsewhere."""
    if os.name != "nt":
        return None

    class Memory(ctypes.Structure):
        _fields_ = [("cb", wintypes.DWORD), ("faults", wintypes.DWORD)] + [
            (name, ctypes.c_size_t) for name in (
                "peak_working_set", "working_set", "peak_paged", "paged",
                "peak_nonpaged", "nonpaged", "pagefile", "peak_pagefile")]

    handle = wintypes.HANDLE(int(process._handle))
    counters = Memory()
    counters.cb = ctypes.sizeof(counters)
    created, exited, kernel, user = (wintypes.FILETIME() for _ in range(4))
    if not ctypes.windll.kernel32.GetProcessTimes(handle, ctypes.byref(created), ctypes.byref(exited), ctypes.byref(kernel), ctypes.byref(user)):
        return None
    if not ctypes.windll.psapi.GetProcessMemoryInfo(handle, ctypes.byref(counters), counters.cb):
        return None
    ticks = lambda value: (value.dwHighDateTime << 32) + value.dwLowDateTime
    return {"whole_process_cpu_seconds": (ticks(kernel) + ticks(user)) / 10_000_000,
            "whole_process_peak_rss_bytes": counters.peak_working_set}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, default=ROOT / ".godot/Godot_v4.7.2-stable_win64.exe")
    parser.add_argument("--scenarios", default="0:0,100:200,250:500")
    parser.add_argument("--layout", choices=("dense", "wide", "both"), default="both")
    parser.add_argument("--cohort", choices=("simulation", "bindings"), default="simulation")
    parser.add_argument("--warmup", type=float, default=3)
    parser.add_argument("--seconds", type=float, default=12)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--profile", choices=("off", "on", "compare"), default="off",
                        help="compare interleaves native control and test-only subtimers on the same commit")
    parser.add_argument("--displacement", action="store_true", help="separate diagnostic: periodic advance/knockback, no damage")
    parser.add_argument("--mob-movement", choices=("native", "light", "compare"), default="native",
                        help="W4a server-only experiment; compare uses unprofiled paired movement policies")
    parser.add_argument("--terrain", action="store_true", help="native disposable flat Terrain3D data, full collider by default")
    parser.add_argument("--terrain-collision", choices=("full", "box"), default="full",
                        help="box keeps common flat physics support and disables terrain collision to isolate grounding API cost")
    parser.add_argument("--mob-grounding", choices=("ray", "height", "compare"), default="ray",
                        help="compare: native, light/ray and light/height on the same Terrain3D")
    args = parser.parse_args()
    if args.mob_movement == "compare" and args.profile != "off":
        parser.error("Movement A/B holds profiling off; use a separate profiled diagnostic")
    if args.mob_grounding != "ray" and not args.terrain:
        parser.error("Height grounding needs --terrain; never substitute fake height samples")
    if args.mob_grounding == "compare" and args.mob_movement != "compare":
        parser.error("Three-way grounding comparison needs --mob-movement compare")
    if args.cohort == "bindings" and (args.profile != "off" or args.displacement or args.mob_movement != "native" or args.terrain):
        parser.error("Binding probe has its own poll/copy metrics; profiling/displacement is simulation-only")
    if os.name == "nt" and "_console" in args.godot.name:
        parser.error("Use the actual win64.exe engine; the console launcher measures a wrapper process")
    try:
        scenarios = [tuple(map(int, pair.split(":"))) for pair in args.scenarios.split(",")]
        assert all(len(pair) == 2 and min(pair) >= 0 for pair in scenarios)
        assert args.repeats > 0 and all(0 < value < float("inf") for value in (args.warmup, args.seconds, args.timeout))
    except (ValueError, AssertionError):
        parser.error("Use nonnegative players:mobs pairs and positive finite timing/repeat values")
    directory = ROOT / ".godot/verification/world-capacity" / time.strftime("%Y%m%d-%H%M%S")
    directory.mkdir(parents=True)
    profile_uri, profile_sources = build_profile(directory / "profile") if args.profile != "off" else ("", {})
    environment = os.environ.copy()
    for key in ("APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        target = directory / key.lower()
        target.mkdir()
        environment[key] = str(target)
    layouts = ["dense", "wide"] if args.layout == "both" else [args.layout]
    cases = [(layout, p, m) for layout in layouts for p, m in scenarios]
    if args.cohort == "bindings":
        cases = [("bindings", 0, 0)]
    records = []
    jobs = []
    for layout, players, mobs in cases:
        for repeat in range(1, args.repeats + 1):
            modes = [False, True] if args.profile == "compare" else [args.profile == "on"]
            if repeat % 2 == 0:
                modes.reverse()
            if args.mob_grounding == "compare":
                variants = [("native", "ray"), ("light", "ray"), ("light", "height")]
            else:
                variants = [(policy, args.mob_grounding) for policy in (["native", "light"] if args.mob_movement == "compare" else [args.mob_movement])]
            if repeat % 2 == 0: variants.reverse()
            jobs.extend((layout, players, mobs, repeat, mode, policy, grounding) for policy, grounding in variants for mode in modes)
    for layout, players, mobs, repeat, profiled, policy, grounding in jobs:
        name = f"{layout}-{players}-{mobs}-{repeat}-{'profile' if profiled else 'control'}-{policy}-{grounding}"
        command = [str(args.godot.resolve()), "--headless", "--path", str(ROOT),
                   "--mode=world-server", "res://tests/world_load_bench.tscn",
                   f"--bench-cohort={args.cohort}", f"--bench-players={players}",
                   f"--bench-mobs={mobs}", f"--bench-wide={int(layout == 'wide')}",
                   f"--bench-profile={int(profiled)}", f"--bench-profile-dir={profile_uri}",
                   f"--bench-displacement={int(args.displacement)}",
                   f"--bench-terrain={int(args.terrain)}", f"--bench-grounding={grounding}",
                   f"--bench-terrain-collision={args.terrain_collision}",
                   f"--bench-warmup={args.warmup}", f"--bench-seconds={args.seconds}"]
        if policy == "light": command.append("--dev-light-mob-movement")
        with (directory / f"{name}.out.log").open("w", encoding="utf-8") as out, (directory / f"{name}.err.log").open("w", encoding="utf-8") as err:
            started = time.monotonic()
            child = subprocess.Popen(command, cwd=ROOT, env=environment, stdout=out, stderr=err,
                                     creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
            usage = None
            try:
                while child.poll() is None:
                    sample = native_usage(child)
                    if sample:
                        usage = sample if usage is None else {key: max(usage[key], value) for key, value in sample.items()}
                    if time.monotonic() - started > args.timeout:
                        raise subprocess.TimeoutExpired(command, args.timeout)
                    time.sleep(0.1)
                code = child.returncode
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
                raise RuntimeError(f"Owned benchmark timed out: {directory / name}")
        text = (directory / f"{name}.out.log").read_text(encoding="utf-8", errors="replace")
        errors = (directory / f"{name}.err.log").read_text(encoding="utf-8", errors="replace")
        rows = [line.partition(" ")[2] for line in text.splitlines() if line.startswith("WORLD_BASELINE_RESULT ")]
        if code or re.search(r"SCRIPT ERROR|Parse Error|Assertion failed", text + errors) or len(rows) != 1:
            raise RuntimeError(f"Benchmark failed: {directory / name}")
        record = json.loads(rows[0])
        if args.cohort == "simulation" and (record["mob_movement"] != policy or record["grounding"] != grounding or record["terrain_fixture"] != args.terrain):
            raise RuntimeError(f"Movement selector mismatch: {directory / name}")
        if args.cohort == "simulation" and record["terrain_collision"] != (args.terrain_collision if args.terrain else "box"):
            raise RuntimeError(f"Terrain collider mismatch: {directory / name}")
        if args.cohort == "simulation" and (record["players"] != players or record["mobs"] != mobs or record["physics_work"]["samples"] < 5):
            raise RuntimeError(f"Invalid actor/sample counts: {directory / name}")
        if args.cohort == "simulation" and profiled:
            required = {"world_movement_snapshot", "mob_tick", "snapshot_roster", "snapshot_encode_proxy"}
            if players:
                required |= {"player_simulate", "player_slide", "player_intersect_shape", "player_exception_add", "player_exception_remove", "player_advance_curve", "player_knockback_damping", "player_advance_probe"}
            if mobs:
                required |= {"mob_ai_inclusive", "mob_motion", "mob_grounding" if policy == "light" else "mob_slide"}
            if not required <= record["profile"].keys():
                raise RuntimeError(f"Missing profiling coverage {required - record['profile'].keys()}: {directory / name}")
        record.update(name=name, repeat=repeat, native_usage=usage, whole_process_wall_seconds=time.monotonic() - started)
        records.append(record)
        print(name, json.dumps({key: record[key] for key in ("physics_work", "tick_interval", "observed_hz")} if args.cohort == "simulation" else {"binding_cases": len(record["cases"])}), flush=True)
    tracked = subprocess.check_output(["git", "ls-files", "-z", "source", "tests", "project.godot"], cwd=ROOT).split(b"\0")
    fingerprint = hashlib.sha256()
    for raw in sorted(filter(None, tracked)):
        path = ROOT / os.fsdecode(raw)
        if path.is_file():
            fingerprint.update(raw + b"\0" + path.read_bytes())
    comparisons = {}
    if args.cohort == "simulation" and args.profile == "compare":
        for layout, p, m in cases:
            rows = [row for row in records if row['name'].startswith(f'{layout}-{p}-{m}-')]
            medians = {mode: {metric: statistics.median(row[metric]['p95_ms'] for row in rows if row['profiled'] == flag) for metric in ('physics_work', 'tick_interval', 'frame_interval')} for mode, flag in [('control', False), ('profile', True)]}
            comparisons[f'{layout}-{p}-{m}'] = {**medians, 'physics_p95_overhead_percent': (medians['profile']['physics_work'] / medians['control']['physics_work'] - 1) * 100}
    movement_comparisons = {}
    if args.mob_movement == "compare":
        for layout, p, m in cases:
            rows = [row for row in records if row['name'].startswith(f'{layout}-{p}-{m}-')]
            for grounding in set(row['grounding'] for row in rows if row['mob_movement'] == 'light'):
                native = [row for row in rows if row['mob_movement'] == 'native']
                light = [row for row in rows if row['mob_movement'] == 'light' and row['grounding'] == grounding]
                medians = {policy: {metric: statistics.median(row[metric]['p95_ms'] for row in group) for metric in ('physics_work', 'tick_interval', 'frame_interval')} for policy, group in [('native', native), ('light', light)]}
                movement_comparisons[f'{layout}-{p}-{m}-{grounding}'] = {**medians, 'physics_p95_change_percent': (medians['light']['physics_work'] / medians['native']['physics_work'] - 1) * 100}
    groups = {}
    if args.cohort == "simulation":
        for row in records:
            key = f"{'wide' if row['wide'] else 'dense'}-{row['players']}-{row['mobs']}-{'profile' if row['profiled'] else 'control'}-{row['mob_movement']}-{row['grounding']}"
            groups.setdefault(key, []).append(row)
    medians = {key: {metric: statistics.median(row[metric]['p95_ms'] for row in rows) for metric in ('physics_work', 'tick_interval')} for key, rows in groups.items()}
    report = {"schema": 4, "git_sha": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "git_status": subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True),
              "source_sha256": fingerprint.hexdigest(), "host": {"platform": platform.platform(), "processor": platform.processor(), "logical_cpus": os.cpu_count()},
              "engine_version": subprocess.check_output([str(args.godot.resolve()), "--version"], text=True).strip(),
              "engine_sha256": hashlib.sha256(args.godot.read_bytes()).hexdigest(),
              "settings": {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()}, "cases": records,
              "profile_source_sha256": profile_sources, "instrumentation_comparison": comparisons,
              "movement_comparison": movement_comparisons,
              "median_simulation": medians}
    (directory / "results.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("WORLD_BASELINE_REPORT", directory.relative_to(ROOT), flush=True)


if __name__ == "__main__":
    main()
