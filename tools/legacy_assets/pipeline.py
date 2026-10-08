"""Explicit local index / conversion / staging commands. Python 3.12+, stdlib."""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import traceback

from asset_index import AssetIndex, REPO, actor_bundle, category_for, external, scan, sha256, virtual_path, write_json
from catalog import ALIASES, ARMORS, GROUPS, MOBS, SWORDS, bundle_for, relative_output
sys.path.insert(0, str(REPO / 'tools/dev_assets'))
from stage_asset import stage_relative_asset, validate_glb

HERE = Path(__file__).resolve().parent


DOMAIN_STATUSES = ('MISSING_MODEL', 'MISSING_TEXTURE', 'MISSING_ANIMATION', 'IMPORT_FAILED',
                   'EXPORT_FAILED', 'INVALID_SKELETON', 'UNKNOWN_LAYOUT')


class AssetFailure(Exception):
    """An expected asset/conversion failure, distinct from an orchestration bug."""
    def __init__(self, status, message):
        if status not in DOMAIN_STATUSES:
            raise ValueError('Unknown asset failure status: ' + status)
        self.status = status
        super().__init__(message)


def configuration(path, command='convert_asset', native=False):
    config = json.loads(Path(path).read_text(encoding='utf-8-sig')) if Path(path).is_file() else {}
    required = ['generated_root']
    if not command.startswith('stage'):
        required.append('source_root')
    if command.startswith('convert') or (command == 'resolve_asset' and native):
        required.extend(('blender', 'importer_root', 'importer_revision'))
    for key in required:
        value = os.environ.get('MANDATE_LEGACY_' + key.upper(), config.get(key))
        if not value:
            raise ValueError(f'Set {key} in local.json or MANDATE_LEGACY_{key.upper()}')
        if key != 'importer_revision':
            value = Path(value)
            if not value.is_absolute():
                value = REPO / value
            value = str(value.resolve(strict=key != 'generated_root'))
        config[key] = value
    config['generated_root'] = str(external(config['generated_root']))
    if 'source_root' in required:
        config['source_root'] = str(external(config['source_root']))
        if Path(config['generated_root']).is_relative_to(Path(config['source_root']) / 'bin'):
            raise ValueError('Generated output must not overlap source assets')
    if 'importer_root' in required:
        external(config['importer_root'])
    return config


def selected(args):
    if args.command.endswith('_group'):
        return list(GROUPS[args.selection])
    return [ALIASES.get(args.selection, args.selection)]


def tool_signature(config):
    digest = hashlib.sha256()
    for path in sorted(HERE.glob('*.py')):
        digest.update(path.name.encode())
        digest.update(path.read_bytes())
    importer = Path(config['importer_root']) / 'BlenderGR2rs'
    if not importer.is_dir():
        raise ValueError('Expected importer_root containing BlenderGR2rs')
    for path in sorted(importer.rglob('*')):
        if path.is_file() and path.suffix.lower() in ('.py', '.dll', '.so', '.dylib'):
            digest.update(path.relative_to(importer).as_posix().encode())
            digest.update(bytes.fromhex(sha256(path)))
    stat = Path(config['blender']).stat()
    digest.update(json.dumps([config['importer_revision'], stat.st_size, stat.st_mtime_ns]).encode())
    return digest.hexdigest()


def blender_run(config, work, request, timeout=180):
    work.mkdir(parents=True, exist_ok=True)
    result_path = work / 'result.json'
    result_path.unlink(missing_ok=True)
    request.update(importer_root=config['importer_root'], importer_revision=config['importer_revision'], result=str(result_path))
    request_path = work / 'request.json'
    write_json(request_path, request)
    with (work / 'blender.log').open('w', encoding='utf-8') as log:
        completed = subprocess.run([config['blender'], '--background', '--factory-startup', '--python-exit-code', '1',
            '--python', str(HERE / 'blender_export.py'), '--', str(request_path)],
            stdout=log, stderr=subprocess.STDOUT, timeout=timeout, check=False)
    if completed.returncode or not result_path.is_file():
        raise AssetFailure('IMPORT_FAILED', f'Blender exited {completed.returncode}; see {work / "blender.log"}')
    return json.loads(result_path.read_text(encoding='utf-8-sig'))


