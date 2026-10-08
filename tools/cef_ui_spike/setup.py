"""Windows-only isolated setup. Plugin never enters the production addon path."""
from pathlib import Path
import hashlib, shutil, urllib.request, zipfile
ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / ".godot" / "cef-spike"
PROJECT = CACHE / "project"
VERSION = "v2.0.0"
SHA256 = "6d58235aa47b654a0a9410dfd40e9d7cb43ffe13d034d9f24fdb44cc2cea1b33"
ARCHIVE = CACHE / f"godot_cef-store-{VERSION}.zip"
URL = f"https://github.com/dsh0416/godot-cef/releases/download/{VERSION}/{ARCHIVE.name}"

def setup():
    CACHE.mkdir(parents=True, exist_ok=True)
    if not ARCHIVE.exists():
        print("Downloading pinned official release", flush=True)
        urllib.request.urlretrieve(URL, ARCHIVE)
    with ARCHIVE.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    if digest != SHA256:
        raise RuntimeError("Archive checksum mismatch; remove only this archive and retry")
    print("Official archive SHA256 verified", flush=True)
    addon = PROJECT / "addons" / "godot_cef"
    if not (addon / "bin/x86_64-pc-windows-msvc/gdcef.dll").exists():
        prefix = "dist/addons/godot_cef/"
        with zipfile.ZipFile(ARCHIVE) as archive:
            for entry in archive.infolist():
                if not entry.filename.startswith(prefix) or entry.is_dir(): continue
                relative = entry.filename[len(prefix):]
                if relative.startswith("bin/") and not relative.startswith("bin/x86_64-pc-windows-msvc/"): continue
                target = (addon / relative).resolve()
                if not target.is_relative_to(addon.resolve()): raise RuntimeError("Unsafe archive entry")
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(entry) as source, target.open("wb") as dest: shutil.copyfileobj(source, dest)
    for project in [PROJECT, CACHE / "baseline"]:
        project.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / "tools/cef_ui_spike/project.godot", project / "project.godot")
        for relative in ["source/client/ui_web", "tests/cef_ui"]:
            target = (project / relative).resolve()
            if not target.is_relative_to(CACHE.resolve()): raise RuntimeError("Unsafe copied-source path")
            if target.exists(): shutil.rmtree(target)
            shutil.copytree(ROOT / relative, target)
        # Browser URL treats `tests` as its authority. Keep fixture modules on
        # that same bundled origin rather than climbing above res://tests/.
        shared = project / "tests/cef_ui/web/shared"
        shared.mkdir(parents=True, exist_ok=True)
        for name in ["protocol.js", "bridge.js", "store.js"]:
            shutil.copy2(ROOT / "source/client/ui_web/web" / name, shared / name)
    print(f"CEF project: {PROJECT}")
    print("No addon/config changes to production project")

if __name__ == "__main__": setup()
