"""Tests for the eval fixture tools in scripts/skills-eval: the PNG writer and the recipe replay.

Run from the repository root with the system python3 (no packages needed):
    python3 -B -m unittest discover -s scripts/tests -p 'test_skills_eval*.py'

Replays talk only to a stub endpoint on an ephemeral loopback port, and every file lands in a temporary folder.
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from test_skills_eval_support import EVAL_SCRIPTS, REPO, StubCompositor, load, read_png

images = load("fixture_images")
replay = load("replay_fixtures")

REPLAY = EVAL_SCRIPTS / "replay_fixtures.py"
PROFILES = REPO / "CompositorTests" / "Fixtures" / "Profiles"


def close(color, expected, tolerance=3):
    return all(abs(a - b) <= tolerance for a, b in zip(color, expected))


class TempDirTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="skills-eval-")
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)


class ImageWriterTests(TempDirTestCase):
    def write(self, **spec):
        spec.setdefault("path", "img.png")
        images.write_image(spec, self.tmp)
        return read_png(self.tmp / spec["path"])

    def test_solid_fills_every_pixel(self):
        width, height, rows = self.write(width=3, height=2, kind="solid", **{"from": "#102030"})
        self.assertEqual((width, height), (3, 2))
        self.assertEqual({pixel for row in rows for pixel in row}, {(0x10, 0x20, 0x30)})

    def test_linear_gradient_at_0_degrees_runs_left_to_right(self):
        _, _, rows = self.write(width=101, height=5, kind="linear_gradient", angle=0,
                                **{"from": "#000000", "to": "#ffffff"})
        self.assertTrue(close(rows[0][0], (0, 0, 0)))
        self.assertTrue(close(rows[0][100], (255, 255, 255)))
        self.assertTrue(close(rows[0][50], (128, 128, 128)))
        self.assertEqual(rows[0], rows[4], "every row is the same")

    def test_linear_gradient_at_90_degrees_runs_top_to_bottom(self):
        _, _, rows = self.write(width=4, height=101, kind="linear_gradient", angle=90,
                                **{"from": "#ff0000", "to": "#0000ff"})
        self.assertTrue(close(rows[0][0], (255, 0, 0)))
        self.assertTrue(close(rows[100][3], (0, 0, 255)))
        self.assertEqual(len(set(rows[40])), 1, "every column is the same")

    def test_linear_gradient_at_an_angle_spans_corner_to_corner(self):
        _, _, rows = self.write(width=60, height=40, kind="linear_gradient", angle=30,
                                **{"from": "#000000", "to": "#ffffff"})
        self.assertTrue(close(rows[0][0], (0, 0, 0), 8))
        self.assertTrue(close(rows[39][59], (255, 255, 255), 8))
        self.assertLess(rows[0][59][0], rows[39][59][0])

    def test_radial_gradient_goes_from_the_center_to_the_corners(self):
        _, _, rows = self.write(width=101, height=81, kind="radial_gradient", **{"from": "#ffffff", "to": "#000000"})
        self.assertTrue(close(rows[40][50], (255, 255, 255), 4))
        self.assertTrue(close(rows[0][0], (0, 0, 0), 8))
        self.assertTrue(close(rows[80][100], (0, 0, 0), 8))

    def test_checker_alternates_cells_starting_with_from(self):
        _, _, rows = self.write(width=6, height=6, kind="checker", cell=2, **{"from": "#ffffff", "to": "#118ab2"})
        white, blue = (255, 255, 255), (0x11, 0x8A, 0xB2)
        self.assertEqual(rows[0][0], white)
        self.assertEqual(rows[1][1], white)
        self.assertEqual(rows[0][2], blue)
        self.assertEqual(rows[2][0], blue)
        self.assertEqual(rows[2][2], white)

    def test_disc_draws_from_inside_the_circle_over_to(self):
        _, _, rows = self.write(width=120, height=100, kind="disc", center={"x": 60, "y": 45}, radius=30,
                                **{"from": "#d62828", "to": "#9e9e9e"})
        red, gray = (0xD6, 0x28, 0x28), (0x9E, 0x9E, 0x9E)
        self.assertEqual(rows[45][60], red)
        self.assertEqual(rows[0][0], gray)
        self.assertEqual(rows[45][29], gray)
        self.assertEqual(rows[45][31], red)
        self.assertEqual(sum(1 for pixel in rows[45] if pixel == red), 60)

    def test_writes_into_missing_folders(self):
        images.write_image({"path": "a/b/c.png", "width": 2, "height": 2, "kind": "solid", "from": "#000000"}, self.tmp)
        self.assertTrue((self.tmp / "a" / "b" / "c.png").is_file())

    @unittest.skipUnless(shutil.which("sips"), "sips is macOS only")
    def test_sips_reads_the_size(self):
        images.write_image({"path": "s.png", "width": 37, "height": 21, "kind": "solid", "from": "#abcdef"}, self.tmp)
        out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(self.tmp / "s.png")],
                             capture_output=True, text=True, check=True).stdout
        self.assertIn("pixelWidth: 37", out)
        self.assertIn("pixelHeight: 21", out)

    def test_rejects_unknown_kinds_and_colors(self):
        with self.assertRaises(ValueError):
            images.write_image({"path": "x.png", "width": 2, "height": 2, "kind": "noise", "from": "#000000"}, self.tmp)
        with self.assertRaises(ValueError):
            images.write_image({"path": "x.png", "width": 2, "height": 2, "kind": "solid", "from": "red"}, self.tmp)

    def test_every_recipe_image_spec_renders(self):
        """Each image a skill's evals/fixtures.json asks for, written small so the test stays fast."""
        for recipe in sorted((REPO / "skills").glob("*/evals/fixtures.json")):
            for spec in json.loads(recipe.read_text(encoding="utf-8")).get("images", []):
                with self.subTest(recipe=recipe.parent.parent.name, image=spec["path"]):
                    small = {**spec, "width": 24, "height": 16}
                    if "center" in small:
                        small["center"] = {"x": 12, "y": 8}
                    if "radius" in small:
                        small["radius"] = 6
                    images.write_image(small, self.tmp)
                    self.assertEqual(read_png(self.tmp / spec["path"])[:2], (24, 16))