def prepare_bundles(index, ids, config, signature):
    bundles = [bundle_for(index, asset_id) for asset_id in ids]
    model_keys = sorted({key for bundle in bundles for key in (bundle.get('model_gr2'), bundle.get('hair')) if key and index.path(key)})
    work = Path(config['generated_root']) / '.pipeline/probes'
    metadata = {}
    missing = []
    for key in model_keys:
        stamp = hashlib.sha256((sha256(index.path(key)) + signature).encode()).hexdigest()
        cached = work / (stamp + '.json')
        if cached.is_file():
            metadata[key] = json.loads(cached.read_text())
        else:
            missing.append((key, cached))
    if missing:
        paths = {str(index.path(key)): key for key, _ in missing}
        try:
            results = blender_run(config, work, {'operation': 'probe', 'models': list(paths)})
        except (AssetFailure, subprocess.TimeoutExpired):
            # A native crash must not hide which model failed or stop the group.
            results = {}
            for path in paths:
                try:
                    results.update(blender_run(config, work / hashlib.sha256(path.encode()).hexdigest(),
                                               {'operation': 'probe', 'models': [path]}))
                except (AssetFailure, subprocess.TimeoutExpired) as error:
                    results[path] = {'error': 'IMPORT_FAILED: ' + str(error)}
        for key, cached in missing:
            metadata[key] = results.get(str(index.path(key)), {'error': 'IMPORT_FAILED: no probe result'})
            if 'error' not in metadata[key]:
                write_json(cached, metadata[key])
    for bundle in bundles:
        bundle['texture_files'] = {}
        bundle['native_metadata'] = {}
        for model in (bundle.get('model_gr2'), bundle.get('hair')):
            if model not in metadata:
                continue
            meta = metadata[model]
            bundle['native_metadata'][model] = meta
            if 'error' in meta:
                bundle['probe_error'] = meta['error']
                continue
            for ref in meta['textures']:
                normalized = virtual_path(ref)
                basename = Path(normalized).name
                override = bundle['texture_overrides'].get(basename)
                candidates = [override] if override else [normalized, str(Path(model).parent / basename).replace('\\', '/')]
                resolved = next((virtual_path(p) for p in candidates if p and index.path(p)), None)
                if resolved:
                    actual = str(index.path(resolved))
                    previous = bundle['texture_files'].get(basename)
                    if previous and previous != actual:
                        bundle['probe_error'] = 'UNKNOWN_LAYOUT: ambiguous texture basename ' + basename
                    bundle['texture_files'][basename] = actual
                    bundle['textures'].append(resolved)
                    bundle['source_paths'].append(resolved)
                else:
                    bundle['warnings'].append('MISSING_TEXTURE: ' + ref)
                    bundle.setdefault('missing_textures', []).append(ref)
        if bundle.get('texture_hint'):
            key = bundle['texture_hint']
            target = index.path(key)
            if target:
                bundle['texture_files'][Path(key).name] = str(target)
                bundle['textures'].append(key)
                bundle['source_paths'].append(key)
                bundle['warnings'].append('TEXTURE_HINT: explicit reference stone skin; native GR2 has no diffuse binding')
            else:
                bundle.setdefault('missing_textures', []).append(key)
        if bundle.get('hair_texture'):
            target = index.path(bundle['hair_texture'])
            bundle['hair_texture_file'] = str(target) if target else None
        bundle['source_paths'] = sorted(set(bundle['source_paths'] + ['npclist.txt']))
        bundle['textures'] = sorted(set(bundle['textures']))
    return bundles


def source_snapshot(index, bundle):
    # Hash actual dependencies on every conversion invocation. The index cannot
    # silently hide changed/deleted source files between explicit index runs.
    sources = []
    for key in bundle['source_paths']:
        record = index.record(key)
        if record is None:
            sources.append({'virtual_path': key, 'missing': True})
            continue
        path = index.source / record['relative_path']
        sources.append({'virtual_path': key, 'relative_path': record['relative_path'], 'pack': record['pack'],
                        'order': record['order'], 'sha256': sha256(path) if path.is_file() else None})
    registration = index.source / index.data['registration']
    if sha256(registration) != index.data['registration_sha256']:
        raise AssetFailure('IMPORT_FAILED', 'Index.dev changed; rebuild the asset index before converting')
    return sources


def fingerprint(bundle, sources, signature, index):
    return hashlib.sha256(json.dumps({'sources': sources, 'bundle': bundle, 'converter': signature,
        'registration': index.data['registration_sha256']}, sort_keys=True).encode()).hexdigest()


