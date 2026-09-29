"""Tests for scripts/skills-eval/view_outputs.py, which builds what skill-creator's review viewer shows of an
iteration: the viewer lists only the files at the top of each run's outputs/, while the evals write into out/,
exports/ and templates/.

Run from the repository root with the system python3 (no packages needed):
    python3 -B -m unittest discover -s scripts/tests -p 'test_skills_eval*.py'
"""

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from test_skills_eval_support import EVAL_SCRIPTS, load

images = load("fixture_images")
VIEW = EVAL_SCRIPTS / "view_outputs.py"
HAS_SIPS = shutil.which("sips") is not None


class ViewOutputsTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="skills-eval-view-")
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name).resolve()
        self.iteration = self.tmp / "compositor" / "iteration-1"
        self.run = self.iteration / "eval-1" / "with_skill" / "run-1"
        outputs = self.run / "outputs"
        images.write_image({"path": "out/card.png", "width": 40, "height": 30, "kind": "solid", "from": "#336699"},
                           outputs)
        images.write_image({"path": "exports/big.png", "width": 2000, "height": 1000, "kind": "solid",
                            "from": "#996633"}, outputs)
        images.write_image({"path": "eval-inputs/photo.png", "width": 20, "height": 20, "kind": "solid",
                            "from": "#000000"}, outputs)
        (outputs / "templates").mkdir()
        (outputs / "templates" / "card.psd").write_bytes(b"8BPS" + b"\0" * 100)
        (outputs / "metrics.json").write_text(json.dumps({"files_created": [
            "out/card.png", "exports/big.png", "templates/card.psd"]}), encoding="utf-8")
        (self.run / "transcript.md").write_text(
            "# t\n\n## Eval Prompt\n\nMake a card.\n\n## Steps\n\n### 1. Tool: x\n\n## Final Answer\n\n"
            "Saved /abs/out/card.png\n", encoding="utf-8")
        (self.run / "grading.json").write_text(json.dumps({"expectations": [], "summary": {}}), encoding="utf-8")
        (self.run / "timing.json").write_text("{}", encoding="utf-8")
        (self.run / "eval_metadata.json").write_text(json.dumps({"eval_id": 1, "prompt": "Make a card."}),
                                                     encoding="utf-8")
        (self.run.parents[1] / "eval_metadata.json").write_text(json.dumps({"eval_id": 1, "prompt": "Make a card."}),
                                                                encoding="utf-8")
        self.view = self.tmp / "compositor" / "view-iteration-1"

    def build(self):
        result = subprocess.run([sys.executable, "-B", str(VIEW), str(self.iteration), str(self.view)],
                                capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return self.view / "eval-1" / "with_skill" / "run-1"

    def test_what_the_agent_made_is_listed_at_the_top_of_outputs(self):
        run = self.build()
        names = sorted(path.name for path in (run / "outputs").iterdir())
        self.assertIn("out__card.png", names)
        self.assertIn("exports__big.png", names)
        self.assertNotIn("eval-inputs__photo.png", names, "only what the agent made, not the fixtures")
        self.assertEqual((run / "outputs" / "out__card.png").read_bytes(),
                         (self.run / "outputs" / "out" / "card.png").read_bytes())
        answer = (run / "outputs" / "final-answer.md").read_text(encoding="utf-8")
        self.assertIn("Saved /abs/out/card.png", answer)
        listing = (run / "outputs" / "files.txt").read_text(encoding="utf-8")
        for path in ("out/card.png", "exports/big.png", "templates/card.psd"):
            self.assertIn(path, listing)
        for name in ("grading.json", "eval_metadata.json", "transcript.md"):
            self.assertTrue((run / name).is_file(), name)
        self.assertTrue((self.view / "eval-1" / "eval_metadata.json").is_file())
        self.assertEqual(sorted(path.name for path in (self.run / "outputs").iterdir()),
                         ["eval-inputs", "exports", "metrics.json", "out", "templates"], "the run is untouched")

    @unittest.skipUnless(HAS_SIPS, "needs sips")
    def test_large_images_are_shown_scaled_down(self):
        run = self.build()
        info = subprocess.run(["sips", "-g", "pixelWidth", str(run / "outputs" / "exports__big.png")],
                              capture_output=True, text=True).stdout
        self.assertIn("pixelWidth: 1024", info)
        self.assertIn("scaled", (run / "outputs" / "files.txt").read_text(encoding="utf-8"))

    def test_building_again_replaces_the_view(self):
        self.build()
        (self.run / "outputs" / "out" / "card.png").unlink()
        (self.run / "outputs" / "metrics.json").write_text(json.dumps({"files_created": []}), encoding="utf-8")
        run = self.build()
        self.assertFalse((run / "outputs" / "out__card.png").exists())

    def refuse(self, iteration, view):
        result = subprocess.run([sys.executable, "-B", str(VIEW), str(iteration), str(view)],
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("view_outputs:", result.stderr)
        return result

    def assert_the_iteration_is_untouched(self):
        self.assertTrue((self.run / "outputs" / "metrics.json").is_file(), "the iteration was deleted")
        self.assertTrue((self.run / "grading.json").is_file(), "the iteration was deleted")

    def test_refuses_to_build_the_view_inside_the_iteration(self):
        self.refuse(self.iteration, self.iteration / "view")
        self.assertFalse((self.iteration / "view").exists())

    def test_refuses_a_view_that_contains_the_iteration(self):
        # One missing "/view-iteration-1" names the skill's folder (every iteration), and "." the whole checkout.
        # Only ancestors inside the temp folder: a regression must never get to delete anything real.
        for view in (self.iteration.parent, self.tmp):
            with self.subTest(view=str(view)):
                self.refuse(self.iteration, view)
                self.assert_the_iteration_is_untouched()

    def test_refuses_to_replace_a_folder_it_did_not_build(self):
        other = self.tmp / "notes"
        other.mkdir()
        (other / "keep.txt").write_text("mine\n", encoding="utf-8")
        self.refuse(self.iteration, other)
        self.assertEqual((other / "keep.txt").read_text(encoding="utf-8"), "mine\n")
        stray = self.tmp / "stray.txt"
        stray.write_text("mine\n", encoding="utf-8")
        self.refuse(self.iteration, stray)
        self.assertTrue(stray.is_file())

    def test_builds_into_an_empty_folder(self):
        self.view.mkdir(parents=True)
        run = self.build()
        self.assertTrue((run / "outputs" / "files.txt").is_file())

    def test_refuses_an_iteration_that_is_not_a_folder(self):
        self.refuse(self.tmp / "compositor" / "iteration-9", self.view)
        self.assertFalse(self.view.exists())


if __name__ == "__main__":
    unittest.main()
