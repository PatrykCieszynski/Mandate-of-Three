"""Build an ignored Windows Vulkan/CEF gameplay client; root servers stay CEF-free."""
from pathlib import Path
import hashlib, shutil, sys, zipfile
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/cef_ui_spike'))
from setup import ARCHIVE, SHA256, setup as setup_spike
TARGET = ROOT / '.godot/cef-client/project'

def setup():
    if not ARCHIVE.exists():
        setup_spike()
    with ARCHIVE.open('rb') as stream:
        if hashlib.file_digest(stream, 'sha256').hexdigest() != SHA256:
            raise RuntimeError('Pinned CEF archive checksum mismatch')
    TARGET.mkdir(parents=True, exist_ok=True)
    # Refresh bounded copied trees, never touch the source checkout/runtime DBs.
    for name in ['source', 'assets', 'data', 'addons', 'tests', 'dev_assets']:
        target = (TARGET / name).resolve()
        if not target.is_relative_to(TARGET.resolve()):
            raise RuntimeError('Unsafe staging target')
        if name != 'addons' and target.exists():
            shutil.rmtree(target)
        if not (ROOT / name).is_dir():
            continue
        shutil.copytree(ROOT / name, target, dirs_exist_ok=True,
            ignore=shutil.ignore_patterns('*.db', '*.db-*', '*.log', 'account_collection.tres', 'godot_mcp', '__pycache__'))
    addon = TARGET / 'addons/godot_cef'
    prefix = 'dist/addons/godot_cef/'
    with zipfile.ZipFile(ARCHIVE) as archive:
        for entry in archive.infolist():
            if not entry.filename.startswith(prefix) or entry.is_dir():
                continue
            relative = entry.filename[len(prefix):]
            if relative.startswith('bin/') and not relative.startswith('bin/x86_64-pc-windows-msvc/'):
                continue
            target = (addon / relative).resolve()
            if not target.is_relative_to(addon.resolve()):
                raise RuntimeError('Unsafe archive entry')
            if target.exists() and target.stat().st_size == entry.file_size:
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(entry) as source, target.open('wb') as dest:
                shutil.copyfileobj(source, dest)
    imported = ROOT / '.godot/imported'
    if imported.exists():
        shutil.copytree(imported, TARGET / '.godot/imported', dirs_exist_ok=True)
    project = (ROOT / 'project.godot').read_text(encoding='utf-8')
    project = project.replace('renderer/rendering_method="gl_compatibility"', 'renderer/rendering_method="mobile"')
    project = project.replace('renderer/rendering_method.mobile="gl_compatibility"', 'renderer/rendering_method.mobile="mobile"')
    project = project.replace('"GL Compatibility"', '"Mobile"')
    project += """
[godot_cef]
security/default_permission_policy=0
storage/data_path="user://mandate-cef-profile"
performance/max_frame_rate=60
"""
    (TARGET / 'project.godot').write_text(project, encoding='utf-8')
    print('Client staging:', TARGET)
    print('Root project/addons/server stores unchanged. Refresh staging after source edits.')

if __name__ == '__main__':
    setup()
