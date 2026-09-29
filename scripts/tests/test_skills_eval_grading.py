"""Tests for scripts/skills-eval/grade_scripted.py and the check specs in scripts/skills-eval/checks/.

Run from the repository root with the system python3 (no packages needed):
    python3 -B -m unittest discover -s scripts/tests -p 'test_skills_eval*.py'

Runs are built by hand in a temporary folder. psd-verify reports are stubbed (the real script needs psd-tools).
"""

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from test_skills_eval_support import EVAL_SCRIPTS, REPO, load

images = load("fixture_images")
grader = load("grade_scripted")

GRADE = EVAL_SCRIPTS / "grade_scripted.py"
CHECKS = EVAL_SCRIPTS / "checks"
HAS_SIPS = shutil.which("sips") is not None


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def tool_use(identifier, name, arguments):
    return {"type": "assistant", "message": {"content": [
        {"type": "tool_use", "id": identifier, "name": name, "input": arguments}]}}


def tool_result(identifier, error=False):
    return {"type": "user", "message": {"content": [
        {"type": "tool_result", "tool_use_id": identifier, "content": "{}", "is_error": error}]}}


def session(*calls):
    """stream-json events for (name, arguments[, error]) calls; MCP tools get Claude Code's mcp__compositor__ prefix."""
    events = [{"type": "system", "subtype": "init", "model": "m", "skills": []}]
    for index, call in enumerate(calls):
        name, arguments = call[0], call[1]
        error = call[2] if len(call) > 2 else False
        full = name if name[0].isupper() else f"mcp__compositor__{name}"
        events += [tool_use(f"t{index}", full, arguments), tool_result(f"t{index}", error)]
    events.append({"type": "result", "subtype": "success", "result": "Done."})
    return events


def comp(path, layers):
    """A .comp folder whose manifest holds (name, parent name or None, origin, locks) layers, bottom to top."""
    ids = {}
    records = []
    for name, parent, origin, locks in layers:
        identifier = f"id-{len(records)}"
        ids.setdefault(name, identifier)
        record = {"id": identifier, "name": name, "isGroup": parent is None and name == "Footer",
                  "opacity": 1, "transform": {"origin": list(origin), "size": [10, 10], "rotation": 0}}
        if parent:
            record["parentID"] = ids[parent]
        if locks is not None:
            record["locks"] = locks
        records.append(record)
    path.mkdir(parents=True, exist_ok=True)
    (path / "manifest.json").write_text(json.dumps({"version": 10, "layers": records}), encoding="utf-8")


class GradingTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="skills-eval-grade-")
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.fixtures = self.tmp / "fixtures" / "demo-skill"
        self.run = self.tmp / "run-1"
        self.outputs = self.run / "outputs"
        self.outputs.mkdir(parents=True)
        self.expectations = []
        self.events = session()
        self.before = {}

    def write_run(self):
        metadata = {"skill_name": "demo-skill", "eval_id": 1, "configuration": "with_skill",
                    "assertions": self.expectations, "fixture_dir": str(self.fixtures), "prompt": "p"}
        (self.run / "eval_metadata.json").write_text(json.dumps(metadata), encoding="utf-8")
        (self.run / "transcript.jsonl").write_text("".join(json.dumps(e) + "\n" for e in self.events), encoding="utf-8")
        (self.run / "agent-folder-before.json").write_text(json.dumps(self.before), encoding="utf-8")
        (self.run / "timing.json").write_text(json.dumps({"total_tokens": 5, "total_duration_seconds": 2.0}),
                                              encoding="utf-8")
        (self.outputs / "metrics.json").write_text(json.dumps({"total_tool_calls": 3, "errors_encountered": 0}),
                                                   encoding="utf-8")

    def grade(self, specs):
        self.write_run()
        checks = {"skill_name": "demo-skill", "evals": {"1": specs}}
        return grader.grade_run(self.run, checks)

    def verdicts(self, specs):
        grading = self.grade(specs)
        return {entry["text"]: entry["passed"] for entry in grading["expectations"]}

    def image(self, relative, width, height):
        images.write_image({"path": relative, "width": width, "height": height, "kind": "solid", "from": "#336699"},
                           self.outputs)


