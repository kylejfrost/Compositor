"""Tests for scripts/skills-eval/grade_agent.py, which has a headless grader agent grade the expectations a script
can't (skill-creator's agents/grader.md) and merges its verdicts into each run's grading.json.

Run from the repository root with the system python3 (no packages needed):
    python3 -B -m unittest discover -s scripts/tests -p 'test_skills_eval*.py'

`claude` is a fake that records how it was started and answers with FAKE_GRADER_ANSWER; runs live in a temporary
folder.
"""

import json
import os
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

from test_skills_eval_support import EVAL_SCRIPTS

GRADE_AGENT = EVAL_SCRIPTS / "grade_agent.py"

FAKE_CLAUDE = textwrap.dedent("""\
    #!/usr/bin/env python3
    import json, os, sys
    from pathlib import Path
    log = Path(os.environ["FAKE_CLAUDE_LOG"])
    calls = json.loads(log.read_text()) if log.exists() else []
    calls.append({"argv": sys.argv[1:], "cwd": os.getcwd(), "stdin": sys.stdin.read()})
    log.write_text(json.dumps(calls))
    print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "duration_ms": 4000,
                      "total_cost_usd": 0.1, "result": os.environ["FAKE_GRADER_ANSWER"],
                      "modelUsage": {"m": {"inputTokens": 100, "outputTokens": 50}}}))
""")

EXPECTATIONS = ["out/x.png exists", "The final answer names the absolute path", "The agent rendered before exporting"]


class GradeAgentTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="skills-eval-grade-agent-")
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name).resolve()
        self.run = self.tmp / "iteration-1" / "eval-1" / "with_skill" / "run-1"
        (self.run / "outputs" / "out").mkdir(parents=True)
        (self.run / "outputs" / "out" / "x.png").write_bytes(b"png")
        (self.run / "final-state").mkdir()
        metadata = {"skill_name": "demo-skill", "eval_id": 1, "prompt": "Export out/x.png and tell me where it is.",
                    "expected_output": "An export and its path.", "assertions": EXPECTATIONS}
        (self.run / "eval_metadata.json").write_text(json.dumps(metadata), encoding="utf-8")
        (self.run / "transcript.jsonl").write_text("{}\n", encoding="utf-8")
        (self.run / "transcript.md").write_text("# run\n\n## Final Answer\n\nSaved /abs/out/x.png\n", encoding="utf-8")
        (self.run / "timing.json").write_text(json.dumps({"total_tokens": 5}), encoding="utf-8")
        self.grading = {
            "expectations": [{"text": EXPECTATIONS[0], "passed": True, "evidence": "out/x.png: found"}],
            "summary": {"passed": 1, "failed": 0, "total": 1, "pass_rate": 1.0},
            "needs_grader": EXPECTATIONS[1:], "stale_checks": [], "grader": "grade_scripted.py",
            "grader_inputs": {"transcript": "transcript.md", "outputs": "outputs/", "final_state": "final-state/",
                              "note": "final-state/ is what Compositor had open."}}
        self.write_grading(self.grading)
        self.instructions = self.tmp / "grader.md"
        self.instructions.write_text("# Grader Agent\n\nEvaluate expectations against a transcript.\n",
                                     encoding="utf-8")
        self.claude = self.tmp / "bin" / "claude"
        self.claude.parent.mkdir()
        self.claude.write_text(FAKE_CLAUDE, encoding="utf-8")
        self.claude.chmod(self.claude.stat().st_mode | stat.S_IEXEC)
        self.log = self.tmp / "claude-log.json"

    def write_grading(self, grading):
        (self.run / "grading.json").write_text(json.dumps(grading), encoding="utf-8")

    def read_grading(self):
        return json.loads((self.run / "grading.json").read_text(encoding="utf-8"))

    def grade(self, answer, *args):
        env = {**os.environ, "FAKE_CLAUDE_LOG": str(self.log), "FAKE_GRADER_ANSWER": answer}
        command = [sys.executable, "-B", str(GRADE_AGENT), str(self.tmp / "iteration-1"), "--claude", str(self.claude),
                   "--instructions", str(self.instructions), "--model", "claude-test", *args]
        return subprocess.run(command, capture_output=True, text=True, env=env, timeout=120)

    def calls(self):
        return json.loads(self.log.read_text(encoding="utf-8")) if self.log.exists() else []


def answer(verdicts, **extra):
    return "Here is my grading.\n```json\n" + json.dumps({"expectations": verdicts, **extra}) + "\n```\n"


