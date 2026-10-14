"""Verify/install the S0-only released addon in ignored diagnostic storage.

No runtime installation, source checkout, latest-main fetch or production DB.
Run with --install once; normal test runs only verify the cached pinned package.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
LOCK = json.loads((ROOT / "tests/fixtures/auction_soci_release.json").read_text())
CACHE = ROOT / ".godot/verification/soci-release"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def dependencies(path):
    """Read PE imports / ELF64 DT_NEEDED without executing the binary."""
    data = path.read_bytes()
    if data[:2] == b"MZ":
        pe = struct.unpack_from("<I", data, 0x3C)[0]
        assert data[pe:pe + 4] == b"PE\0\0"
        machine, count = struct.unpack_from("<HH", data, pe + 4)
        assert machine == 0x8664, "Expected Windows x86_64"
        optional_size = struct.unpack_from("<H", data, pe + 20)[0]
        optional = pe + 24
        assert struct.unpack_from("<H", data, optional)[0] == 0x20B
        sections = optional + optional_size

        def offset(rva):
            for index in range(count):
                size, address, raw_size, raw = struct.unpack_from("<IIII", data, sections + index * 40 + 8)
                if address <= rva < address + max(size, raw_size):
                    return raw + rva - address
            raise ValueError("Invalid PE address")

        imports, _ = struct.unpack_from("<II", data, optional + 112 + 8)
        cursor = offset(imports)
        names = []
        while any(data[cursor:cursor + 20]):
            address = struct.unpack_from("<I", data, cursor + 12)[0]
            start = offset(address)
            names.append(data[start:data.index(b"\0", start)].decode())
            cursor += 20
        return sorted(names)
    assert data[:6] == b"\x7fELF\x02\x01", "Expected little-endian ELF64"
    assert struct.unpack_from("<H", data, 18)[0] == 62, "Expected Linux x86_64"
    table = struct.unpack_from("<Q", data, 40)[0]
    size, count = struct.unpack_from("<HH", data, 58)
    sections = [struct.unpack_from("<IIQQQQIIQQ", data, table + index * size) for index in range(count)]
    names = []
    for section in sections:
        if section[1] != 6:  # SHT_DYNAMIC
            continue
        strings = sections[section[6]][4]
        for cursor in range(section[4], section[4] + section[5], section[9]):
            tag, value = struct.unpack_from("<qQ", data, cursor)
            if tag == 1:  # DT_NEEDED
                start = strings + value
                names.append(data[start:data.index(b"\0", start)].decode())
    return sorted(names)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install", action="store_true", help="Explicitly download the pinned released ZIP if absent")
    parser.add_argument("--fixture-directory", type=Path, help="Reject fixture paths resolving outside disposable storage, including symlinks")
    options = parser.parse_args()
    if not CACHE.resolve().is_relative_to(ROOT.resolve() / ".godot/verification"):
        raise ValueError("S0 cache resolves outside this project's disposable directory")
    if options.fixture_directory and not options.fixture_directory.resolve().is_relative_to(ROOT.resolve() / ".godot/verification"):
        raise ValueError("S0 fixture resolves outside this project's disposable directory")
    CACHE.mkdir(parents=True, exist_ok=True)
    archive = CACHE / LOCK["asset"]
    if not archive.exists():
        if not options.install:
            parser.error("Pinned addon absent; run python tests/prepare-auction-soci-s0.py --install first")
        request = urllib.request.Request(LOCK["url"], headers={"User-Agent": "Mandate-S0"})
        with urllib.request.urlopen(request, timeout=60) as response:
            archive.write_bytes(response.read())
    if digest(archive) != LOCK["sha256"]:
        raise ValueError("S0 release ZIP SHA-256 mismatch; refusing to load")
    package = CACHE / "package"
    with zipfile.ZipFile(archive) as zipped:
        files = {entry.filename for entry in zipped.infolist() if not entry.is_dir()}
        if files != set(LOCK["files"]):
            raise ValueError("Unexpected S0 release payload")
        for name, expected in LOCK["files"].items():
            payload = zipped.read(name)
            if hashlib.sha256(payload).hexdigest() != expected:
                raise ValueError("Invalid archived payload: " + name)
            path = package / name
            if options.install:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(payload)
            if not path.is_file() or digest(path) != expected:
                raise ValueError("Installed S0 payload missing/modified: " + name)
    native = {}
    for name, sha in LOCK["files"].items():
        if name.endswith((".dll", ".so")):
            native[name] = {"sha256": sha, "dependencies": dependencies(package / name)}
            if name.endswith(".so"):
                versions = {v.decode() for v in re.findall(rb"GLIBC_[0-9]+(?:\.[0-9]+)+", (package / name).read_bytes())}
                native[name]["glibc_symbols"] = sorted(versions, key=lambda v: tuple(map(int, v[6:].split("."))))
    # This report is binary provenance, never a Linux runtime PASS.
    report = {"tag": LOCK["tag"], "commit": LOCK["commit"], "archive_sha256": LOCK["sha256"], "native": native}
    (CACHE / "provenance.json").write_text(json.dumps(report, indent=2) + "\n")
    # Diagnostic selector only: unchanged pinned Release payload under a Debug
    # editor, so GDScript assertions still run. Never edit the released descriptor.
    descriptor = (package / "addons/godot_soci/soci.gdextension").read_text()
    release_descriptor = descriptor.replace("./bin/", "./package/addons/godot_soci/bin/").replace("template_debug", "template_release")
    (CACHE / "soci-release-library.gdextension").write_text(release_descriptor)
    print("AUCTION_S0_RELEASE " + json.dumps(report))


if __name__ == "__main__":
    main()
