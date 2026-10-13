"""Bounded reproduction of the V4 headless saved-scene failure; opt-in diagnostic."""
import argparse
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", type=Path, default=ROOT / ".godot/Godot_v4.7.2-stable_win64_console.exe")
    parser.add_argument("--scene", default="res://tools/terrain3d/repro_scene.tscn")
    args = parser.parse_args()
    log = ROOT / ".godot/verification/visual-v4-saved-scene-repro.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w", encoding="utf-8") as output:
        process = subprocess.Popen([str(args.godot.resolve()), "--headless", "--path", str(ROOT),
                                    "--mode=world-server", args.scene, "--quit-after", "90"],
                                   cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
        try:
            code = process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            if os.name == "nt":
                # Godot's console launcher can own an engine child process.
                subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                               capture_output=True, check=False)
            else:
                process.kill()
            process.wait()
            print(f"Probe timed out; its owned process was stopped. Log: {log}")
            return 1
    print(f"Saved Terrain3D scene exit={code} (0x{code & 0xFFFFFFFF:08X}). Log: {log}")
    return 0 if code == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