RECIPE = {
    "skill_name": "demo-skill",
    "images": [
        {"path": "eval-inputs/logo.png", "width": 4, "height": 4, "kind": "checker", "from": "#ffffff",
         "to": "#000000", "cell": 2},
    ],
    "fixtures": [
        {"id": "draft", "description": "a project and an export", "outputs": ["draft.comp", "exports/draft.png"],
         "calls": [
             {"tool": "new_document", "arguments": {"width": 10, "height": 10, "name": "draft"}},
             {"tool": "add_image_layer", "arguments": {"path": "eval-inputs/logo.png", "name": "Logo"}},
             {"tool": "place_layer", "arguments": {"layer": "@active", "parent": None}, "note": "stays at the top"},
             {"tool": "save_document_as", "arguments": {"path": "draft.comp"}},
             {"tool": "export_image", "arguments": {"path": "exports/draft.png"}},
             {"tool": "close_document", "arguments": {}},
         ]},
        {"id": "template", "description": "a PSD template", "outputs": ["templates/card.psd"],
         "calls": [
             {"tool": "new_document", "arguments": {"width": 10, "height": 10, "name": "card"}},
             {"tool": "save_document_as", "arguments": {"path": "templates/card.psd"}},
             {"tool": "close_document", "arguments": {}},
         ]},
        {"id": "later", "description": "replayed after a failed fixture", "outputs": ["later.comp"],
         "calls": [
             {"tool": "new_document", "arguments": {"width": 10, "height": 10, "name": "later"}},
             {"tool": "save_document_as", "arguments": {"path": "later.comp"}},
             {"tool": "close_document", "arguments": {}},
         ]},
    ],
}


