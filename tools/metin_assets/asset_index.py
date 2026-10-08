"""Local source index. Text dependency discovery reuses the single-asset scanner.
GR2 contents are inspected exclusively through BlenderGR2rs, in Blender.
"""
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path, PurePosixPath
import re

REPO = Path(__file__).resolve().parents[2]


def virtual_path(value):
    value = value.replace('\\', '/').strip().lower()
    value = re.sub(r'^[a-z]:/', '', value)
    while value.startswith('./'):
        value = value[2:]
    value = value.lstrip('/')
    if '..' in PurePosixPath(value).parts:
        raise ValueError('Parent traversal in virtual path')
    return PurePosixPath(value).as_posix()


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def external(path):
    path = Path(path).resolve()
    if path.is_relative_to(REPO) or REPO.is_relative_to(path):
        raise ValueError('Legacy source/cache must be separate from the Godot project')
    return path


def write_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(data, ensure_ascii=True, indent=2), encoding='utf-8')
    temporary.replace(path)


def read_text(path):
    return Path(path).read_text(encoding='utf-8-sig', errors='replace')


def field(text, name):
    match = re.search(r'^\s*' + re.escape(name) + r'\s+(?:"([^"]*)"|([^\r\n]+))', text, re.M | re.I)
    return (match.group(1) if match.group(1) is not None else match.group(2).strip()) if match else None


def category_for(path):
    path = virtual_path(path)
    if path.startswith(('ymir work/pc/', 'ymir work/pc2/')):
        return 'player'
    if path.startswith(('ymir work/monster/', 'ymir work/monster2/')):
        return 'mob'
    if path.startswith('ymir work/item/weapon/'):
        return 'weapon'
    if path.startswith(('ymir work/npc/', 'ymir work/npc2/')):
        return 'npc'
    return 'other'


def scan(source, destination):
    source = external(source)
    destination = external(destination)
    pack = source / 'bin/pack'
    registration = pack / 'Index.dev'
    if not registration.is_file():
        raise ValueError('Expected unpacked bin/pack with Index.dev (FOLDER registration)')
    directories = {p.name.lower(): p for p in pack.iterdir() if p.is_dir()}
    providers = []
    registered = set()
    for line in read_text(registration).splitlines():
        tokens = line.split()
        if len(tokens) != 2:
            continue
        name, kind = tokens
        name = name.lower()
        if name in registered:
            continue  # RegisterPack ignores a second registration of the same name.
        if kind.upper() != 'FOLDER':
            raise ValueError('Index.dev must register unpacked FOLDER providers')
        registered.add(name)
        for candidate in (name, name + '_texcache'):
            providers.append({'pack': candidate, 'order': len(providers),
                              'registered': True, 'present': candidate in directories})
    for name in sorted(set(directories) - {p['pack'] for p in providers}):
        providers.append({'pack': name, 'order': len(providers), 'registered': False, 'present': True})
    files = []
    winners = {}
    groups = defaultdict(list)
    for provider in providers:
        directory = directories.get(provider['pack'])
        if directory is None:
            continue
        if directory.is_symlink() or directory.is_junction():
            raise ValueError('Linked pack provider is not supported')
        paths = []
        for parent, folders, names in directory.walk(follow_symlinks=False):
            folders[:] = sorted(n for n in folders if not (parent/n).is_symlink() and not (parent/n).is_junction())
            paths.extend(parent/n for n in sorted(names) if not (parent/n).is_symlink() and not (parent/n).is_junction())
        for path in sorted(paths):
            key = virtual_path(path.relative_to(directory).as_posix())
            stat = path.stat()
            record = {'relative_path': path.relative_to(source).as_posix(), 'virtual_path': key,
                      'pack': provider['pack'], 'order': provider['order'],
                      'registered': provider['registered'], 'type': path.suffix.lower(), 'category': category_for(key),
                      'size': stat.st_size, 'mtime_ns': stat.st_mtime_ns, 'sha256': sha256(path)}
            record['selected'] = provider['registered'] and key not in winners
            record['duplicate_group'] = record['sha256']
            if record['selected']:
                winners[key] = len(files)
            groups[record['sha256']].append(len(files))
            files.append(record)
    index = {'schema': 1, 'source': str(source), 'registration': 'bin/pack/Index.dev',
             'registration_sha256': sha256(registration), 'priority': 'first-registered-path-wins',
             'providers': providers, 'files': files, 'winners': winners,
             'duplicate_groups': {digest: ids for digest, ids in groups.items() if len(ids) > 1},
             'counts': dict(Counter(f['type'] for f in files))}
    lookup = AssetIndex(index)
    index['actors'] = discover_actors(lookup)
    write_json(destination, index)
    return index


