"""Tests for scripts/psd-verify.py.

Run from the repository root:
    uv run --with psd-tools python3 -m unittest discover -s scripts/tests
"""

import hashlib
import importlib.util
import json
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from PIL import Image
from psd_tools import PSDImage
from psd_tools.constants import BlendMode, Resource, Tag
from psd_tools.psd.image_resources import GridGuidesInfo, ImageResource
from psd_tools.psd.tagged_blocks import ProtectedSetting

SCRIPT = Path(__file__).resolve().parents[1] / "psd-verify.py"

# Distinctive stand-ins for client strings: none of them may reach a default report or summary.
CLIENT_FILE = "Northwind Quarterly Brief.psd"
CLIENT_NAMES = ["Northwind Hero Image", "Unreleased Offer Copy", "Confidential Folder", "Private Inner Mark"]


def sha(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def load_psd_verify():
    spec = importlib.util.spec_from_file_location("psd_verify", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    dont_write_bytecode = sys.dont_write_bytecode
    sys.dont_write_bytecode = True  # no scripts/__pycache__
    try:
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = dont_write_bytecode
    return module


def run_verify(*args):
    return subprocess.run(
        [sys.executable, str(SCRIPT), *map(str, args)],
        capture_output=True,
        text=True,
        timeout=120,
    )


def save_layered_document(path, mode="RGB", guides=None, names=("Bottom", "Top", "Folder", "Inner")):
    """Bottom (locked) and Top (clipped, multiply, hidden) pixel layers under a Folder holding Inner."""
    bottom_name, top_name, folder_name, inner_name = names
    psd = PSDImage.new(mode, (100, 80), color=255)
    bottom = psd.create_pixel_layer(
        Image.new("RGBA", (20, 10), (255, 0, 0, 255)), name=bottom_name, top=5, left=7
    )
    bottom.tagged_blocks.set_data(Tag.PROTECTED_SETTING, ProtectedSetting(0x01 | 0x04))
    top = psd.create_pixel_layer(
        Image.new("RGBA", (30, 30), (0, 0, 255, 255)),
        name=top_name,
        top=10,
        left=20,
        opacity=128,
        blend_mode=BlendMode.MULTIPLY,
    )
    top.clipping = True
    top.fill_opacity = 200
    top.visible = False
    folder = psd.create_group(name=folder_name)
    folder.append(
        psd.create_pixel_layer(
            Image.new("RGBA", (4, 4), (0, 255, 0, 255)), name=inner_name, top=1, left=2
        )
    )
    if guides is not None:
        psd.image_resources[Resource.GRID_AND_GUIDES_INFO] = ImageResource(
            key=Resource.GRID_AND_GUIDES_INFO,
            data=GridGuidesInfo(version=1, horizontal=576, vertical=576, data=guides),
        )
    psd.save(path)
    return path


def layer_count_offset(data):
    offset = 26  # file header
    offset += 4 + struct.unpack_from(">I", data, offset)[0]  # color mode data
    offset += 4 + struct.unpack_from(">I", data, offset)[0]  # image resources
    return offset + 4 + 4  # layer and mask length, layer info length


class PSDVerifyTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def verify_json(self, psd_path, *options):
        out = self.tmp / "out.json"
        result = run_verify(psd_path, "--json", out, *options)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(out.read_text())

    def layer(self, report, name):
        return next(layer for layer in report["layers"] if layer["name_sha256"] == sha(name))

    def test_reports_header_and_positive_layer_count(self):
        report = self.verify_json(save_layered_document(self.tmp / "doc.psd"))
        self.assertEqual(
            report["header"],
            {"version": 1, "channels": 3, "width": 100, "height": 80, "depth": 8, "color_mode": "RGB"},
        )
        # Three pixel layers plus the folder's two records (folder and divider).
        self.assertEqual(report["layer_count"], 5)
        self.assertEqual(report["warnings"], [])
        self.assertEqual(report["errors"], [])

    def test_reports_negative_layer_count_of_a_document_with_merged_transparency(self):
        path = save_layered_document(self.tmp / "alpha.psd", mode="RGBA")
        data = bytearray(path.read_bytes())
        offset = layer_count_offset(data)
        struct.pack_into(">h", data, offset, -struct.unpack_from(">h", data, offset)[0])
        path.write_bytes(bytes(data))

        report = self.verify_json(path)
        self.assertEqual(report["header"]["channels"], 4)
        self.assertEqual(report["layer_count"], -5)

    def test_lists_layers_top_to_bottom_like_photoshop(self):
        report = self.verify_json(save_layered_document(self.tmp / "doc.psd"))
        self.assertEqual(
            [(layer["index"], layer["depth"], layer["kind"], layer["name_sha256"]) for layer in report["layers"]],
            [
                (0, 0, "group", sha("Folder")),
                (1, 1, "pixel", sha("Inner")),
                (2, 0, "pixel", sha("Top")),
                (3, 0, "pixel", sha("Bottom")),
            ],
        )

    def test_reports_bbox_blend_opacity_clipping_visibility_and_locks(self):
        report = self.verify_json(save_layered_document(self.tmp / "doc.psd"))
        top = self.layer(report, "Top")
        self.assertEqual(top["bbox"], [20, 10, 50, 40])
        self.assertEqual(top["blend_mode"], "MULTIPLY")
        self.assertEqual(top["opacity"], 128)
        self.assertEqual(top["fill_opacity"], 200)
        self.assertTrue(top["clipping"])
        self.assertFalse(top["visible"])
        self.assertIsNone(top["locks"])

        bottom = self.layer(report, "Bottom")
        self.assertEqual(bottom["bbox"], [7, 5, 27, 15])
        self.assertEqual(bottom["blend_mode"], "NORMAL")
        self.assertFalse(bottom["clipping"])
        self.assertTrue(bottom["visible"])
        self.assertEqual(
            bottom["locks"],
            {"value": 5, "transparency": True, "composite": False, "position": True, "nesting": False, "complete": False},
        )
        self.assertEqual(self.layer(report, "Folder")["blend_mode"], "PASS_THROUGH")

    def test_decodes_guides_from_resource_1032(self):
        path = save_layered_document(self.tmp / "guides.psd", guides=[(64 * 32, 0), (1072, 1)])
        report = self.verify_json(path)
        self.assertEqual(
            report["guides"],
            [
                {"location": 2048, "direction": 0, "axis": "vertical", "position": 64.0},
                {"location": 1072, "direction": 1, "axis": "horizontal", "position": 33.5},
            ],
        )

    def test_reports_no_guides_when_resource_1032_is_absent(self):
        report = self.verify_json(save_layered_document(self.tmp / "doc.psd"))
        self.assertEqual(report["guides"], [])

    def test_lists_resources_in_file_order_and_document_blocks(self):
        report = self.verify_json(save_layered_document(self.tmp / "guides.psd", guides=[]))
        self.assertEqual(
            report["resources"],
            [{"id": 1057, "name": "VERSION_INFO"}, {"id": 1032, "name": "GRID_AND_GUIDES_INFO"}],
        )
        self.assertEqual(report["document_blocks"], [])

    def test_prints_a_readable_summary(self):
        path = save_layered_document(self.tmp / "guides.psd", guides=[(2048, 0), (1072, 1)])
        result = run_verify(path)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("100 x 80 px, 3 channels, 8-bit RGB", result.stdout)
        self.assertIn("layer count: 5", result.stdout)
        self.assertIn("guides: vertical 64 px, horizontal 33.5 px", result.stdout)
        self.assertIn(f"pixel #{sha('Top')[:12]} ", result.stdout)
        self.assertIn("warnings: none", result.stdout)

    def test_stores_hashes_instead_of_names_and_the_file_name_by_default(self):
        path = save_layered_document(self.tmp / CLIENT_FILE, names=CLIENT_NAMES)
        out = self.tmp / "out.json"

        result = run_verify(path, "--json", out)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        stored = out.read_text()
        for client_string in [CLIENT_FILE, "Northwind", str(self.tmp), *CLIENT_NAMES]:
            self.assertNotIn(client_string, stored)
            self.assertNotIn(client_string, result.stdout)
        report = json.loads(stored)
        self.assertIs(report["raw"], False)
        self.assertNotIn("file", report)
        self.assertEqual(report["file_sha256"], sha(CLIENT_FILE))
        for layer in report["layers"]:
            self.assertNotIn("name", layer)
        self.assertEqual(
            sorted(layer["name_sha256"] for layer in report["layers"]), sorted(sha(name) for name in CLIENT_NAMES)
        )
        self.assertIn(f"#{sha(CLIENT_NAMES[1])[:12]}", result.stdout)

    def test_raw_option_also_stores_names_and_the_path(self):
        path = save_layered_document(self.tmp / CLIENT_FILE, names=CLIENT_NAMES)
        out = self.tmp / "out.json"

        result = run_verify(path, "--json", out, "--raw")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(out.read_text())
        self.assertIs(report["raw"], True)
        self.assertEqual(report["file"], str(path))
        self.assertEqual(report["file_sha256"], sha(CLIENT_FILE))
        for layer in report["layers"]:
            self.assertEqual(layer["name_sha256"], sha(layer["name"]))
        self.assertEqual(sorted(layer["name"] for layer in report["layers"]), sorted(CLIENT_NAMES))
        self.assertIn(f'pixel "{CLIENT_NAMES[1]}"', result.stdout)
        self.assertIn(str(path), result.stdout)

    def test_error_messages_do_not_store_the_file_name(self):
        path = self.tmp / CLIENT_FILE  # never created: psd-tools' error names the path
        out = self.tmp / "out.json"

        result = run_verify(path, "--json", out)

        self.assertEqual(result.returncode, 1)
        stored = out.read_text()
        report = json.loads(stored)
        self.assertTrue(report["errors"])
        self.assertIn("FileNotFoundError", report["errors"][0])
        self.assertNotIn("Northwind", stored)
        self.assertNotIn("Northwind", result.stdout)

    def test_type_layer_text_is_stored_as_a_hash_unless_raw(self):
        module = load_psd_verify()
        run = SimpleNamespace(style=SimpleNamespace(font_size=24.0))
        layer = SimpleNamespace(
            text="Launch price\rtwo lines \u2014 caf\u00e9 \U0001F600",
            text_type=SimpleNamespace(name="POINT"),
            transform=(1.0, 0.0, 0.0, 1.0, 10.0, 20.0),
            font_names=["ArialMT"],
            typesetting=SimpleNamespace(runs=[run, run]),
        )

        hashed = module.Privacy(raw=False)
        text = module._text(layer, hashed)
        self.assertEqual(text["text_sha256"], sha(layer.text))
        self.assertNotIn("text", text)
        self.assertEqual(text["font_sizes"], [24.0])
        self.assertEqual(
            hashed.scrub("could not lay out Launch price\rtwo lines \u2014 caf\u00e9 \U0001F600 again"),
            f"could not lay out #{sha(layer.text)[:12]} again",
        )

        raw = module.Privacy(raw=True)
        text = module._text(layer, raw)
        self.assertEqual(text["text"], layer.text)
        self.assertEqual(text["text_sha256"], sha(layer.text))
        self.assertEqual(raw.scrub(f"message with {layer.text}"), f"message with {layer.text}")

    def test_exits_nonzero_and_lists_psd_tools_warnings(self):
        path = save_layered_document(self.tmp / "warn.psd")
        data = path.read_bytes()
        self.assertIn(b"8BIMlspf", data)
        path.write_bytes(data.replace(b"8BIMlspf", b"8BIMzzzz"))
        out = self.tmp / "out.json"

        result = run_verify(path, "--json", out)

        self.assertEqual(result.returncode, 1)
        report = json.loads(out.read_text())
        self.assertTrue(any("Unknown key" in warning for warning in report["warnings"]), report["warnings"])
        self.assertIn("Unknown key", result.stdout)

    def test_unreadable_file_exits_nonzero_with_an_error(self):
        path = self.tmp / "broken.psd"
        path.write_bytes(b"8BPS\x00\x01not a psd")
        out = self.tmp / "out.json"

        result = run_verify(path, "--json", out)

        self.assertEqual(result.returncode, 1)
        self.assertTrue(json.loads(out.read_text())["errors"])


if __name__ == "__main__":
    unittest.main()