class ReplayTests(TempDirTestCase):
    def setUp(self):
        super().setUp()
        self.workspace = self.tmp / "workspace"
        self.agent = self.tmp / "agent"
        self.agent.mkdir()

    def replay(self, recipe=RECIPE, **stub_options):
        with StubCompositor(self.agent, **stub_options) as stub:
            manifest = replay.replay_recipe(recipe, replay.Endpoint(stub.url), self.workspace)
        return stub, manifest

    def test_writes_images_and_rebases_relative_paths_into_the_fixture_folder(self):
        stub, manifest = self.replay()
        root = self.workspace / "fixtures" / "demo-skill"
        self.assertEqual(Path(manifest["fixture_dir"]), root)
        self.assertTrue((root / "eval-inputs" / "logo.png").is_file())
        paths = [arguments["path"] for name, arguments in stub.calls if "path" in arguments]
        self.assertIn(str(root / "eval-inputs" / "logo.png"), paths)
        self.assertIn(str(root / "draft.comp"), paths)
        self.assertIn(str(root / "exports" / "draft.png"), paths)
        self.assertFalse(any(Path(path).is_relative_to(self.agent) for path in paths), "nothing goes to the Agent folder")
        self.assertTrue((root / "draft.comp" / "manifest.json").is_file())
        self.assertFalse((self.agent / "draft.comp").exists())

    def test_runs_each_fixtures_calls_in_order_with_their_arguments(self):
        stub, _ = self.replay()
        draft = [name for name, _ in stub.calls if name not in ("list_documents",)]
        self.assertEqual(draft[:6], ["new_document", "add_image_layer", "place_layer", "save_document_as",
                                     "export_image", "close_document"])
        self.assertIn(("place_layer", {"layer": "@active", "parent": None}), stub.calls)

    def test_records_the_sha256_of_every_file_left_behind(self):
        _, manifest = self.replay()
        root = self.workspace / "fixtures" / "demo-skill"
        expected = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in root.rglob("*") if path.is_file()}
        self.assertEqual(manifest["files"], expected)
        self.assertIn("draft.comp/manifest.json", manifest["files"])
        self.assertIn("eval-inputs/logo.png", manifest["files"])
        written = json.loads((self.workspace / "fixtures" / "demo-skill.manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(written, manifest)

    def test_a_failing_call_fails_its_fixture_clearly_and_the_rest_still_replay(self):
        stub, manifest = self.replay()
        by_id = {fixture["id"]: fixture for fixture in manifest["fixtures"]}
        self.assertTrue(by_id["draft"]["ok"])
        self.assertFalse(by_id["template"]["ok"])
        self.assertRegex(by_id["template"]["error"], r"call 2 save_document_as .*unsupported")
        self.assertTrue(by_id["later"]["ok"])
        self.assertFalse(manifest["ok"])
        # The half-built template was closed without saving before the next fixture started.
        closes = [arguments for name, arguments in stub.calls if name == "close_document"]
        self.assertTrue(any(arguments.get("discard_changes") is True for arguments in closes))
        self.assertEqual(stub.tabs[0]["document_id"], None)

    def test_a_declared_output_that_never_appeared_fails_the_fixture(self):
        recipe = json.loads(json.dumps(RECIPE))
        recipe["fixtures"] = [recipe["fixtures"][2]]
        recipe["fixtures"][0]["outputs"] = ["later.comp", "missing.png"]
        _, manifest = self.replay(recipe)
        self.assertFalse(manifest["fixtures"][0]["ok"])
        self.assertIn("missing.png", manifest["fixtures"][0]["error"])

    def test_starts_from_a_clean_app_and_a_fresh_fixture_folder(self):
        stale = self.workspace / "fixtures" / "demo-skill" / "stale.txt"
        stale.parent.mkdir(parents=True)
        stale.write_text("old")
        stub, _ = self.replay()
        self.assertFalse(stale.exists())
        self.assertEqual(stub.calls[0][0], "list_documents")

    def test_the_command_line_reads_the_endpoint_from_the_instance_state_and_exits_1_on_a_failed_fixture(self):
        recipe_file = self.tmp / "recipe.json"
        recipe_file.write_text(json.dumps(RECIPE), encoding="utf-8")
        with StubCompositor(self.agent) as stub:
            state = self.workspace / "instance" / "state.json"
            state.parent.mkdir(parents=True)
            state.write_text(json.dumps({"url": stub.url}), encoding="utf-8")
            result = subprocess.run([sys.executable, "-B", str(REPLAY), "--recipe", str(recipe_file),
                                     "--workspace", str(self.workspace)], capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("template", result.stdout + result.stderr)
        self.assertIn("unsupported", result.stdout + result.stderr)
        self.assertTrue((self.workspace / "fixtures" / "demo-skill.manifest.json").is_file())


class ProfileFixtureTests(TempDirTestCase):
    def test_a_synthetic_profile_takes_its_tables_from_a_committed_fixture_under_a_new_name_and_group(self):
        spec = {"path": "eval-inputs/profiles/film.xmp", "from": "film-prophoto", "name": "Synthetic Film 01",
                "group": "Film-Inspired"}
        replay.write_profile(spec, self.tmp)
        written = (self.tmp / spec["path"]).read_text(encoding="utf-8")
        source = (PROFILES / "profile-film-prophoto.xmp").read_text(encoding="utf-8")
        self.assertIn('crs:PresetType="Look"', written)
        self.assertIn('<rdf:li xml:lang="x-default">Synthetic Film 01</rdf:li>', written)
        self.assertIn('<rdf:li xml:lang="x-default">Film-Inspired</rdf:li>', written)
        self.assertNotIn("Film ProPhoto", written)
        table = re.compile(r'crs:Table_\w+="[^"]*"', re.S)
        self.assertEqual(table.findall(written), table.findall(source))
        uuid = re.search(r'crs:UUID="([0-9A-F]{32})"', written).group(1)
        self.assertNotEqual(uuid, re.search(r'crs:UUID="([0-9A-F]{32})"', source).group(1))

    def test_rejects_an_unknown_source_fixture(self):
        with self.assertRaises(ValueError):
            replay.write_profile({"path": "p.xmp", "from": "nope", "name": "N", "group": "G"}, self.tmp)

    def test_profiles_are_written_before_the_fixtures_that_import_them(self):
        recipe = {"skill_name": "demo-skill", "images": [],
                  "profiles": [{"path": "eval-inputs/profiles/film.xmp", "from": "film-prophoto",
                                "name": "Synthetic Film 01", "group": "Film-Inspired"}],
                  "fixtures": [{"id": "film-profile", "description": "imports it", "outputs": [],
                                "calls": [{"tool": "import_profile",
                                           "arguments": {"path": "eval-inputs/profiles/film.xmp"}}]}]}
        agent = self.tmp / "agent"
        agent.mkdir()
        with StubCompositor(agent) as stub:
            manifest = replay.replay_recipe(recipe, replay.Endpoint(stub.url), self.tmp / "ws")
        imported = [arguments["path"] for name, arguments in stub.calls if name == "import_profile"]
        self.assertEqual(len(imported), 1)
        self.assertTrue(Path(imported[0]).is_file())
        self.assertTrue(manifest["ok"])

    def test_the_image_editing_recipe_imports_a_synthetic_film_inspired_profile(self):
        recipe = json.loads((REPO / "skills" / "compositor-image-editing" / "evals" / "fixtures.json")
                            .read_text(encoding="utf-8"))
        profiles = recipe.get("profiles", [])
        self.assertTrue(any(profile.get("group") == "Film-Inspired" for profile in profiles))
        imports = [call["arguments"]["path"] for fixture in recipe["fixtures"] for call in fixture["calls"]
                   if call["tool"] == "import_profile"]
        self.assertEqual(sorted(imports), sorted(profile["path"] for profile in profiles))


if __name__ == "__main__":
    unittest.main()
