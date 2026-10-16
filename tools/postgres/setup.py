"""Opt-in portable Windows test binaries; no installer/service/system changes."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
LOCK = json.loads(Path(__file__).with_name("release.json").read_text(encoding="utf-8"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    cache = ROOT / ".godot/plugin-cache"
    archive = cache / LOCK["asset"]
    target = cache / ("postgresql-" + LOCK["version"])
    cache.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        if args.check:
            raise RuntimeError("Portable PostgreSQL archive not installed")
        temporary = archive.with_suffix(".part")
        with urllib.request.urlopen(LOCK["url"], timeout=60) as source, temporary.open("wb") as destination:
            shutil.copyfileobj(source, destination, 1024 * 1024)
        temporary.replace(archive)
    with archive.open("rb") as source:
        if hashlib.file_digest(source, "sha256").hexdigest() != LOCK["sha256"]:
            raise RuntimeError("Portable PostgreSQL archive checksum mismatch")
    with zipfile.ZipFile(archive) as package:
        for entry in package.infolist():
            if entry.is_dir() or not entry.filename.startswith(("pgsql/bin/", "pgsql/lib/", "pgsql/share/")):
                continue
            path = (target / entry.filename).resolve()
            if not path.is_relative_to(target.resolve()):
                raise RuntimeError("Unsafe PostgreSQL archive path")
            expected = hashlib.sha256(package.read(entry)).digest()
            if path.exists():
                with path.open("rb") as installed:
                    if hashlib.file_digest(installed, "sha256").digest() == expected:
                        continue
            if args.check:
                raise RuntimeError("Missing/modified portable PostgreSQL payload: " + entry.filename)
            path.parent.mkdir(parents=True, exist_ok=True)
            with package.open(entry) as source, path.open("wb") as destination:
                shutil.copyfileobj(source, destination)
    print("PORTABLE_POSTGRES_VERIFIED", LOCK["version"], target / "pgsql/bin")


if __name__ == "__main__":
    main()
