"""D0 diagnostic packs only; never modifies installed addon or export presets.

The pinned editor is a debug engine. Bind debug selector to the release extension
in a copied pack to exercise that actual binary too. This is not a release-exe
or Linux-runtime PASS. The installed external native libraries are still needed.
"""
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parent.parent
VERIFY = ROOT / ".godot" / "verification"
EXTENSION = "addons/godot-sqlite/gdsqlite.gdextension"

for platform in ("ServerWindows", "ServerUbuntu"):
    source = VERIFY / f"auction-d0-{platform}.zip"
    destination = VERIFY / f"auction-d0-{platform}-release-library.zip"
    with zipfile.ZipFile(source) as src, zipfile.ZipFile(destination, "w") as out:
        names = set(src.namelist())
        for required in (EXTENSION, "tests/auction_sqlite_threads.gdc", "tests/fixtures/auction_read_probe.gdc"):
            if required not in names:
                raise RuntimeError(f"missing diagnostic resource: {platform}: {required}")
        for entry in src.infolist():
            data = src.read(entry)
            if entry.filename == EXTENSION:
                data = data.replace(b"libgdsqlite.windows.template_debug.x86_64.dll", b"libgdsqlite.windows.template_release.x86_64.dll")
                data = data.replace(b"libgdsqlite.linux.template_debug.x86_64.so", b"libgdsqlite.linux.template_release.x86_64.so")
            out.writestr(entry, data)
    print(f"D0 diagnostic pack prepared: {destination.name}")
