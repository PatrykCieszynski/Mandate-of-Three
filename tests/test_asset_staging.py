import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest

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
        self.assertEqual(list((self.repo / "dev_assets").rglob("*.*")), [target])
        previous = target.read_bytes()
        self.source.write_bytes(glb({"images": [{"uri": "texture.dds"}]}))
        with self.assertRaisesRegex(ValueError, "self-contained"):
            stage.stage_asset("stray_dog", self.generated, self.repo)
        self.assertEqual(target.read_bytes(), previous)
        self.assertFalse(list(target.parent.glob(".stage-*")))

    def test_rejects_project_source_unknown_id_and_broken_glb(self):
        with self.assertRaisesRegex(ValueError, "outside"):
            stage.stage_asset("stray_dog", self.repo, self.repo)
        with self.assertRaisesRegex(ValueError, "Only stray_dog"):
            stage.stage_asset("warrior", self.generated, self.repo)
        self.source.write_bytes(b"broken")
        with self.assertRaisesRegex(ValueError, "Truncated"):
            stage.stage_asset("stray_dog", self.generated, self.repo)
        self.assertFalse((self.repo / "dev_assets").exists())

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