class FileCheckTests(GradingTestCase):
    def test_exists_with_a_glob_that_leaves_out_the_template(self):
        self.expectations = ["A new PSD exists", "Another file exists"]
        (self.outputs / "templates").mkdir()
        (self.outputs / "templates" / "card-template.psd").write_bytes(b"t")
        verdicts = self.verdicts([
            {"match": "A new PSD", "checks": [{"type": "exists", "glob": "templates/*.psd",
                                               "exclude": ["templates/card-template.psd"]}]},
            {"match": "Another file", "checks": [{"type": "exists", "path": "templates/card-template.psd"}]},
        ])
        self.assertEqual(verdicts, {"A new PSD exists": False, "Another file exists": True})
        (self.outputs / "templates" / "card-jordan.psd").write_bytes(b"n")
        self.assertTrue(self.verdicts([{"match": "A new PSD", "checks": [
            {"type": "exists", "glob": "templates/*.psd", "exclude": ["templates/card-template.psd"]}]}])[
            "A new PSD exists"])

    def test_unchanged_compares_with_the_agent_folder_before_the_session(self):
        self.expectations = ["The template is unchanged", "The project is unchanged"]
        (self.outputs / "t.psd").write_bytes(b"template")
        comp(self.outputs / "p.comp", [("Badge", None, (0, 0), None)])
        self.before = {"t.psd": sha(self.outputs / "t.psd"), "p.comp/manifest.json": "0" * 64}
        grading = self.grade([
            {"match": "template is unchanged", "checks": [{"type": "unchanged", "path": "t.psd"}]},
            {"match": "project is unchanged", "checks": [{"type": "unchanged", "path": "p.comp"}]},
        ])
        verdicts = {entry["text"]: entry for entry in grading["expectations"]}
        self.assertTrue(verdicts["The template is unchanged"]["passed"])
        self.assertFalse(verdicts["The project is unchanged"]["passed"])
        self.assertIn("p.comp/manifest.json", verdicts["The project is unchanged"]["evidence"])

    def test_unchanged_fails_when_the_file_is_gone(self):
        self.expectations = ["kept"]
        self.before = {"t.psd": "0" * 64}
        self.assertFalse(self.verdicts([{"match": "kept", "checks": [{"type": "unchanged", "path": "t.psd"}]}])["kept"])


@unittest.skipUnless(HAS_SIPS, "sips is macOS only")
class ImageCheckTests(GradingTestCase):
    def test_image_size_reads_pixels_with_sips(self):
        self.expectations = ["half-size PNG", "full-size PNG"]
        self.image("exports/half.png", 540, 540)
        grading = self.grade([
            {"match": "half-size", "checks": [{"type": "image_size", "path": "exports/half.png", "width": 540,
                                               "height": 540, "format": "png"}]},
            {"match": "full-size", "checks": [{"type": "image_size", "path": "exports/half.png", "width": 1080,
                                               "height": 1080}]},
        ])
        verdicts = {entry["text"]: entry for entry in grading["expectations"]}
        self.assertTrue(verdicts["half-size PNG"]["passed"])
        self.assertFalse(verdicts["full-size PNG"]["passed"])
        self.assertIn("540 x 540", verdicts["full-size PNG"]["evidence"])

    def test_image_size_with_a_tolerance_and_a_glob(self):
        self.expectations = ["cutout"]
        self.image("out/cutout.png", 644, 637)
        spec = {"match": "cutout", "checks": [{"type": "image_size", "glob": "out/*.png", "width": 640, "height": 640,
                                               "tolerance": 6}]}
        self.assertTrue(self.verdicts([spec])["cutout"])
        spec["checks"][0]["tolerance"] = 2
        self.assertFalse(self.verdicts([spec])["cutout"])

    def test_image_sizes_needs_exactly_those_sizes(self):
        self.expectations = ["three JPEG sizes"]
        spec = {"match": "three", "checks": [{"type": "image_sizes", "glob": "out/kit/*.png",
                                              "sizes": [[30, 40], [30, 50], [40, 20]]}]}
        self.image("out/kit/feed.png", 30, 40)
        self.image("out/kit/story.png", 30, 50)
        self.assertFalse(self.verdicts([spec])["three JPEG sizes"])
        self.image("out/kit/link.png", 40, 20)
        self.assertTrue(self.verdicts([spec])["three JPEG sizes"])
        self.image("out/kit/extra.png", 40, 20)
        self.assertFalse(self.verdicts([spec])["three JPEG sizes"])


