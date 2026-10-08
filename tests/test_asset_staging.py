import importlib.util
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest

from filesystem_assertions import assert_same_files

spec = importlib.util.spec_from_file_location("stage_asset", Path(__file__).parents[1] / "tools/dev_assets/stage_asset.py")
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)


def glb(metadata):
    data = json.dumps(metadata).encode()
    data += b" " * (-len(data) % 4)
    return struct.pack("<IIIII", 0x46546C67, 2, 20 + len(data), len(data), 0x4E4F534A) + data


class StagingTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "project"
        self.repo.mkdir()
        self.generated = self.root / "external/generated"
        self.source = self.generated / stage.ASSETS["stray_dog"]
        self.source.parent.mkdir(parents=True)
        self.source.write_bytes(glb({"asset": {"version": "2.0"}}))

    def test_explicit_selection_and_atomic_validation(self):
        (self.generated / "other.gr2").write_bytes(b"never stage this")
        target = stage.stage_asset("stray_dog", self.generated, self.repo)
        self.assertEqual(target.read_bytes(), self.source.read_bytes())
        assert_same_files(self, (self.repo / "dev_assets").rglob("*.*"), [target])
        previous = target.read_bytes()
        self.source.write_bytes(glb({"images": [{"uri": "texture.dds"}]}))
        with self.assertRaisesRegex(ValueError, "self-contained"):
            stage.stage_asset("stray_dog", self.generated, self.repo)
        self.assertEqual(target.read_bytes(), previous)
        self.assertFalse(list(target.parent.glob(".stage-*")))

    def test_rejects_project_source_unknown_id_and_broken_glb(self):
        with self.assertRaisesRegex(ValueError, "outside"):
            stage.stage_asset("stray_dog", self.repo, self.repo)
        with self.assertRaisesRegex(ValueError, "Unsupported selected asset"):
            stage.stage_asset("unknown", self.generated, self.repo)
        self.source.write_bytes(b"broken")
        with self.assertRaisesRegex(ValueError, "Truncated"):
            stage.stage_asset("stray_dog", self.generated, self.repo)
        self.assertFalse((self.repo / "dev_assets").exists())

    def test_body_variant_and_sword_are_explicit_selections(self):
        for asset in ("warrior", "warrior_armor", "iron_sword"):
            source = self.generated / stage.ASSETS[asset]
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_bytes(glb({"asset": {"version": "2.0"}}))
        body = stage.stage_asset("warrior", self.generated, self.repo)
        assert_same_files(self, (self.repo / "dev_assets").rglob("*.glb"), [body])
        sword = stage.stage_asset("iron_sword", self.generated, self.repo)
        assert_same_files(self, (self.repo / "dev_assets").rglob("*.glb"), [body, sword])
        self.assertFalse((self.repo / "dev_assets/legacy" / stage.ASSETS["warrior_armor"]).exists())

    def test_identity_comparison_accepts_aliases_but_rejects_an_extra_file(self):
        target = stage.stage_asset("stray_dog", self.generated, self.repo)
        alias = self.root / "same-file-alias.glb"
        os.link(target, alias)
        # Different textual names, same filesystem identity (also true for 8.3 aliases).
        self.assertNotEqual(target, alias)
        self.assertTrue(os.path.samefile(target, alias))
        assert_same_files(self, [target], [alias])
        with self.assertRaises(AssertionError):
            assert_same_files(self, [target, alias], [target])
        unrelated = self.root / "other-file.glb"
        unrelated.write_bytes(target.read_bytes())
        with self.assertRaises(AssertionError):
            assert_same_files(self, [target], [unrelated])

    @unittest.skipUnless(os.name == "nt", "Windows path aliases only")
    def test_real_windows_short_path_alias_when_available(self):
        import ctypes
        target = stage.stage_asset("stray_dog", self.generated, self.repo)
        # Filesystems may have short-name creation disabled; the identity helper
        # above remains covered everywhere, including those Windows volumes.
        get_short = ctypes.windll.kernel32.GetShortPathNameW
        buffer = ctypes.create_unicode_buffer(32768)
        if not get_short(str(target), buffer, len(buffer)):
            self.skipTest("Short path unavailable on this volume")
        alias = Path(buffer.value)
        if str(alias).casefold() == str(target).casefold():
            self.skipTest("8.3 aliases disabled on this volume")
        assert_same_files(self, [alias], [target])

    def test_destination_link_cannot_write_outside_project(self):
        outside = self.root / "outside"
        outside.mkdir()
        link = self.repo / "dev_assets"
        if __import__("os").name == "nt":
            import subprocess
            subprocess.run(["cmd", "/c", "mklink", "/J", str(link), str(outside)], check=True, capture_output=True)
        else:
            link.symlink_to(outside, target_is_directory=True)
        self.addCleanup(lambda: link.rmdir() if link.is_junction() else link.unlink())
        with self.assertRaisesRegex(ValueError, "links or junctions"):
            stage.stage_asset("stray_dog", self.generated, self.repo)
        self.assertFalse(list(outside.iterdir()))


if __name__ == "__main__":
    unittest.main()
