"""Install pinned official server-only SOCI payload; never rebuild the addon."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request
import zipfile
ROOT=Path(__file__).resolve().parents[2]
LOCK=json.loads((Path(__file__).parent/'release.json').read_text(encoding='utf-8'))
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check',action='store_true')
args=parser.parse_args()
addon=ROOT/'addons/godot_soci'
if not args.check:
    archive=ROOT/'.godot/plugin-cache'/LOCK['asset']; archive.parent.mkdir(parents=True,exist_ok=True)
    if not archive.exists():
        local=ROOT/'.godot/verification/soci-release-041'/LOCK['asset']
        archive.write_bytes(local.read_bytes() if local.exists() else urllib.request.urlopen(LOCK['url'],timeout=60).read())
    if hashlib.sha256(archive.read_bytes()).hexdigest()!=LOCK['sha256']: raise ValueError('SOCI archive hash mismatch')
    with zipfile.ZipFile(archive) as z:
        names={e.filename for e in z.infolist() if not e.is_dir()}
        if names!=set(LOCK['files']): raise ValueError('Unexpected release payload')
        for name,sha in LOCK['files'].items():
            data=z.read(name)
            if hashlib.sha256(data).hexdigest()!=sha: raise ValueError('Invalid payload: '+name)
            path=ROOT/name
            if not path.resolve().is_relative_to(addon.resolve()): raise ValueError('Unsafe archive path')
            if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest()==sha: continue
            path.parent.mkdir(parents=True,exist_ok=True); path.write_bytes(data)
for name,sha in LOCK['files'].items():
    path=ROOT/name
    if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest()!=sha: raise ValueError('Missing/modified installed SOCI file: '+name)
print('SOCI '+LOCK['tag']+' verified: '+str(addon))