class TranscriptCheckTests(GradingTestCase):
    def test_called_and_not_called_look_inside_run_batch_steps(self):
        self.expectations = ["exported at half size", "no overwrite", "band batch"]
        self.events = session(
            ("get_document", {}),
            ("run_batch", {"steps": [{"tool": "add_blank_layer", "arguments": {"name": "Band"}},
                                     {"tool": "set_layer_opacity", "arguments": {"opacity": 0.4}}]}),
            ("export_image", {"path": "a.png", "scale": 0.5, "overwrite": False}),
        )
        verdicts = self.verdicts([
            {"match": "half size", "checks": [{"type": "called", "tool": "export_image",
                                               "args": {"scale": {"<=": 0.5}}}]},
            {"match": "no overwrite", "checks": [{"type": "not_called", "args": {"overwrite": True}}]},
            {"match": "band batch", "checks": [{"type": "called", "tool": "set_layer_opacity",
                                                "args": {"opacity": 0.4}}]},
        ])
        self.assertEqual(set(verdicts.values()), {True})
        self.events = session(("run_batch", {"steps": [{"tool": "export_image", "arguments": {"overwrite": True}}]}))
        self.expectations = ["no overwrite"]
        self.assertFalse(self.verdicts([{"match": "no overwrite", "checks": [
            {"type": "not_called", "args": {"overwrite": True}}]}])["no overwrite"])

    def test_order_finds_the_calls_in_sequence(self):
        self.expectations = ["render between move and export"]
        spec = {"match": "render between", "checks": [{"type": "order", "steps": [
            {"any": ["move_layer", "set_layer_transform"]}, {"any": ["render_document", "render_region"]},
            {"tool": "export_image"}]}]}
        self.events = session(("move_layer", {}), ("export_image", {}), ("render_document", {}))
        self.assertFalse(self.verdicts([spec])["render between move and export"])
        self.events = session(("render_document", {}), ("move_layer", {}), ("render_region", {}), ("export_image", {}))
        self.assertTrue(self.verdicts([spec])["render between move and export"])

    def test_order_after_the_last_anchor_ignores_earlier_attempts(self):
        # A render of an attempt that was undone must not count for the version that was exported.
        self.expectations = ["checked the final version"]
        self.events = session(("run_batch", {"steps": [{"tool": "add_shape", "arguments": {}}]}),
                              ("render_document", {}), ("undo", {}),
                              ("run_batch", {"steps": [{"tool": "add_blank_layer", "arguments": {}}]}),
                              ("export_image", {"path": "exports/a.png"}), ("render_document", {}))
        spec = {"match": "final version", "checks": [{"type": "order", "after_last": {"tool": "run_batch"},
                                                       "steps": [{"any": ["render_document", "render_region"]},
                                                                 {"tool": "export_image"}]}]}
        grading = self.grade([spec])
        self.assertFalse(grading["expectations"][0]["passed"], grading["expectations"][0]["evidence"])
        self.assertIn("after call 5 run_batch", grading["expectations"][0]["evidence"])
        del spec["checks"][0]["after_last"]
        self.assertTrue(self.verdicts([spec])["checked the final version"])
        self.assertEqual(grader.validate_check({"type": "order", "after_last": "run_batch", "steps": [{"tool": "x"}]}),
                         ["a call matcher is an object"])

    def test_first_before_and_last_after(self):
        self.expectations = ["read before the first edit", "sampled again after the last adjustment"]
        specs = [
            {"match": "read before", "checks": [{"type": "first_before", "first": {"any": ["get_document", "get_layer"]},
                                                 "before": {"any": ["move_layer"]}}]},
            {"match": "sampled again", "checks": [{"type": "last_after", "last": {"tool": "sample_colors"},
                                                   "after": {"tool": "add_adjustment_layer"}}]},
        ]
        self.events = session(("move_layer", {}), ("get_document", {}), ("add_adjustment_layer", {}),
                              ("sample_colors", {}), ("add_adjustment_layer", {}))
        self.assertEqual(set(self.verdicts(specs).values()), {False})
        self.events = session(("get_document", {}), ("move_layer", {}), ("add_adjustment_layer", {}),
                              ("sample_colors", {}))
        self.assertEqual(set(self.verdicts(specs).values()), {True})

    def test_a_matcher_can_require_success_and_bash_commands_match_by_pattern(self):
        self.expectations = ["replaced with fill", "ran the check script"]
        self.events = session(("replace_smart_object_contents", {"fit": "fill"}, True),
                              ("Bash", {"command": "bash skills/compositor-setup/scripts/check-compositor.sh"}))
        verdicts = self.verdicts([
            {"match": "replaced", "checks": [{"type": "called", "tool": "replace_smart_object_contents",
                                              "args": {"fit": "fill"}, "ok": True}]},
            {"match": "check script", "checks": [{"type": "called", "tool": "Bash",
                                                  "args": {"command": {"matches": r"check-compositor\.sh"}}}]},
        ])
        self.assertEqual(verdicts, {"replaced with fill": False, "ran the check script": True})

    def test_any_passes_when_one_alternative_does(self):
        self.expectations = ["measured"]
        self.events = session(("get_layer_bounds", {}))
        spec = {"match": "measured", "checks": [{"type": "any", "checks": [
            {"type": "called", "tool": "get_text_metrics"}, {"type": "called", "tool": "get_layer_bounds"}]}]}
        self.assertTrue(self.verdicts([spec])["measured"])


