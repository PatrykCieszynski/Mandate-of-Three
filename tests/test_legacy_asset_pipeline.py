"""No legacy assets/Blender needed. Real index, priority, dependency and cache fixtures."""
import copy
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools/legacy_assets'))
import asset_index
from asset_index import AssetIndex, actor_bundle, scan, sha256, virtual_path, write_json
import pipeline
from filesystem_assertions import assert_same_files
from stage_asset import stage_relative_asset


def glb(path):
    data = json.dumps({'asset': {'version': '2.0'}}).encode()
    data += b' ' * (-len(data) % 4)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(struct.pack('<IIIII', 0x46546C67, 2, 20+len(data), len(data), 0x4E4F534A) + data)


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'legacy'
        self.pack = self.source / 'bin/pack'
        self.generated = self.root / 'generated'
        self.generated.mkdir()
        self.put('Index.dev', 'patch FOLDER\nbase FOLDER\nroot FOLDER\n')
        self.put('root/npclist.txt', '0 blue dog\n101 dog\n102 blue\n')
        self.put('base/ymir work/monster/dog/dog.msm', 'BaseModelFileName "d:/ymir work/monster/dog/dog.gr2"\n')
        self.put('base/ymir work/monster/dog/blue.msm', 'BaseModelFileName "d:/ymir work/monster/dog/dog.gr2"\nPathName "d:/ymir work/monster/dog/"\nSourceSkin "dog.dds"\nTargetSkin "blue.dds"\n')
        self.put('base/ymir work/monster/dog/dog.gr2', 'base-model')
        self.put('patch/ymir work/monster/dog/dog.gr2', 'winning-patch')
        self.put('unregistered/ymir work/monster/dog/dog.gr2', 'unregistered')
        self.put('base/ymir work/monster/dog/copy.gr2', 'winning-patch')
        self.put('base/ymir work/monster/dog/dog.dds', 'texture')
        self.put('base/ymir work/monster/dog/blue.dds', 'blue')
        self.put('base/ymir work/monster/dog/motlist.txt', '\n'.join('GENERAL ' + state + ' ' + str(i) + '.msa 100' for i,state in enumerate(('WAIT','RUN','NORMAL_ATTACK','FRONT_DAMAGE','FRONT_DEAD'))))
        for i in range(5):
            self.put(f'base/ymir work/monster/dog/{i}.msa', f'MotionFileName "d:/ymir work/monster/dog/{i}.gr2"\nMotionDuration 1.0')
            self.put(f'base/ymir work/monster/dog/{i}.gr2', 'motion' + str(i))
        self.index = AssetIndex(scan(self.source, self.generated / 'index.json'))
        actor = next(a for a in self.index.data['actors'] if a['race_id'] == 101)
        self.bundle = actor_bundle(self.index, actor)
        self.bundle.update(id='stray_dog', recipe='mob', texture_files={'dog.dds': str(self.index.path('ymir work/monster/dog/dog.dds'))})
        self.bundle['source_paths'].append('ymir work/monster/dog/dog.dds')
        self.config = {'generated_root': str(self.generated), 'importer_revision': 'fixture'}

    def put(self, path, content):
        target = self.pack / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
        return target

    def fake_export(self, config, work, request):
        glb(Path(request['job']['temporary_output']))
        return {'status': 'SUCCESS', 'findings': {'clips': {}}}

    def convert(self, bundle=None, signature='v1', force=False):
        return pipeline.convert_one(self.index, copy.deepcopy(bundle or self.bundle), self.config, signature, force)

    def test_first_registered_wins_without_losing_duplicates(self):
        records = [r for r in self.index.files if r['virtual_path'] == 'ymir work/monster/dog/dog.gr2']
        self.assertEqual(len(records), 3)
        self.assertEqual([r['pack'] for r in records if r['selected']], ['patch'])
        digest = sha256(self.index.path('ymir work/monster/dog/dog.gr2'))
        self.assertEqual(len(self.index.data['duplicate_groups'][digest]), 2)
        self.assertEqual(virtual_path('D:\\Ymir Work\\Monster\\Dog\\Dog.GR2'), 'ymir work/monster/dog/dog.gr2')
        with self.assertRaises(ValueError):
            virtual_path('../escape')

    def test_actor_alias_and_msa_dependencies(self):
        actor = next(a for a in self.index.data['actors'] if a['race_id'] == 102)
        bundle = actor_bundle(self.index, actor)
        self.assertEqual(bundle['texture_overrides'], {'dog.dds': 'ymir work/monster/dog/blue.dds'})
        self.assertEqual(set(bundle['animations']), {'idle','run','attack','hit','death'})
        self.assertIn('ymir work/monster/dog/4.msa', bundle['source_paths'])

    def test_resume_source_converter_force_and_corrupt_output(self):
        with patch.object(pipeline, 'blender_run', side_effect=self.fake_export) as exporter:
            self.assertEqual(self.convert()['status'], 'SUCCESS')
            self.assertEqual(self.convert()['status'], 'SKIPPED')
            self.assertEqual(exporter.call_count, 1)
            self.put('patch/ymir work/monster/dog/dog.gr2', 'changed-model')
            self.assertEqual(self.convert()['status'], 'SUCCESS')
            self.assertEqual(self.convert(signature='v2')['status'], 'SUCCESS')
            self.assertEqual(self.convert(signature='v2', force=True)['status'], 'SUCCESS')
            output = self.generated / 'mobs/stray_dog/stray_dog.glb'
            output.write_bytes(b'corrupt')
            self.assertEqual(self.convert(signature='v2')['status'], 'SUCCESS')
            self.assertEqual(exporter.call_count, 5)

    def test_partial_failure_preserves_previous_good_output(self):
        with patch.object(pipeline, 'blender_run', side_effect=self.fake_export):
            self.assertEqual(self.convert()['status'], 'SUCCESS')
        output = self.generated / 'mobs/stray_dog/stray_dog.glb'
        prior = output.read_bytes()
        broken = copy.deepcopy(self.bundle)
        broken['animations']['attack'] = 'missing.gr2'
        with patch.object(pipeline, 'blender_run', side_effect=self.fake_export):
            results = [self.convert(broken), self.convert(force=True)]
        self.assertEqual([r['status'] for r in results], ['MISSING_ANIMATION','SUCCESS'])
        self.assertEqual(output.read_bytes(), prior)
        missing = copy.deepcopy(self.bundle)
        missing['model_gr2'] = 'missing.gr2'
        self.assertEqual(self.convert(missing)['status'], 'MISSING_MODEL')

    def test_failed_export_and_changed_registration_are_not_cached(self):
        with patch.object(pipeline, 'blender_run', return_value={'status': 'INVALID_SKELETON', 'error': 'bad binding'}):
            self.assertEqual(self.convert()['status'], 'INVALID_SKELETON')
        self.put('Index.dev', 'base FOLDER\npatch FOLDER\nroot FOLDER\n')
        self.assertEqual(self.convert()['status'], 'IMPORT_FAILED')
        with self.assertRaises(ValueError):
            asset_index.external(asset_index.REPO / 'dev_assets')

    def test_deleted_texture_is_reported_before_export(self):
        texture = self.index.path('ymir work/monster/dog/dog.dds')
        texture.unlink()
        model = str(self.index.path(self.bundle['model_gr2']))
        with patch.object(pipeline, 'bundle_for', return_value=copy.deepcopy(self.bundle)), patch.object(pipeline, 'blender_run', return_value={model: {'textures': ['dog.dds']}}):
            bundles = pipeline.prepare_bundles(self.index, ['stray_dog'], self.config, 'fixture')
        self.assertEqual(bundles[0]['missing_textures'], ['dog.dds'])
        self.assertEqual(self.convert(bundles[0])['status'], 'MISSING_TEXTURE')

    def test_lazy_configuration_and_source_free_staging(self):
        config_path = self.root / 'local.json'
        config_path.write_text(json.dumps({'generated_root': str(self.generated),
            'source_root': 'not-installed', 'blender': 'not-installed', 'importer_root': 'not-installed'}))
        with patch.dict(os.environ, {}, clear=True):
            config = pipeline.configuration(config_path, 'stage_asset')
            self.assertTrue(os.path.samefile(config['generated_root'], self.generated))
            with self.assertRaises((OSError, ValueError)):
                pipeline.configuration(config_path, 'convert_asset')
        with patch.object(pipeline, 'blender_run', side_effect=self.fake_export):
            self.assertEqual(self.convert()['status'], 'SUCCESS')
        repo = self.root / 'stage-only-game'
        repo.mkdir()
        with patch.dict(os.environ, {}, clear=True), patch.object(sys, 'argv', ['pipeline', '--config', str(config_path), 'stage_asset', 'stray_dog']), patch.object(pipeline, 'stage_relative_asset', side_effect=lambda relative, root: stage_relative_asset(relative, root, repo)), patch.object(pipeline, 'blender_run', side_effect=AssertionError('Staging must not launch Blender')):
            # No asset_index.json is present; source_root/tools are deliberately invalid.
            self.assertEqual(pipeline.main(), 0)
        self.assertTrue((repo / 'dev_assets/legacy/mobs/stray_dog/stray_dog.glb').exists())

    def test_index_query_and_basic_resolution_do_not_require_native_tools(self):
        config_path = self.root / 'local.json'
        config_path.write_text(json.dumps({'source_root': str(self.source), 'generated_root': str(self.generated)}))
        with patch.dict(os.environ, {}, clear=True):
            for command in ('index', 'query', 'resolve_asset'):
                config = pipeline.configuration(config_path, command)
                self.assertNotIn('blender', config)
            with self.assertRaisesRegex(ValueError, 'blender'):
                pipeline.configuration(config_path, 'resolve_asset', native=True)
            with patch.object(sys, 'argv', ['pipeline', '--config', str(config_path), 'index']):
                self.assertEqual(pipeline.main(), 0)
            with patch.object(pipeline, 'blender_run', side_effect=AssertionError('Read-only commands must not launch Blender')):
                with patch.object(sys, 'argv', ['pipeline', '--config', str(config_path), 'query', '--race', '101']):
                    self.assertEqual(pipeline.main(), 0)
                with patch.object(sys, 'argv', ['pipeline', '--config', str(config_path), 'resolve_asset', 'stray_dog']), patch.object(pipeline, 'bundle_for', return_value=copy.deepcopy(self.bundle)):
                    self.assertEqual(pipeline.main(), 0)

    def test_unexpected_pipeline_error_is_visible_and_group_continues(self):
        write_json(self.generated / '.pipeline/asset_index.json', self.index.data)
        other = copy.deepcopy(self.bundle)
        other['id'] = 'wolf'
        def exporter(config, work, request):
            if request['job']['id'] == 'stray_dog':
                raise TypeError('unexpected orchestration bug')
            return self.fake_export(config, work, request)
        config = self.config | {'source_root': str(self.source)}
        with patch.object(sys, 'argv', ['pipeline', 'convert_group', 'mobs_m1']), patch.object(pipeline, 'configuration', return_value=config), patch.object(pipeline, 'tool_signature', return_value='fixture'), patch.object(pipeline, 'prepare_bundles', return_value=[copy.deepcopy(self.bundle), other]), patch.object(pipeline, 'blender_run', side_effect=exporter):
            self.assertEqual(pipeline.main(), 1)
        report = json.loads((self.generated / '.pipeline/reports/mobs_m1.json').read_text())
        self.assertEqual(report['counts'], {'PIPELINE_ERROR': 1, 'SUCCESS': 1})
        job = self.generated / '.pipeline/jobs/stray_dog'
        self.assertIn('TypeError: unexpected orchestration bug', (job / 'pipeline_error.log').read_text())
        self.assertIn('Traceback', json.loads((job / 'last_attempt.json').read_text())['traceback'])

    def test_malformed_result_keeps_last_known_good_glb(self):
        with patch.object(pipeline, 'blender_run', side_effect=self.fake_export):
            self.assertEqual(self.convert()['status'], 'SUCCESS')
        output = self.generated / 'mobs/stray_dog/stray_dog.glb'
        before = output.read_bytes()
        def malformed(config, work, request):
            self.fake_export(config, work, request)
            return {'status': 'SUCCESS'}  # Internal protocol bug: findings absent.
        with patch.object(pipeline, 'blender_run', side_effect=malformed):
            self.assertEqual(self.convert(force=True)['status'], 'PIPELINE_ERROR')
        self.assertEqual(output.read_bytes(), before)
        manifest = json.loads(output.with_suffix('.manifest.json').read_text())
        self.assertEqual(manifest['status'], 'SUCCESS')

    def test_child_pipeline_error_is_not_an_asset_import_failure(self):
        with patch.object(pipeline, 'blender_run', return_value={'status': 'PIPELINE_ERROR', 'error': 'child protocol bug', 'traceback': 'Child traceback: KeyError'}):
            self.assertEqual(self.convert()['status'], 'PIPELINE_ERROR')
        diagnostic = (self.generated / '.pipeline/jobs/stray_dog/pipeline_error.log').read_text()
        self.assertIn('Child traceback: KeyError', diagnostic)

    def test_explicit_relative_staging_and_escape(self):
        relative = Path('mobs/wolf/wolf.glb')
        glb(self.generated / relative)
        repo = self.root / 'game'
        repo.mkdir()
        stage_relative_asset(relative, self.generated, repo)
        assert_same_files(self, (repo / 'dev_assets').rglob('*.glb'), [repo / 'dev_assets/legacy' / relative])
        with self.assertRaises(ValueError):
            stage_relative_asset(Path('../escape.glb'), self.generated, repo)
        with self.assertRaises(ValueError):
            stage_relative_asset(Path('mobs/wolf/wolf.dds'), self.generated, repo)


if __name__ == '__main__':
    unittest.main()
