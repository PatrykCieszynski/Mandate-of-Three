"""Install the official pinned Terrain3D addon; native payload stays ignored."""
import hashlib
from pathlib import Path
import shutil
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
VERSION = "1.0.2-stable"
URL = f"https://github.com/TokisanGames/Terrain3D/releases/download/v{VERSION}/Terrain3D_v{VERSION}.zip"
SHA256 = "a071850250ec5e596aa54da61c01d75768774eb379ee997584d426a45f4884a2"
ARCHIVE = ROOT / ".godot/verification" / f"Terrain3D_v{VERSION}.zip"
ADDON = ROOT / "addons/terrain_3d"


def setup():
    ARCHIVE.parent.mkdir(parents=True, exist_ok=True)
    if not ARCHIVE.exists():
        urllib.request.urlretrieve(URL, ARCHIVE)
    if hashlib.sha256(ARCHIVE.read_bytes()).hexdigest() != SHA256:
        raise RuntimeError("Terrain3D archive checksum mismatch")
    with zipfile.ZipFile(ARCHIVE) as archive:
        prefix = "addons/terrain_3d/"
        for entry in archive.infolist():
            if entry.is_dir() or not entry.filename.startswith(prefix):
                continue
            relative = entry.filename[len(prefix):]
            if relative.startswith("bin/") and not relative.startswith(("bin/libterrain.windows.", "bin/libterrain.linux.")):
                continue
            target = (ADDON / relative).resolve()
            if not target.is_relative_to(ADDON.resolve()):
                raise RuntimeError("Unsafe Terrain3D archive path")
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(entry) as source, target.open("wb") as destination:
                shutil.copyfileobj(source, destination)
    print(f"Terrain3D {VERSION} installed (Windows/Linux x86_64 debug+release): {ADDON}")


if __name__ == "__main__":
    setup()
