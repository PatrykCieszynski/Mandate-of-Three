"""Pinned CEF download for the gameplay client; no standalone spike projects."""
from pathlib import Path
import hashlib, urllib.request
ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / '.godot/cef-client/cache'
VERSION = 'v2.0.0'
SHA256 = '6d58235aa47b654a0a9410dfd40e9d7cb43ffe13d034d9f24fdb44cc2cea1b33'
ARCHIVE = CACHE / f'godot_cef-store-{VERSION}.zip'
URL = f'https://github.com/dsh0416/godot-cef/releases/download/{VERSION}/{ARCHIVE.name}'

def ensure_archive():
    CACHE.mkdir(parents=True,exist_ok=True)
    if not ARCHIVE.exists():
        temporary = ARCHIVE.with_suffix('.zip.part')
        try:
            print('Downloading pinned CEF',VERSION,flush=True)
            urllib.request.urlretrieve(URL,temporary)
            with temporary.open('rb') as stream:
                if hashlib.file_digest(stream,'sha256').hexdigest() != SHA256:
                    raise RuntimeError('Pinned CEF archive checksum mismatch')
            temporary.replace(ARCHIVE)
        finally:
            temporary.unlink(missing_ok=True)
    with ARCHIVE.open('rb') as stream:
        if hashlib.file_digest(stream,'sha256').hexdigest() != SHA256:
            raise RuntimeError('Pinned CEF archive checksum mismatch')
    return ARCHIVE