class AssetIndex:
    def __init__(self, data):
        self.data = data
        self.source = external(data['source'])
        self.files = data['files']
        self.winners = data['winners']

    def record(self, path):
        key = virtual_path(path)
        return self.files[self.winners[key]] if key in self.winners else None

    def path(self, path):
        record = self.record(path)
        if record is None:
            return None
        result = (self.source / record['relative_path']).resolve()
        if not result.is_relative_to(self.source):
            raise ValueError('Source entry escapes configured root')
        return result if result.is_file() else None

    def text(self, path):
        resolved = self.path(path)
        return read_text(resolved) if resolved else ''


def race_roots(race):
    # Mirrors GameLib/RaceManager.cpp __GetRaceResourcePathes, including exceptions.
    if 14000 <= race < 15000 or race == 20043:
        return ['guild', 'npc', 'npc2', 'monster', 'monster2']
    if race >= 30000:
        return ['npc2', 'npc', 'monster', 'monster2', 'guild']
    if race > 9000:
        return ['npc', 'npc2', 'monster', 'monster2', 'guild']
    if race in (8507, 8510) or 2000 < race <= 8000 or 1400 <= race <= 1700:
        return ['monster2', 'monster', 'npc', 'npc2', 'guild']
    return ['monster', 'monster2', 'npc', 'npc2', 'guild']


def discover_actors(index):
    aliases = {}
    races = {}
    for line in index.text('npclist.txt').splitlines():
        parts = line.split()
        if len(parts) < 2 or not parts[0].isdigit():
            continue
        race, name = int(parts[0]), parts[1]
        if race == 0 and len(parts) >= 3:
            aliases.setdefault(name, parts[2])
        elif race:
            races.setdefault(race, name)
    result = []
    for race, name in sorted(races.items()):
        msm = None
        if not name.startswith('#'):
            for root in race_roots(race):
                candidate = f'ymir work/{root}/{aliases.get(name, name)}/{name}.msm'
                if index.record(candidate):
                    msm = candidate
                    break
        result.append({'race_id': race, 'name': name, 'msm': msm,
                       'category': 'npc' if race > 9000 else 'mob',
                       'warnings': [] if msm else ['UNKNOWN_LAYOUT: no supported MSM path']})
    return result


SEMANTICS = {'WAIT': 'idle', 'WALK': 'walk', 'RUN': 'run', 'NORMAL_ATTACK': 'attack',
             'FRONT_DAMAGE': 'hit', 'FRONT_DEAD': 'death', 'DEAD': 'death', 'SPAWN': 'spawn'}


def actor_bundle(index, actor):
    name = actor['name']
    bundle = {'id': name, 'name': name, 'race_id': actor['race_id'], 'category': actor['category'],
              'model_gr2': None, 'lods': [], 'textures': [], 'skeleton_source': None,
              'animations': {}, 'animation_variants': [], 'source_paths': [], 'warnings': list(actor['warnings']),
              'texture_overrides': {}}
    msm = actor.get('msm')
    if not msm:
        return bundle
    text = index.text(msm)
    directory = str(PurePosixPath(msm).parent)
    model = field(text, 'BaseModelFileName')
    if model:
        model = virtual_path(model) if ':' in model or 'ymir work' in model.lower() else virtual_path(directory + '/' + model)
    bundle.update(model_gr2=model, skeleton_source=model, actor_directory=directory)
    bundle['source_paths'].append(msm)
    path_name = field(text, 'PathName') or directory
    source_skin = field(text, 'SourceSkin')
    target_skin = field(text, 'TargetSkin')
    if source_skin and target_skin:
        target = virtual_path(target_skin) if ':' in target_skin else virtual_path(path_name + '/' + target_skin)
        bundle['texture_overrides'][PurePosixPath(virtual_path(source_skin)).name] = target
        bundle['textures'].append(target)
    if model:
        bundle['source_paths'].append(model)
        bundle['lods'] = [key for key in index.winners if key.startswith(model[:-4] + '_lod_') and key.endswith('.gr2')]
    motlist = virtual_path(directory + '/' + (field(text, 'MotionListFileName') or 'motlist.txt'))
    if index.record(motlist):
        bundle['source_paths'].append(motlist)
        for line in index.text(motlist).splitlines():
            parts = line.split()
            if len(parts) < 4:
                continue
            mode, state, msa, weight = parts[:4]
            msa = virtual_path(directory + '/' + msa)
            gr2 = field(index.text(msa), 'MotionFileName')
            if gr2:
                gr2 = virtual_path(gr2) if ':' in gr2 or 'ymir work' in gr2.lower() else virtual_path(directory + '/' + gr2)
            entry = {'mode': mode, 'state': state, 'msa': msa, 'gr2': gr2, 'weight': weight,
                     'duration': field(index.text(msa), 'MotionDuration')}
            bundle['animation_variants'].append(entry)
            semantic = SEMANTICS.get(state)
            if semantic and semantic not in bundle['animations']:
                bundle['animations'][semantic] = gr2
                bundle['source_paths'].extend([msa] + ([gr2] if gr2 else []))
    if not bundle['animations']:
        bundle['warnings'].append('MISSING_ANIMATION: no motlist motions resolved')
    return bundle
