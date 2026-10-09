"""Install pinned Windows CEF into the real project. No copied gameplay tree."""
from pathlib import Path
import importlib.util
import shutil
import zlib
import zipfile
from plugin import ARCHIVE, ensure_archive
ROOT = Path(__file__).resolve().parents[2]
ADDON = ROOT / "addons/godot_cef"

def setup():
    ensure_archive()
    ADDON.mkdir(parents=True, exist_ok=True)
    prefix = "dist/addons/godot_cef/"
    with zipfile.ZipFile(ARCHIVE) as archive:
        for entry in archive.infolist():
            if not entry.filename.startswith(prefix) or entry.is_dir():
                continue
            relative = entry.filename[len(prefix):]
            if relative.startswith("bin/") and not relative.startswith("bin/x86_64-pc-windows-msvc/"):
                continue
            target = (ADDON / relative).resolve()
            if not target.is_relative_to(ADDON.resolve()):
                raise RuntimeError("Unsafe archive entry")
            # Release checksum protects the archive; compare installed files by CRC
            # without loading Chromium DLLs into Python memory.
            if target.exists() and target.stat().st_size == entry.file_size:
                crc = 0
                with target.open("rb") as installed:
                    for block in iter(lambda: installed.read(1024 * 1024), b""):
                        crc = zlib.crc32(block, crc)
                if crc == entry.CRC:
                    continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(entry) as source, target.open("wb") as dest:
                shutil.copyfileobj(source, dest)
    skin_spec = importlib.util.spec_from_file_location("stage_ui_skin", ROOT / "tools/dev_assets/stage_ui_skin.py")
    skin = importlib.util.module_from_spec(skin_spec)
    skin_spec.loader.exec_module(skin)
    skin.stage()
    print("CEF installed:", ADDON)
    print("Run the root project directly; no source/assets/config copy.")

if __name__ == "__main__":
    setup()
