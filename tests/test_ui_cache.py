"""Synthetic pixel fixtures only; no third-party artwork is needed."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image

spec = importlib.util.spec_from_file_location('export_ui', Path(__file__).parents[1] / 'tools/dev_assets/export_ui.py')
ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ui)


class UICacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'external-ui'
        self.repo = self.root / 'game'
        self.source.mkdir()
        self.repo.mkdir()
        self.image = Image.new('RGBA', (8, 6))
        self.image.putdata([(x * 29, y * 41, (x+y)*17, (x*37+y*19)%256) for y in range(6) for x in range(8)])
        self.image.save(self.source / 'Texture.tga')

    def sub(self, name='public/slot.sub', version='1.0', image='Texture.tga', rect=(1, 2, 5, 6)):
        path = self.source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        text = f'title subImage\nversion {version}\nimage "{image}"\n'
        text += '\n'.join(f'{key} {value}' for key, value in zip(('left', 'top', 'right', 'bottom'), rect))
        path.write_text(text, encoding='utf-8')
        return name

    def export(self, *names):
        return ui.export_selected(self.source, names, self.repo)

    def pixels(self, name, expected):
        with Image.open(self.repo / ui.CACHE / (name+'.png')) as image:
            self.assertEqual(image.size, expected.size)
            self.assertEqual(image.mode, 'RGBA')
            self.assertEqual(image.tobytes(), expected.tobytes())

    def test_v1_search_root_exclusive_bounds_and_original_manifest(self):
        name = self.sub(image='texture.TGA')
        # A same-name image next to .sub must not override the v1 search root.
        Image.new('RGBA', (8, 6), 'red').save(self.source / 'public/Texture.tga')
        self.assertEqual(self.export(name)[0]['status'], 'EXPORTED')
        self.pixels(name, self.image.crop((1, 2, 5, 6)))
        record = json.loads((self.repo/ui.CACHE/'manifest.json').read_text())['assets'][name]
        self.assertEqual(record['texture_path'], 'Texture.tga')
        self.assertEqual(record['sub']['image'], 'texture.TGA')
        self.assertEqual(record['source_path'], name)
        self.assertEqual(record['rect'], [1, 2, 5, 6])
        self.assertEqual(record['size'], [4, 4])

    def test_v2_relative_image_and_windows_separators(self):
        (self.source/'nested/images').mkdir(parents=True)
        self.image.save(self.source/'nested/images/local.tga')
        name = self.sub('nested/button.sub', version='2.0', image=r'images\local.tga')
        self.assertEqual(self.export(name)[0]['status'], 'EXPORTED')
        self.pixels(name, self.image.crop((1, 2, 5, 6)))

    def test_standalone_tga_and_dds_preserve_every_rgba_pixel(self):
        self.image.save(self.source/'Texture.dds')
        result = self.export('Texture.tga', 'Texture.dds')
        self.assertEqual([r['status'] for r in result], ['EXPORTED', 'EXPORTED'])
        self.pixels('Texture.tga', self.image)
        self.pixels('Texture.dds', self.image)

    def test_cache_revalidates_changed_source_and_modified_png(self):
        name = self.sub()
        self.assertEqual(self.export(name)[0]['status'], 'EXPORTED')
        self.assertEqual(self.export(name)[0]['status'], 'CACHED')
        self.image.putpixel((1, 2), (255, 0, 100, 0))
        self.image.save(self.source/'Texture.tga')
        self.assertEqual(self.export(name)[0]['status'], 'EXPORTED')
        self.pixels(name, self.image.crop((1, 2, 5, 6)))
        (self.repo/ui.CACHE/(name+'.png')).write_bytes(b'corrupted')
        self.assertEqual(self.export(name)[0]['status'], 'EXPORTED')
        self.pixels(name, self.image.crop((1, 2, 5, 6)))
        self.sub(rect=(0, 0, 1, 1))
        self.assertEqual(self.export(name)[0]['status'], 'EXPORTED')
        self.pixels(name, self.image.crop((0, 0, 1, 1)))

    def test_invalid_rectangle_does_not_pad_or_overwrite_previous_output(self):
        name = self.sub()
        self.export(name)
        target = self.repo/ui.CACHE/(name+'.png')
        manifest = self.repo/ui.CACHE/'manifest.json'
        previous, metadata = target.read_bytes(), manifest.read_bytes()
        for rect in ((-1, 0, 4, 4), (0, 0, 9, 6), (0, 0, 8, 7), (2, 1, 2, 5)):
            self.sub(rect=rect)
            self.assertEqual(self.export(name)[0]['status'], 'FAILED')
            self.assertEqual(target.read_bytes(), previous)
            self.assertEqual(manifest.read_bytes(), metadata)

    def test_failed_png_write_keeps_previous_output_and_removes_temporary_file(self):
        name = self.sub()
        self.export(name)
        cache = self.repo/ui.CACHE
        target, manifest = cache/(name+'.png'), cache/'manifest.json'
        previous, metadata = target.read_bytes(), manifest.read_bytes()
        self.sub(rect=(0, 0, 2, 2))
        with patch.object(Image.Image, 'save', side_effect=OSError('simulated disk write failure')):
            self.assertEqual(self.export(name)[0]['status'], 'FAILED')
        self.assertEqual(target.read_bytes(), previous)
        self.assertEqual(manifest.read_bytes(), metadata)
        self.assertEqual(list(cache.rglob('.ui-*.tmp')), [])
    def test_parser_rejects_duplicate_fields_unknown_version_and_missing_fields(self):
        with self.assertRaises(ValueError):
            ui.parse_sub('title subImage\nversion 3.0')
        name = self.sub()
        path = self.source/name
        path.write_text(path.read_text()+'\nleft 0')
        self.assertEqual(self.export(name)[0]['status'], 'FAILED')

    def test_traversal_external_source_requirement_and_explicit_selection(self):
        for image in ('../Texture.tga', 'D:/Texture.tga', '/Texture.tga'):
            name = self.sub(image=image)
            self.assertEqual(self.export(name)[0]['status'], 'FAILED')
        self.assertEqual(self.export('../outside.tga')[0]['status'], 'FAILED')
        self.assertEqual(self.export('Texture.tga')[0]['status'], 'EXPORTED')
        self.assertEqual(len(list((self.repo/ui.CACHE).rglob('*.png'))), 1)
        with self.assertRaises(ValueError):
            ui.export_selected(self.repo, ['anything.tga'], self.repo)

    def test_source_and_destination_links_cannot_escape_boundaries(self):
        outside = self.root/'outside'
        outside.mkdir()
        self.image.save(outside/'secret.tga')
        try:
            (self.source/'escape.tga').symlink_to(outside/'secret.tga')
        except OSError:
            self.skipTest('Creating symbolic links is unavailable')
        self.assertEqual(self.export('escape.tga')[0]['status'], 'FAILED')
        cache = self.repo/ui.CACHE
        cache.parent.mkdir(parents=True)
        cache.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.export('Texture.tga')
        self.assertFalse((outside/'Texture.tga.png').exists())


if __name__ == '__main__':
    unittest.main()
