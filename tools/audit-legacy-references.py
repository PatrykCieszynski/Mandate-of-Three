#!/usr/bin/env python3
"""Conservative inventory of potentially stale Godot resources.

Read-only: this tool never deletes assets. Missing literal references do not prove
an asset unused (dynamic load(), UID paths and generated content are possible).
"""
from __future__ import annotations

import argparse
from collections import Counter
from pathlib import Path

TEXT_SUFFIXES = {".gd", ".tscn", ".tres", ".godot", ".cfg", ".json", ".js", ".ts",
                 ".html", ".css", ".ps1", ".py", ".md", ".gdshader", ".gdshaderinc"}
SKIP_DIRS = {".git", ".godot", "node_modules", ".venv", "__pycache__"}
CANDIDATE_TERMS = ("legacy", "old", "prototype", "spike", "placeholder", "tinymmo")
RESOURCE_SUFFIXES = {".gd", ".tscn", ".tres", ".res", ".png", ".svg", ".jpg",
                     ".webp", ".ogg", ".wav", ".mp3", ".gdshader"}


def inventory(root: Path) -> list[tuple[str, int, list[str]]]:
    files = [p for p in root.rglob("*") if p.is_file() and
             not any(part in SKIP_DIRS for part in p.relative_to(root).parts)]
    sources: dict[Path, str] = {}
    for path in files:
        if path.suffix.lower() in TEXT_SUFFIXES and path.stat().st_size <= 2_000_000:
            try:
                sources[path] = path.read_text(encoding="utf-8")
            except (OSError, UnicodeError):
                pass
    findings = []
    for path in files:
        rel = path.relative_to(root).as_posix()
        if path.suffix.lower() not in RESOURCE_SUFFIXES:
            continue
        if not any(term in rel.lower() for term in CANDIDATE_TERMS):
            continue
        # Never treat sidecar imports/UIDs as independent candidates.
        token = "res://" + rel
        hits = []
        for source, text in sources.items():
            if source == path:
                continue
            if token in text:
                hits.append(source.relative_to(root).as_posix())
        findings.append((rel, len(hits), hits))
    return sorted(findings)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--limit", type=int, default=120)
    args = parser.parse_args()
    root = args.root.resolve()
    if not (root / "project.godot").is_file():
        parser.error("root must contain project.godot")
    findings = inventory(root)
    print(f"Scanned candidate resources: {len(findings)}")
    print("NOTE: zero literal references does not prove safe removal.")
    for rel, count, hits in findings[:max(args.limit, 0)]:
        print(f"{count:3}  {rel}")
        for hit in hits[:3]:
            print(f"     <- {hit}")
    counts = Counter(p.split("/")[0] for p, _, _ in findings)
    print("Candidate buckets:", dict(sorted(counts.items())))


if __name__ == "__main__":
    main()