class ManifestCheckTests(GradingTestCase):
    def setUp(self):
        super().setUp()
        layers = [("Background", None, (0, 0), None), ("Badge", None, (100, 200), None), ("Logo", None, (5, 5), None),
                  ("Footer", None, (0, 0), 4), ("Logo", "Footer", (500, 900), None)]
        comp(self.fixtures / "draft.comp", layers)
        moved = [("Background", None, (0, 0), None), ("Badge", None, (140, 180), None), ("Logo", None, (5, 5), None),
                 ("Footer", None, (0, 0), 4), ("Logo", "Footer", (500, 876), None)]
        comp(self.outputs / "draft-v2.comp", moved)

    def test_comp_layer_delta_same_and_bits_by_path(self):
        self.expectations = ["Badge moved", "footer logo raised", "top logo kept", "footer still locked"]
        verdicts = self.verdicts([
            {"match": "Badge moved", "checks": [{"type": "comp_layer", "path": "draft-v2.comp", "layer": "Badge",
                                                 "baseline": "draft.comp",
                                                 "delta": {"transform.origin.0": 40, "transform.origin.1": -20}}]},
            {"match": "footer logo", "checks": [{"type": "comp_layer", "path": "draft-v2.comp", "layer": "Footer/Logo",
                                                 "baseline": "draft.comp", "delta": {"transform.origin.1": -24}}]},
            {"match": "top logo", "checks": [{"type": "comp_layer", "path": "draft-v2.comp", "layer": "Logo",
                                              "baseline": "draft.comp", "same": ["transform"]}]},
            {"match": "still locked", "checks": [{"type": "comp_layer", "path": "draft-v2.comp", "layer": "Footer",
                                                  "bits": {"locks": 4}}]},
        ])
        self.assertEqual(set(verdicts.values()), {True}, verdicts)

    def test_comp_layer_fails_with_evidence(self):
        self.expectations = ["Badge moved"]
        grading = self.grade([{"match": "Badge moved", "checks": [
            {"type": "comp_layer", "path": "draft-v2.comp", "layer": "Badge", "baseline": "draft.comp",
             "delta": {"transform.origin.0": 50}}]}])
        entry = grading["expectations"][0]
        self.assertFalse(entry["passed"])
        self.assertIn("40", entry["evidence"])

    def test_a_missing_layer_or_file_fails(self):
        self.expectations = ["ghost", "no file"]
        verdicts = self.verdicts([
            {"match": "ghost", "checks": [{"type": "comp_layer", "path": "draft-v2.comp", "layer": "Nope",
                                           "equals": {"opacity": 1}}]},
            {"match": "no file", "checks": [{"type": "comp_layer", "path": "gone.comp", "layer": "Badge",
                                             "equals": {"opacity": 1}}]},
        ])
        self.assertEqual(set(verdicts.values()), {False})


