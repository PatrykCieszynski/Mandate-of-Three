"""Repeat the owned-cluster mixed World workload sequentially and collect evidence.

Every run starts from a fresh cluster/data set. No installed service, external
DSN or parallel competing benchmark is used. Detailed evidence stays ignored.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HIDDEN = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pg-bin", type=Path, required=True)
    parser.add_argument("--godot", type=Path, default=ROOT/".godot/Godot_v4.7.2-stable_win64_console.exe")
    parser.add_argument("--seconds", type=int, default=8)
    parser.add_argument("--runs", type=int, choices=(1,2,3), default=3)
    args = parser.parse_args()
    if not 2 <= args.seconds <= 1800:
        parser.error("--seconds must be between 2 and 1800 per cohort")
    parent = ROOT/".godot/verification/postgres-mixed-load"
    parent.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="series-", dir=parent))
    results = []
    for index in range(args.runs):
        print(f"Mixed workload: fresh cluster {index+1}/{args.runs}", flush=True)
        result = subprocess.run([sys.executable, str(ROOT/"tools/postgres/run_readiness.py"),
                                 "--pg-bin", str(args.pg_bin), "--godot", str(args.godot),
                                 "--suite", "mixed-load", "--load-seconds", str(args.seconds),
                                 "--load-repeats", "1"], cwd=ROOT, capture_output=True,
                                # The owned runner bounds every native operation
                                # and cleans its cluster in finally. Do not kill
                                # that owner from an outer wall-time timeout.
                                text=True, encoding="utf-8",
                                creationflags=HIDDEN)
        (output/f"run-{index+1}.log").write_text(result.stdout+result.stderr, encoding="utf-8")
        match = re.search(r"POSTGRES_MIXED_LOAD_PASS (.+)", result.stdout)
        if result.returncode or match is None:
            raise RuntimeError(f"Mixed run failed; inspect {output.relative_to(ROOT)}")
        directory = (ROOT/match[1].strip()).resolve()
        if not directory.is_relative_to((ROOT/".godot/verification/postgres-readiness").resolve()):
            raise RuntimeError("Unexpected fixture evidence path")
        result = json.loads((directory/"mixed-load.json").read_text(encoding="utf-8"))
        summary = json.loads((directory/"summary.json").read_text(encoding="utf-8"))
        if result["invariants"] != "PASS" or not result["native_workers_stopped"] or not summary["stopped"]:
            raise RuntimeError("Missing invariant/worker/cluster closure proof")
        results.append({"evidence":str(directory.relative_to(ROOT)), "report":result})
        print(f"Mixed workload: run {index+1} PASS / owned cluster stopped", flush=True)
    report = {"runs":results,"seconds_per_cohort":args.seconds,"fresh_clusters":args.runs,
              "same_host":True,"not_mmo_capacity":True,"result":"PASS"}
    (output/"summary.json").write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")
    print("POSTGRES_MIXED_SERIES_PASS", output.relative_to(ROOT), flush=True)


if __name__ == "__main__":
    main()
