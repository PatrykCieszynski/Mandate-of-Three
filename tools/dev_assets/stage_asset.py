"""Stage one explicitly selected, self-contained GLB. No conversion or batch scan."""
import argparse
import json
import os
from pathlib import Path
import shutil
import struct
import tempfile

REPO_ROOT = Path(__file__).resolve().parents[2]
ASSETS = {
    "stray_dog": Path("mobs/stray_dog/stray_dog.glb"),
    "warrior": Path("players/warrior/warrior.glb"),
    "warrior_armor": Path("players/warrior/warrior_armor.glb"),
    "iron_sword": Path("weapons/iron_sword/iron_sword.glb"),
}


def validate_glb(path: Path) -> None:
    with path.open("rb") as stream:
        header = stream.read(20)
        if len(header) != 20:
            raise ValueError("Truncated GLB")
        magic, version, total, length, kind = struct.unpack("<IIIII", header)
        if magic != 0x46546C67 or version != 2 or total != path.stat().st_size or kind != 0x4E4F534A:
            raise ValueError("Expected a GLB v2 with a JSON chunk")
        if length > total - 20:
            raise ValueError("Invalid GLB JSON chunk length")
        metadata = json.loads(stream.read(length))
    for key in ("buffers", "images"):
        if any("uri" in entry for entry in metadata.get(key, [])):
            raise ValueError("Only self-contained GLB files may be staged")


def stage_asset(asset_id: str, generated_root: Path, repo_root: Path = REPO_ROOT) -> Path:
    if asset_id not in ASSETS:
        raise ValueError("Unsupported selected asset")
    return stage_relative_asset(ASSETS[asset_id], generated_root, repo_root)


def stage_relative_asset(relative: Path, generated_root: Path, repo_root: Path = REPO_ROOT) -> Path:
    relative = Path(relative)
    if relative.is_absolute() or '..' in relative.parts or relative.suffix.lower() != '.glb':
        raise ValueError('Expected a selected relative GLB path')
    repo_root = repo_root.resolve(strict=True)
    generated_root = generated_root.resolve(strict=True)
    if generated_root.is_relative_to(repo_root):
        raise ValueError("Generated source must be outside the Godot project")
    source = (generated_root / relative).resolve(strict=True)
    if not source.is_relative_to(generated_root):
        raise ValueError("Source escapes the configured generated root")
    validate_glb(source)
    destination = repo_root / "dev_assets/legacy" / relative
    # Reject staging through symlinks/junctions, including an existing target.
    for candidate in [destination, *destination.parents]:
        if candidate == repo_root: break
        if candidate.is_symlink() or candidate.is_junction():
            raise ValueError("Staging destination must not contain links or junctions")
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".stage-", suffix=".tmp", dir=destination.parent)
    os.close(fd)
    try:
        shutil.copyfile(source, temporary)
        os.replace(temporary, destination)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return destination


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("asset_id", choices=ASSETS)
    parser.add_argument("--generated-root", type=Path)
    parser.add_argument("--config", type=Path, default=Path(__file__).with_name("local.json"))
    args = parser.parse_args()
    try:
        configured = args.generated_root or os.environ.get("MANDATE_LEGACY_GENERATED_ROOT")
        if not configured and args.config.is_file():
            configured = json.loads(args.config.read_text(encoding="utf-8-sig")).get("generated_root")
        if not configured:
            raise ValueError("Set --generated-root, MANDATE_LEGACY_GENERATED_ROOT or local.json; see local.example.json")
        generated_root = Path(configured)
        if not generated_root.is_absolute(): generated_root = REPO_ROOT / generated_root
        print(stage_asset(args.asset_id, generated_root))
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"Staging failed: {error}\n")


if __name__ == "__main__":
    main()