class PSDCheckTests(GradingTestCase):
    TEMPLATE = {"layers": [
        {"index": 0, "depth": 0, "kind": "group", "name": "Card", "bbox": [0, 0, 1080, 1350],
         "locks": {"value": 0, "complete": False, "position": False}},
        {"index": 1, "depth": 1, "kind": "type", "name": "Name", "bbox": [300, 1000, 780, 1064],
         "text": {"text": "Endorser Name"}, "locks": None},
        {"index": 2, "depth": 1, "kind": "shape", "name": "Accent Bar", "bbox": [130, 960, 950, 972],
         "locks": {"value": 2147483648, "complete": True, "position": False}},
        {"index": 3, "depth": 1, "kind": "smartobject", "name": "Photo", "bbox": [130, 120, 950, 940],
         "locks": {"value": 4, "complete": False, "position": True}}],
        "warnings": [], "errors": []}

    def setUp(self):
        super().setUp()
        self.fixtures.mkdir(parents=True)
        (self.fixtures / "templates").mkdir()
        (self.fixtures / "templates" / "card-template.psd").write_bytes(b"template")
        (self.outputs / "templates").mkdir()
        (self.outputs / "templates" / "card-template.psd").write_bytes(b"template")
        (self.outputs / "templates" / "card-jordan.psd").write_bytes(b"new")
        filled = json.loads(json.dumps(self.TEMPLATE))
        filled["layers"][1].update(name="Name", text={"text": "Jordan Rivera"}, bbox=[380, 1000, 700, 1064])
        filled["layers"][2]["bbox"] = [130, 984, 950, 996]
        reports = {"card-template.psd": (0, self.TEMPLATE), "card-jordan.psd": (0, filled)}

        def fake_report(path):
            return reports[Path(path).name]

        original = grader.psd_report
        grader.psd_report = fake_report
        self.addCleanup(setattr, grader, "psd_report", original)

    def test_psd_checks_read_the_report(self):
        self.expectations = ["verifies", "same structure", "name text", "centered", "bar moved", "bar locked"]
        new = {"glob": "templates/*.psd", "exclude": ["templates/card-template.psd"]}
        verdicts = self.verdicts([
            {"match": "verifies", "checks": [{"type": "psd_verify", **new}]},
            {"match": "same structure", "checks": [{"type": "psd_same_structure", **new,
                                                    "baseline": "templates/card-template.psd"}]},
            {"match": "name text", "checks": [{"type": "psd_layer", **new, "layer": "Card/Name",
                                               "equals": {"kind": "type", "text.text": "Jordan Rivera"}}]},
            {"match": "centered", "checks": [{"type": "psd_layer", **new, "layer": "Card/Name", "center_x": 540,
                                              "tolerance": 2}]},
            {"match": "bar moved", "checks": [{"type": "psd_layer", **new, "layer": "Card/Accent Bar",
                                               "baseline": "templates/card-template.psd", "delta": {"bbox.1": 24}}]},
            {"match": "bar locked", "checks": [{"type": "psd_layer", **new, "layer": "Card/Accent Bar",
                                                "equals": {"locks.complete": True}}]},
        ])
        self.assertEqual(set(verdicts.values()), {True}, verdicts)

    def test_layer_equals_takes_operators(self):
        self.expectations = ["name text"]
        new = {"glob": "templates/*.psd", "exclude": ["templates/card-template.psd"]}
        spec = {"match": "name text", "checks": [{"type": "psd_layer", **new, "layer": "Card/Name",
                                                  "equals": {"text.text": {"matches": r"^Jordan Rivera\s*$"},
                                                             "bbox.0": {"<=": 380}}}]}
        self.assertTrue(self.verdicts([spec])["name text"])
        spec["checks"][0]["equals"]["bbox.0"] = {"<": 380}
        self.assertFalse(self.verdicts([spec])["name text"])

    def test_psd_checks_fail_without_a_new_psd(self):
        (self.outputs / "templates" / "card-jordan.psd").unlink()
        self.expectations = ["verifies"]
        self.assertFalse(self.verdicts([{"match": "verifies", "checks": [
            {"type": "psd_verify", "glob": "templates/*.psd", "exclude": ["templates/card-template.psd"]}]}])[
            "verifies"])


