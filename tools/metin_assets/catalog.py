"""Explicit first-batch selection; no convert-all or stage-all command."""
MOBS = {
    'stray_dog': 101, 'wolf': 102, 'wild_boar': 108, 'bear': 110, 'tiger': 114,
    'barbarian_soldier': 502, 'barbarian_infantry': 501, 'barbarian_bow': 503,
    'orc_soldier': 601, 'orc_scouter': 602, 'orc_knight': 603,
    'orc_black': 636, 'orc_magician': 604,
    'metinstone_01': 8001, 'metinstone_02': 8002,
}
ARMORS = {'warrior': 'warrior_novice', 'warrior_armor': 'warrior_nahan',
          'warrior_saja': 'warrior_saja', 'warrior_cheongrin': 'warrior_cheongrin'}
SWORDS = {'iron_sword': '00010', 'sword_00020': '00020', 'sword_00030': '00030', 'sword_00040': '00040'}
GROUPS = {
    'mobs_m1': list(MOBS)[:8], 'orcs': list(MOBS)[8:13], 'metin_stones': list(MOBS)[13:],
    'warrior_male': list(ARMORS), 'basic_swords': list(SWORDS),
}
GROUPS['first_batch'] = list(MOBS) + list(ARMORS) + list(SWORDS)
ALIASES = {'warrior_male': 'warrior', 'boar': 'wild_boar'}


def relative_output(asset_id):
    asset_id = ALIASES.get(asset_id, asset_id)
    if asset_id in MOBS:
        return f'mobs/{asset_id}/{asset_id}.glb'
    if asset_id in ARMORS:
        return f'players/warrior/{asset_id}.glb'
    if asset_id in SWORDS:
        return f'weapons/{asset_id}/{asset_id}.glb'
    raise ValueError(f'Unsupported selected asset: {asset_id}')


def bundle_for(index, asset_id):
    from asset_index import actor_bundle
    asset_id = ALIASES.get(asset_id, asset_id)
    if asset_id in MOBS:
        # Race IDs are checked against npclist; use its actual name, never infer a model from the ID.
        actors = index.data['actors']
        actor = next((a for a in actors if a['race_id'] == MOBS[asset_id] and a['name'] == asset_id), None)
        if actor is None:
            actor = next((a for a in actors if a['name'] == asset_id and a['msm']), None)
        if actor is None:
            return {'id': asset_id, 'name': asset_id, 'model_gr2': None, 'warnings': ['UNKNOWN_LAYOUT: absent from npclist'],
                    'source_paths': [], 'animations': {}, 'textures': [], 'texture_overrides': {}, 'category': 'mob'}
        bundle = actor_bundle(index, actor)
        bundle['recipe'] = 'mob'
        if asset_id in ('metinstone_01', 'metinstone_02'):
            # These GR2 files contain geometry, but no native diffuse binding.
            # The known client skin is explicit; never guess arbitrary DDS files.
            bundle['texture_hint'] = bundle['actor_directory'] + '/' + asset_id + '.dds'
    else:
        base = 'ymir work/pc/warrior'
        model = base + '/' + ARMORS[asset_id] + '.gr2' if asset_id in ARMORS else 'ymir work/item/weapon/' + SWORDS[asset_id] + '.gr2'
        bundle = {'id': asset_id, 'name': asset_id, 'model_gr2': model, 'skeleton_source': model,
                  'lods': [], 'textures': [], 'source_paths': [model], 'animations': {}, 'texture_overrides': {},
                  'warnings': [], 'recipe': 'warrior' if asset_id in ARMORS else 'sword',
                  'category': 'player' if asset_id in ARMORS else 'weapon'}
        if asset_id in ARMORS:
            bundle['hair'] = base + '/hair/hair_1_1.gr2'
            bundle['texture_overrides']['hair_1_1.dds'] = base + '/warrior_hair_01.dds'
            bundle['hair_texture'] = base + '/warrior_hair_01.dds'
            bundle['source_paths'].extend([bundle['hair'], bundle['hair_texture']])
            for semantic, relative in [('idle','onehand_sword/wait'), ('run','onehand_sword/run'),
                    ('attack_1','onehand_sword/combo_01'), ('attack_2','onehand_sword/combo_02'),
                    ('attack_3','onehand_sword/combo_03'), ('hit','onehand_sword/damage'), ('death','general/dead')]:
                bundle['animations'][semantic] = base + '/' + relative + '.gr2'
                bundle['source_paths'].extend([base + '/' + relative + '.gr2', base + '/' + relative + '.msa'])
    bundle['output'] = relative_output(asset_id)
    return bundle