def convert_one(index, bundle, config, signature, force=False):
    root = Path(config['generated_root'])
    asset_id = bundle['id']
    output = root / relative_output(asset_id)
    manifest_path = output.with_suffix('.manifest.json')
    work = root / '.pipeline/jobs' / asset_id
    work.mkdir(parents=True, exist_ok=True)
    manifest = {'id': asset_id, 'timestamp': datetime.now(timezone.utc).isoformat(), 'bundle': bundle,
                'converter_signature': signature, 'importer_revision': config.get('importer_revision'),
                'warnings': bundle['warnings'], 'output': relative_output(asset_id)}
    try:
        sources = source_snapshot(index, bundle)
        stamp = fingerprint(bundle, sources, signature, index)
        manifest.update(source_files=sources, fingerprint=stamp)
        if not force and manifest_path.is_file() and output.is_file():
            prior = json.loads(manifest_path.read_text())
            if prior.get('status') == 'SUCCESS' and prior.get('fingerprint') == stamp and prior.get('output_sha256') == sha256(output):
                validate_glb(output)
                write_json(work / 'last_attempt.json', prior)
                return {'id': asset_id, 'status': 'SKIPPED', 'warnings': prior['warnings'], 'output': manifest['output']}
        model = index.path(bundle['model_gr2']) if bundle.get('model_gr2') else None
        if not model:
            status = 'MISSING_MODEL' if bundle.get('model_gr2') else 'UNKNOWN_LAYOUT'
            raise AssetFailure(status, 'no resolved model')
        if bundle.get('probe_error'):
            message = bundle['probe_error']
            status = next((s for s in DOMAIN_STATUSES if message.startswith(s + ':')), None)
            if status is None:
                raise RuntimeError(message)
            raise AssetFailure(status, message)
        if bundle.get('missing_textures') or not bundle['texture_files']:
            raise AssetFailure('MISSING_TEXTURE', 'unresolved diffuse textures')
        if bundle.get('hair') and not index.path(bundle['hair']):
            raise AssetFailure('MISSING_MODEL', 'hair')
        animation_files = {}
        for semantic, virtual in bundle['animations'].items():
            path = index.path(virtual) if virtual else None
            if not path:
                raise AssetFailure('MISSING_ANIMATION', semantic)
            animation_files[semantic] = str(path)
        if bundle['recipe'] != 'sword':
            for semantic in ('idle', 'run', 'hit', 'death'):
                if semantic not in animation_files:
                    raise AssetFailure('MISSING_ANIMATION', semantic)
            if not any(name.startswith('attack') for name in animation_files):
                raise AssetFailure('MISSING_ANIMATION', 'attack')
        temporary = work / (asset_id + '.glb')
        temporary.unlink(missing_ok=True)
        job = dict(bundle, model_file=str(model), animation_files=animation_files, temporary_output=str(temporary))
        if bundle.get('hair'):
            job['hair_file'] = str(index.path(bundle['hair']))
        result = blender_run(config, work, {'operation': 'convert', 'job': job})
        if result['status'] == 'PIPELINE_ERROR':
            raise RuntimeError(result.get('error', 'Blender orchestration error') + '\n' + result.get('traceback', ''))
        if result['status'] != 'SUCCESS':
            raise AssetFailure(result['status'], result.get('error', 'conversion failed'))
        try:
            validate_glb(temporary)
        except (OSError, ValueError) as error:
            raise AssetFailure('EXPORT_FAILED', str(error)) from error
        findings = result['findings']
        if any(max(clip['root_range'][:2]) > .01 for clip in findings['clips'].values()):
            manifest['warnings'].append('ROOT_MOTION: native planar translation; neutralized by VisualAnimationTools per instance')
        if bundle.get('animation_variants'):
            manifest['warnings'].append('MOTION_VARIANTS: first primary semantic selected; alternate weights/clips recorded, not exported')
        output.parent.mkdir(parents=True, exist_ok=True)
        os.replace(temporary, output)
        manifest.update(status='SUCCESS', findings=findings, output_sha256=sha256(output))
    except AssetFailure as error:
        manifest.update(status=error.status, error=str(error))
    except subprocess.TimeoutExpired as error:
        manifest.update(status='IMPORT_FAILED', error=str(error))
    except Exception as error:
        diagnostic = traceback.format_exc()
        (work / 'pipeline_error.log').write_text(diagnostic, encoding='utf-8')
        manifest.update(status='PIPELINE_ERROR', error=f'{type(error).__name__}: {error}', traceback=diagnostic)
    write_json(work / 'last_attempt.json', manifest)
    # Failed attempts must not claim an older successful GLB is current.
    if manifest['status'] == 'SUCCESS':
        write_json(manifest_path, manifest)
    return {k: manifest[k] for k in ('id', 'status', 'warnings', 'output')} | ({'error': manifest['error']} if 'error' in manifest else {})