class ImageStatCheckTests(GradingTestCase):
    """pixel, image_compare and image_differs read image_stats.py's report (stubbed here: it needs Pillow)."""

    STATS = {
        "out/cutout.png": {"width": 640, "height": 640, "mean_luminance": 0.4, "mean_red_minus_blue": 0.5,
                           "points": {"0,0": {"r": 0, "g": 0, "b": 0, "a": 0},
                                      "center": {"r": 0.9, "g": 0.1, "b": 0.1, "a": 1}}},
        "out/room.jpg": {"width": 16, "height": 10, "mean_luminance": 0.55, "mean_red_minus_blue": 0.05,
                         "points": {}},
        "eval-inputs/room.png": {"width": 16, "height": 10, "mean_luminance": 0.3, "mean_red_minus_blue": 0.4,
                                 "points": {}},
    }

    def setUp(self):
        super().setUp()
        for relative in self.STATS:
            (self.outputs / relative).parent.mkdir(parents=True, exist_ok=True)
            (self.outputs / relative).write_bytes(b"image")
        self.asked = []

        def fake_stats(path, points=(), other=None):
            self.asked.append((Path(path).name, list(points), other and Path(other).name))
            stats = dict(self.STATS[str(Path(path).relative_to(self.outputs))])
            if other is not None:
                stats["diff_fraction"] = 0.0 if Path(other) == Path(path) else 0.37
            return stats

        original = grader.image_stats
        grader.image_stats = fake_stats
        self.addCleanup(setattr, grader, "image_stats", original)

    def test_pixel_checks_a_point_or_the_center(self):
        self.expectations = ["corner clear", "center red", "corner red"]
        verdicts = self.verdicts([
            {"match": "corner clear", "checks": [{"type": "pixel", "path": "out/cutout.png", "x": 0, "y": 0,
                                                  "equals": {"a": {"<=": 0.01}}}]},
            {"match": "center red", "checks": [{"type": "pixel", "path": "out/cutout.png", "x": "center",
                                                "y": "center", "equals": {"a": {">=": 0.99}, "r": {">": 0.7},
                                                                          "g": {"<": 0.3}, "b": {"<": 0.3}}}]},
            {"match": "corner red", "checks": [{"type": "pixel", "path": "out/cutout.png", "x": 0, "y": 0,
                                                "equals": {"r": {">": 0.7}}}]}])
        self.assertEqual(verdicts, {"corner clear": True, "center red": True, "corner red": False})
        self.assertIn(("cutout.png", [[0, 0]], None), self.asked)

    def test_image_compare_relates_a_statistic_of_two_files(self):
        self.expectations = ["brighter", "less orange", "darker"]
        verdicts = self.verdicts([
            {"match": "brighter", "checks": [{"type": "image_compare", "path": "out/room.jpg",
                                              "other": "eval-inputs/room.png", "stat": "mean_luminance",
                                              "relation": ">"}]},
            {"match": "less orange", "checks": [{"type": "image_compare", "path": "out/room.jpg",
                                                 "other": "eval-inputs/room.png", "stat": "mean_red_minus_blue",
                                                 "relation": "<"}]},
            {"match": "darker", "checks": [{"type": "image_compare", "path": "out/room.jpg",
                                            "other": "eval-inputs/room.png", "stat": "mean_luminance",
                                            "relation": "<"}]}])
        self.assertEqual(verdicts, {"brighter": True, "less orange": True, "darker": False})
        evidence = self.grade([{"match": "brighter", "checks": [
            {"type": "image_compare", "path": "out/room.jpg", "other": "eval-inputs/room.png",
             "stat": "mean_luminance", "relation": ">"}]}])["expectations"][0]["evidence"]
        self.assertIn("0.55", evidence)
        self.assertIn("0.3", evidence)

    def test_image_differs_needs_a_share_of_changed_pixels(self):
        self.expectations = ["differs from the input", "differs from itself"]
        verdicts = self.verdicts([
            {"match": "the input", "checks": [{"type": "image_differs", "path": "out/room.jpg",
                                               "other": "eval-inputs/room.png", "min_fraction": 0.01}]},
            {"match": "itself", "checks": [{"type": "image_differs", "path": "out/room.jpg",
                                            "other": "out/room.jpg", "min_fraction": 0.01}]}])
        self.assertEqual(verdicts, {"differs from the input": True, "differs from itself": False})

    def test_image_checks_fail_on_a_missing_file(self):
        self.expectations = ["corner clear"]
        self.assertFalse(self.verdicts([{"match": "corner clear", "checks": [
            {"type": "pixel", "path": "out/none.png", "x": 0, "y": 0, "equals": {"a": 0}}]}])["corner clear"])

    def test_the_specs_are_validated(self):
        self.assertEqual(grader.validate_check({"type": "pixel", "path": "a.png", "x": 0, "y": 0,
                                                "equals": {"a": 0}}), [])
        self.assertTrue(grader.validate_check({"type": "pixel", "path": "a.png", "equals": {"a": 0}}))
        self.assertTrue(grader.validate_check({"type": "image_compare", "path": "a.png", "other": "b.png",
                                               "stat": "sharpness", "relation": ">"}))
        self.assertTrue(grader.validate_check({"type": "image_differs", "path": "a.png"}))


