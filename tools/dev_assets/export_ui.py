"""Export explicitly selected local UI images to exact RGBA PNGs; no resizing."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PureWindowsPath
import shlex
import tempfile

from PIL import Image, __version__ as PILLOW_VERSION

REPO = Path(__file__).resolve().parents[2]
CACHE = Path('dev_assets/legacy/ui_cache')
SCHEMA = 1


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def relative_name(value):
    name = str(value).replace('\\', '/')
    if not name or Path(name).is_absolute() or PureWindowsPath(name).drive or ':' in name or '..' in Path(name).parts:
        raise ValueError('Expected a relative path within the configured UI source')
    return Path(name)


def source_file(root, relative):
    # The client looks up names case-insensitively. Preserve actual disk spelling.
    candidate = root
    for part in relative_name(relative).parts:
        matches = [p for p in candidate.iterdir() if p.name.casefold() == part.casefold()]
        if len(matches) != 1:
            raise ValueError(f'Missing or ambiguous source: {relative}')
        candidate = matches[0]
        if not candidate.resolve(strict=True).is_relative_to(root):
            raise ValueError('Source escapes configured UI root')
    if not candidate.is_file():
        raise ValueError('Expected a source file')
    return candidate


def parse_sub(text):
    fields = {}
    for number, line in enumerate(text.splitlines(), 1):
        tokens = shlex.split(line, comments=True, posix=False)
        if not tokens:
            continue
        if len(tokens) != 2:
            raise ValueError(f'Invalid .sub line {number}')
        key, value = tokens
        key = key.lower()
        if key in fields:
            raise ValueError('Duplicate .sub field: ' + key)
        fields[key] = value.strip('"')
    required = {'title', 'version', 'image', 'left', 'top', 'right', 'bottom'}
    if set(fields) != required or fields['title'].lower() != 'subimage' or fields['version'] not in ('1.0', '2.0'):
        raise ValueError('Expected subImage version 1.0 or 2.0 with exact rectangle fields')
    rect = tuple(int(fields[key]) for key in ('left', 'top', 'right', 'bottom'))
    left, top, right, bottom = rect
    if left < 0 or top < 0 or right <= left or bottom <= top:
        raise ValueError('Invalid .sub rectangle')
    relative_name(fields['image'])
    return fields, rect


def writable(path, repo):
    cache = repo / CACHE
    if not path.is_relative_to(cache):
        raise ValueError('Destination escapes UI cache')
    for candidate in (path, *path.parents):
        if candidate == repo:
            break
        if candidate.is_symlink() or candidate.is_junction():
            raise ValueError('Cache destination must not contain links or junctions')
    if not path.resolve().is_relative_to(cache.resolve()):
        raise ValueError('Destination escapes UI cache')


def atomic_json(path, data, repo):
    writable(path, repo)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.ui-', suffix='.tmp', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            json.dump(data, stream, indent=2, ensure_ascii=False)
            stream.write('\n')
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def export_selected(source_root, selections, repo_root=REPO):
    repo = Path(repo_root).resolve(strict=True)
    root = Path(source_root).resolve(strict=True)
    if not root.is_dir() or root.is_relative_to(repo):
        raise ValueError('UI source directory must be outside the Godot project')
    cache = repo / CACHE
    manifest_path = cache / 'manifest.json'
    writable(manifest_path, repo)
    manifest = json.loads(manifest_path.read_text(encoding='utf-8')) if manifest_path.exists() else {'schema': SCHEMA, 'assets': {}}
    if manifest.get('schema') != SCHEMA or not isinstance(manifest.get('assets'), dict):
        raise ValueError('Unsupported UI cache manifest')
    results = []
    for selected in selections:
        try:
            requested = relative_name(selected)
            source = source_file(root, requested)
            suffix = source.suffix.lower()
            if suffix not in ('.sub', '.dds', '.tga'):
                raise ValueError('Select .sub, .dds or .tga files only')
            original = source.relative_to(root).as_posix()
            fields, rect = (None, None)
            if suffix == '.sub':
                fields, rect = parse_sub(source.read_text(encoding='utf-8-sig'))
                reference = relative_name(fields['image'])
                if fields['version'] == '2.0':
                    reference = source.relative_to(root).parent / reference
                texture = source_file(root, reference)
            else:
                texture = source
            if texture.suffix.lower() not in ('.dds', '.tga'):
                raise ValueError('The .sub image must reference DDS or TGA')
            output_relative = original + '.png'  # Keep source extension to avoid .sub/.tga name collisions.
            output = cache / output_relative
            writable(output, repo)
            identity = {'source_path': original, 'source_root': str(root), 'source_sha256': digest(source),
                        'texture_path': texture.relative_to(root).as_posix(), 'texture_sha256': digest(texture),
                        'sub': fields, 'rect': list(rect) if rect else None, 'decoder': 'Pillow ' + PILLOW_VERSION,
                        'algorithm': 'exact-rgba-v1', 'output': output_relative}
            fingerprint = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
            prior = manifest['assets'].get(original, {})
            if prior.get('fingerprint') == fingerprint and output.is_file() and prior.get('output_sha256') == digest(output):
                results.append({'source': original, 'status': 'CACHED', 'output': str(output)})
                continue
            with Image.open(texture) as decoded:
                image = decoded.convert('RGBA')
            if rect:
                if rect[2] > image.width or rect[3] > image.height:
                    raise ValueError('Rectangle extends beyond source texture; padding is forbidden')
                image = image.crop(rect)
            output.parent.mkdir(parents=True, exist_ok=True)
            fd, temporary = tempfile.mkstemp(prefix='.ui-', suffix='.tmp', dir=output.parent)
            os.close(fd)
            try:
                image.save(temporary, format='PNG')
                with Image.open(temporary) as reread:
                    if reread.mode != 'RGBA' or reread.size != image.size or reread.tobytes() != image.tobytes():
                        raise ValueError('PNG pixel verification failed')
                record = identity | {'fingerprint': fingerprint, 'size': list(image.size),
                    'rgba_sha256': hashlib.sha256(image.tobytes()).hexdigest(), 'output_sha256': digest(temporary)}
                os.replace(temporary, output)
            finally:
                Path(temporary).unlink(missing_ok=True)
            manifest['assets'][original] = record
            atomic_json(manifest_path, manifest, repo)
            results.append({'source': original, 'status': 'EXPORTED', 'output': str(output)})
        except (OSError, ValueError, KeyError) as error:
            results.append({'source': str(selected), 'status': 'FAILED', 'error': str(error)})
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('files', nargs='+', help='Explicit relative .sub/.tga/.dds paths under UI source')
    parser.add_argument('--source-root', type=Path, default=os.environ.get('MANDATE_LEGACY_UI_SOURCE_ROOT'))
    args = parser.parse_args()
    if not args.source_root:
        parser.error('Set --source-root or MANDATE_LEGACY_UI_SOURCE_ROOT')
    try:
        results = export_selected(args.source_root, args.files)
    except (OSError, ValueError) as error:
        parser.exit(1, f'UI export failed: {error}\n')
    print(json.dumps(results, indent=2))
    return int(any(result['status'] == 'FAILED' for result in results))


if __name__ == '__main__':
    raise SystemExit(main())