def report_results(path, results):
    counts = dict(Counter(r['status'] for r in results))
    report = {'timestamp': datetime.now(timezone.utc).isoformat(), 'counts': counts,
              'assets_with_warnings': sum(bool(r['warnings']) for r in results), 'results': results}
    write_json(path, report)
    print(json.dumps({'report': str(path), 'counts': counts, 'assets_with_warnings': report['assets_with_warnings']}, indent=2))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=HERE / 'local.json')
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('index')
    query = commands.add_parser('query')
    for name in ('race', 'name', 'virtual_path', 'category', 'sha256', 'pack'):
        query.add_argument('--' + name.replace('_', '-'))
    query.add_argument('--limit', type=int, default=20)
    for command in ('resolve_asset', 'convert_asset', 'convert_group', 'stage_asset', 'stage_group'):
        sub = commands.add_parser(command)
        sub.add_argument('selection', choices=GROUPS if command.endswith('_group') else list(MOBS) + list(ARMORS) + list(SWORDS) + list(ALIASES))
        if command == 'resolve_asset':
            sub.add_argument('--native', action='store_true', help='Include native GR2 texture metadata; requires Blender/importer')
        if command == 'stage_group':
            sub.add_argument('--skip-failed', action='store_true', help='Stage successful selections; report failed selections without copying them')
        if command.startswith('convert'):
            sub.add_argument('--force', action='store_true')
    args = parser.parse_args()
    config = configuration(args.config, args.command, getattr(args, 'native', False))
    root = Path(config['generated_root'])
    index_path = root / '.pipeline/asset_index.json'
    if args.command == 'index':
        data = scan(config['source_root'], index_path)
        print(json.dumps({'index': str(index_path), 'files': len(data['files']), 'actors': len(data['actors']), 'counts': data['counts']}, indent=2))
        return 0
    if args.command.startswith('stage'):
        ids = selected(args)
        failures = []
        for asset_id in ids:
            try:
                relative = Path(relative_output(asset_id))
                manifest_path = (root / relative).with_suffix('.manifest.json')
                manifest = json.loads(manifest_path.read_text())
                latest = root / '.pipeline/jobs' / asset_id / 'last_attempt.json'
                if latest.is_file() and json.loads(latest.read_text()).get('status') != 'SUCCESS':
                    raise ValueError('Latest conversion failed; rerun before staging')
                if manifest['status'] != 'SUCCESS' or manifest['output_sha256'] != sha256(root / relative):
                    raise ValueError('No verified successful conversion')
                print(stage_relative_asset(relative, root))
            except (OSError, ValueError, KeyError) as error:
                failures.append({'id': asset_id, 'error': str(error)})
                if not getattr(args, 'skip_failed', False):
                    raise ValueError('Staging failed for ' + asset_id + ': ' + str(error))
        if failures:
            print(json.dumps({'not_staged': failures}, indent=2))
        return 0
    index = AssetIndex(json.loads(index_path.read_text()))
    if index.source != Path(config['source_root']):
        raise ValueError('Index belongs to a different configured source')
    if args.command == 'query':
        if args.race and (args.pack or args.sha256 or args.virtual_path):
            raise ValueError('Race queries use name/category; use file filters for pack/hash/virtual path')
        if args.race or (args.category in ('mob', 'npc') and not (args.pack or args.sha256 or args.virtual_path)):
            rows = index.data['actors']
            rows = [r for r in rows if (not args.race or str(r['race_id']) == args.race) and
                    (not args.category or r['category'] == args.category) and (not args.name or args.name.lower() in r['name'].lower())]
        else:
            rows = [dict(r, category=r.get('category', category_for(r['virtual_path']))) for r in index.files if (not args.category or r.get('category', category_for(r['virtual_path'])) == args.category) and (not args.name or args.name.lower() in Path(r['virtual_path']).name.lower()) and
                    all(not getattr(args, key) or r[key] == (virtual_path(getattr(args,key)) if key == 'virtual_path' else getattr(args,key))
                        for key in ('virtual_path','sha256','pack'))]
        print(json.dumps({'matches': len(rows), 'rows': rows[:args.limit]}, indent=2))
        return 0
    ids = selected(args)
    if args.command == 'resolve_asset' and not args.native:
        print(json.dumps(bundle_for(index, ids[0]), indent=2))
        return 0
    signature = tool_signature(config)
    bundles = prepare_bundles(index, ids, config, signature)
    if args.command == 'resolve_asset':
        print(json.dumps(bundles[0], indent=2))
        return 0
    results = []
    for bundle in bundles:
        result = convert_one(index, bundle, config, signature, args.force)
        results.append(result)
        print(bundle['id'] + ': ' + result['status'], flush=True)
        report_results(root / '.pipeline/reports' / (args.selection + '.json'), results)
    return 1 if any(r['status'] not in ('SUCCESS', 'SKIPPED') for r in results) else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print('Pipeline failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