@unittest.skipUnless(shutil.which("uv"), "needs uv to run image_stats.py with Pillow")
class ImageStatsScriptTests(GradingTestCase):
    def test_the_script_reports_means_points_and_differences(self):
        images.write_image({"path": "red.png", "width": 8, "height": 6, "kind": "solid", "from": "#ff0000"},
                           self.outputs)
        images.write_image({"path": "blue.png", "width": 8, "height": 6, "kind": "solid", "from": "#0000ff"},
                           self.outputs)
        stats = grader.image_stats(self.outputs / "red.png", points=[[0, 0], "center"], other=self.outputs / "blue.png")
        self.assertEqual((stats["width"], stats["height"]), (8, 6))
        self.assertAlmostEqual(stats["mean_red_minus_blue"], 1.0, places=3)
        self.assertAlmostEqual(stats["mean_luminance"], 0.2126, places=3)
        self.assertEqual(stats["points"]["center"], {"r": 1.0, "g": 0.0, "b": 0.0, "a": 1.0})
        self.assertEqual(stats["points"]["0,0"]["r"], 1.0)
        self.assertEqual(stats["diff_fraction"], 1.0)


class GradingFileTests(GradingTestCase):
    def test_unscripted_expectations_are_left_for_the_grader_agent(self):
        self.expectations = ["file exists", "The final answer is friendly"]
        (self.outputs / "a.txt").write_text("a")
        grading = self.grade([{"match": "file exists", "checks": [{"type": "exists", "path": "a.txt"}]}])
        self.assertEqual([entry["text"] for entry in grading["expectations"]], ["file exists"])
        self.assertEqual(set(grading["expectations"][0]), {"text", "passed", "evidence"})
        self.assertEqual(grading["needs_grader"], ["The final answer is friendly"])
        self.assertEqual(grading["summary"], {"passed": 1, "failed": 0, "total": 1, "pass_rate": 1.0})
        written = json.loads((self.run / "grading.json").read_text(encoding="utf-8"))
        self.assertEqual(written, grading)
        self.assertEqual(written["execution_metrics"]["total_tool_calls"], 3)
        # skill-creator's aggregate_benchmark reads tokens (and time) from timing.json only when grading.json has
        # no timing.total_duration_seconds; with one, it counts output characters as tokens.
        self.assertNotIn("timing", written)

    def test_regrading_keeps_the_grader_agents_verdicts(self):
        # The grader agent adds its verdicts to grading.json; grading again (a fixed check, a new run next to it)
        # must not throw them away, or every re-grade would need the agent again.
        self.expectations = ["file exists", "The final answer is friendly", "The answer names the file"]
        (self.outputs / "a.txt").write_text("a")
        specs = [{"match": "file exists", "checks": [{"type": "exists", "path": "a.txt"}]}]
        first = self.grade(specs)
        self.assertEqual(first["needs_grader"], ["The final answer is friendly", "The answer names the file"])
        graded = dict(first)
        graded["expectations"] = first["expectations"] + [
            {"text": "The final answer is friendly", "passed": False, "evidence": "It is curt."},
            {"text": "An expectation the eval no longer has", "passed": True, "evidence": "old"}]
        graded["eval_feedback"] = {"suggestions": [], "overall": "No suggestions."}
        graded["claims"] = [{"claim": "Exported a.txt", "type": "process", "verified": True, "evidence": "call 2"}]
        (self.run / "grading.json").write_text(json.dumps(graded), encoding="utf-8")

        (self.outputs / "a.txt").unlink()  # the scripted verdict is recomputed, not carried over
        again = self.grade(specs)
        by_text = {entry["text"]: entry for entry in again["expectations"]}
        self.assertEqual([entry["text"] for entry in again["expectations"]],
                         ["file exists", "The final answer is friendly"], "in the eval's order; stale ones dropped")
        self.assertFalse(by_text["file exists"]["passed"])
        self.assertEqual(by_text["The final answer is friendly"],
                         {"text": "The final answer is friendly", "passed": False, "evidence": "It is curt."})
        self.assertEqual(again["needs_grader"], ["The answer names the file"])
        self.assertEqual(again["summary"], {"passed": 0, "failed": 2, "total": 2, "pass_rate": 0.0})
        self.assertEqual(again["eval_feedback"], graded["eval_feedback"])
        self.assertEqual(again["claims"], graded["claims"])

    def test_grading_points_the_grader_agent_at_the_final_state(self):
        self.expectations = ["The band's opacity is 0.4 (get_document or get_layer)"]
        (self.run / "final-state").mkdir()
        (self.run / "final-state" / "list_documents.json").write_text("{}", encoding="utf-8")
        grading = self.grade([])
        inputs = grading["grader_inputs"]
        self.assertEqual(inputs["transcript"], "transcript.md")
        self.assertEqual(inputs["outputs"], "outputs/")
        self.assertEqual(inputs["final_state"], "final-state/")
        self.assertIn("get_document", inputs["note"])
        self.assertIn("before", inputs["note"])

    def test_without_a_final_state_the_grader_is_told_so(self):
        self.expectations = ["The answer is friendly"]
        self.assertIsNone(self.grade([])["grader_inputs"]["final_state"])

    def test_a_spec_that_matches_no_expectation_is_reported(self):
        self.expectations = ["file exists"]
        grading = self.grade([{"match": "no such text", "checks": [{"type": "exists", "path": "a.txt"}]}])
        self.assertEqual(grading["stale_checks"], ["no such text"])
        self.assertEqual(grading["needs_grader"], ["file exists"])

    def test_the_command_line_grades_every_run_under_a_folder(self):
        self.expectations = ["file exists"]
        (self.outputs / "a.txt").write_text("a")
        self.write_run()
        checks = self.tmp / "checks.json"
        checks.write_text(json.dumps({"skill_name": "demo-skill", "evals": {"1": [
            {"match": "file exists", "checks": [{"type": "exists", "path": "a.txt"}]}]}}), encoding="utf-8")
        result = subprocess.run([sys.executable, "-B", str(GRADE), str(self.tmp), "--checks", str(checks)],
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("1/1", result.stdout)
        self.assertTrue((self.run / "grading.json").is_file())

    def test_an_interrupted_run_without_timing_is_skipped(self):
        self.expectations = ["file exists"]
        self.write_run()
        (self.run / "timing.json").unlink()
        result = subprocess.run([sys.executable, "-B", str(GRADE), str(self.tmp)], capture_output=True, text=True,
                                timeout=60)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("incomplete", result.stderr)
        self.assertIn(str(self.run), result.stderr)
        self.assertFalse((self.run / "grading.json").exists())


class CheckSpecTests(unittest.TestCase):
    """The committed specs in scripts/skills-eval/checks/ must keep up with the evals they grade."""

    def specs(self):
        files = sorted(CHECKS.glob("*.json"))
        self.assertTrue(files, "no check specs")
        return [(path, json.loads(path.read_text(encoding="utf-8"))) for path in files]

    def test_every_spec_matches_exactly_one_expectation_of_its_eval(self):
        for path, spec in self.specs():
            evals = json.loads((REPO / "skills" / spec["skill_name"] / "evals" / "evals.json")
                               .read_text(encoding="utf-8"))["evals"]
            by_id = {str(case["id"]): case["expectations"] for case in evals}
            self.assertEqual(path.stem, spec["skill_name"])
            for eval_id, entries in spec["evals"].items():
                self.assertIn(eval_id, by_id, f"{path.name}: no eval {eval_id}")
                for entry in entries:
                    with self.subTest(file=path.name, eval=eval_id, match=entry["match"]):
                        hits = [text for text in by_id[eval_id] if entry["match"] in text]
                        self.assertEqual(len(hits), 1, hits)

    def test_every_check_is_well_formed(self):
        for path, spec in self.specs():
            for eval_id, entries in spec["evals"].items():
                for entry in entries:
                    with self.subTest(file=path.name, eval=eval_id, match=entry["match"]):
                        self.assertTrue(entry["checks"])
                        for check in entry["checks"]:
                            self.assertEqual(grader.validate_check(check), [])

    def test_validate_check_rejects_unknown_types_and_absolute_paths(self):
        self.assertTrue(grader.validate_check({"type": "telepathy"}))
        self.assertTrue(grader.validate_check({"type": "exists", "path": "/etc/passwd"}))
        self.assertTrue(grader.validate_check({"type": "exists"}))
        self.assertEqual(grader.validate_check({"type": "exists", "path": "a/b.png"}), [])


if __name__ == "__main__":
    unittest.main()