class GradeAgentTests(GradeAgentTestCase):
    def test_the_agents_verdicts_are_merged_in_the_evals_order(self):
        verdicts = [{"text": EXPECTATIONS[2], "passed": False, "evidence": "export_image came first (call 3)"},
                    {"text": EXPECTATIONS[1], "passed": True, "evidence": "Final answer: Saved /abs/out/x.png"}]
        result = self.grade(answer(verdicts, claims=[{"claim": "saved", "type": "process", "verified": True,
                                                      "evidence": "call 3"}],
                                   eval_feedback={"suggestions": [], "overall": "No suggestions, evals look solid"}))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        grading = self.read_grading()
        self.assertEqual([entry["text"] for entry in grading["expectations"]], EXPECTATIONS)
        self.assertEqual(grading["expectations"][1],
                         {"text": EXPECTATIONS[1], "passed": True, "evidence": "Final answer: Saved /abs/out/x.png"})
        self.assertEqual(grading["needs_grader"], [])
        self.assertEqual(grading["summary"], {"passed": 2, "failed": 1, "total": 3, "pass_rate": 0.67})
        self.assertEqual(grading["eval_feedback"]["overall"], "No suggestions, evals look solid")
        self.assertEqual(grading["claims"][0]["claim"], "saved")
        self.assertEqual(grading["grader_agent"]["model"], "claude-test")
        self.assertEqual(grading["grader_agent"]["graded"], 2)
        self.assertNotIn("timing", grading, "aggregate_benchmark would read output characters as tokens")
        self.assertIn("2 graded", result.stdout)

    def test_the_prompt_holds_the_instructions_the_expectations_and_where_to_look(self):
        self.grade(answer([]))
        prompt = self.calls()[0]["stdin"]
        self.assertIn("Evaluate expectations against a transcript.", prompt)
        for text in EXPECTATIONS[1:]:
            self.assertIn(text, prompt)
        self.assertNotIn(EXPECTATIONS[0], prompt.split("Expectations to grade")[-1], "the scripted one is done")
        for path in (self.run / "transcript.md", self.run / "outputs", self.run / "final-state"):
            self.assertIn(str(path), prompt)
        self.assertIn("Export out/x.png and tell me where it is.", prompt)
        self.assertIn("final-state/ is what Compositor had open.", prompt)

    def test_the_grader_may_only_read_the_run_and_inspect_its_files(self):
        self.grade(answer([]))
        call = self.calls()[0]
        argv = call["argv"]
        self.assertEqual(Path(call["cwd"]).resolve(), self.run)
        self.assertNotIn("--permission-mode", argv)
        self.assertNotIn("bypassPermissions", " ".join(argv))
        allowed = argv[argv.index("--allowedTools") + 1:]
        run = os.path.realpath(self.run)
        self.assertIn(f"Read(/{run}/**)", allowed)
        self.assertIn("Bash(sips:*)", allowed)
        repo = EVAL_SCRIPTS.parents[1]
        self.assertIn(f"Bash(uv run --with pillow python3 {repo}/scripts/psd-diff.py:*)", allowed)
        self.assertFalse(any(rule.startswith(("Edit", "Write")) for rule in allowed))
        self.assertIn("--strict-mcp-config", argv)
        config = json.loads(argv[argv.index("--mcp-config") + 1])
        self.assertEqual(config, {"mcpServers": {}}, "the grader never talks to Compositor")
        self.assertEqual(argv[argv.index("--model") + 1], "claude-test")

    def test_verdicts_for_other_texts_are_ignored_and_ungraded_ones_stay_open(self):
        verdicts = [{"text": EXPECTATIONS[1], "passed": True, "evidence": "ok"},
                    {"text": "Something the eval never asked", "passed": True, "evidence": "made up"},
                    {"text": EXPECTATIONS[0], "passed": False, "evidence": "the agent overrules the script"}]
        result = self.grade(answer(verdicts))
        self.assertEqual(result.returncode, 0, result.stderr)
        grading = self.read_grading()
        self.assertEqual([entry["text"] for entry in grading["expectations"]], EXPECTATIONS[:2])
        self.assertTrue(grading["expectations"][0]["passed"], "scripted verdicts are the script's")
        self.assertEqual(grading["needs_grader"], [EXPECTATIONS[2]])

    def test_a_run_with_nothing_left_to_grade_is_skipped(self):
        self.grading["needs_grader"] = []
        self.write_grading(self.grading)
        result = self.grade(answer([]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [])
        self.assertIn("nothing to grade", result.stdout)

    def test_an_answer_without_verdicts_changes_nothing_and_fails(self):
        before = (self.run / "grading.json").read_text(encoding="utf-8")
        result = self.grade("I could not decide.")
        self.assertEqual(result.returncode, 1)
        self.assertIn(str(self.run), result.stderr)
        self.assertEqual((self.run / "grading.json").read_text(encoding="utf-8"), before)

    def test_a_run_without_scripted_grading_is_refused(self):
        (self.run / "grading.json").unlink()
        result = self.grade(answer([]))
        self.assertEqual(result.returncode, 1)
        self.assertIn("grade_scripted.py", result.stderr)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
