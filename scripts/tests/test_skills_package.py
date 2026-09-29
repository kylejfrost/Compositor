"""Tests for scripts/package-skills.sh, which stages and packages Compositor's skills as .skill files.

Run from the repository root with the system python3 (no packages needed):
    python3 -B -m unittest discover -s scripts/tests -p test_skills_package.py

A packaged skill (Claude Desktop) or a skill copied into an eval project has no Compositor checkout around it, so the
verification scripts its references run (psd-verify.py, psd-diff.py, photoshop-verify.sh and its .jsx) are copied into
the skill's scripts/ at staging time: scripts/ in the repository stays their one source of truth. Packaging goes
through skill-creator's package_skill.py; here a fake skill-creator stands in for it, and everything is written to
temporary folders.
"""

import os
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "package-skills.sh"
SKILLS = REPO / "skills"
VERIFY_SCRIPTS = ("psd-verify.py", "psd-diff.py", "photoshop-verify.sh", "photoshop-verify.jsx")
BUNDLING = ("compositor-psd-templates", "compositor-variants-and-delivery")

# Stands in for skill-creator's scripts/package_skill.py: zips the folder it is given as <out>/<name>.skill, with
# arcnames relative to the folder's parent (as the real one does), leaving out evals/ at the skill's root.
FAKE_PACKAGE_SKILL = textwrap.dedent("""\
    import sys, zipfile
    from pathlib import Path
    skill, out = Path(sys.argv[1]).resolve(), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out / f"{skill.name}.skill", "w") as archive:
        for path in sorted(skill.rglob("*")):
            relative = path.relative_to(skill.parent)
            if path.is_file() and relative.parts[1:2] != ("evals",):
                archive.write(path, relative)
    print("packaged", skill.name)
""")


class PackageSkillsTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="package-skills-")
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name).resolve()
        self.creator = self.tmp / "skill-creator"
        (self.creator / "scripts").mkdir(parents=True)
        (self.creator / "scripts" / "__init__.py").write_text("", encoding="utf-8")
        (self.creator / "scripts" / "package_skill.py").write_text(FAKE_PACKAGE_SKILL, encoding="utf-8")

    def run_script(self, *args, env=None):
        environment = {**os.environ, "SKILL_CREATOR": str(self.creator), "PACKAGE_SKILLS_PYTHON": "python3",
                       **(env or {})}
        return subprocess.run(["bash", str(SCRIPT), *map(str, args)], capture_output=True, text=True,
                              env=environment, timeout=300)


class StageTests(PackageSkillsTestCase):
    def test_a_template_skill_is_staged_with_the_verification_scripts_and_without_its_evals(self):
        for name in BUNDLING:
            with self.subTest(skill=name):
                staged = self.tmp / "staged" / name
                result = self.run_script("--stage", SKILLS / name, staged)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue((staged / "SKILL.md").is_file())
                self.assertFalse((staged / "evals").exists(), "evals/ holds the expectations; it stays behind")
                for script in VERIFY_SCRIPTS:
                    copy = staged / "scripts" / script
                    self.assertEqual(copy.read_bytes(), (REPO / "scripts" / script).read_bytes(), script)
                    self.assertEqual(copy.stat().st_mode & stat.S_IXUSR,
                                     (REPO / "scripts" / script).stat().st_mode & stat.S_IXUSR, script)
                for path in (SKILLS / name).rglob("*"):
                    relative = path.relative_to(SKILLS / name)
                    if path.is_file() and relative.parts[0] != "evals" and path.name != ".DS_Store":
                        self.assertEqual((staged / relative).read_bytes(), path.read_bytes(), str(relative))

    def test_a_skill_that_bundles_nothing_is_staged_as_it_is(self):
        staged = self.tmp / "staged" / "compositor"
        result = self.run_script("--stage", SKILLS / "compositor", staged)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sorted(path.name for path in (staged / "scripts").iterdir()), ["tool-atlas.py"])
        self.assertFalse((staged / "evals").exists())

    def test_staging_refuses_a_skill_whose_own_script_has_a_bundled_name(self):
        # One source of truth: a skill may not carry its own copy of a script the repository's scripts/ provides.
        skill = self.tmp / "skills" / "compositor-psd-templates"
        shutil.copytree(SKILLS / "compositor-psd-templates", skill)
        (skill / "scripts").mkdir(exist_ok=True)
        (skill / "scripts" / "psd-verify.py").write_text("# a stale copy\n", encoding="utf-8")
        result = self.run_script("--stage", skill, self.tmp / "staged" / "compositor-psd-templates")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("psd-verify.py", result.stderr)

    def test_staging_refuses_an_existing_destination_and_a_missing_skill(self):
        existing = self.tmp / "staged" / "compositor"
        existing.mkdir(parents=True)
        self.assertEqual(self.run_script("--stage", SKILLS / "compositor", existing).returncode, 1)
        missing = self.run_script("--stage", self.tmp / "no-such-skill", self.tmp / "staged" / "x")
        self.assertEqual(missing.returncode, 1)
        self.assertIn("no SKILL.md", missing.stderr)


class PackageTests(PackageSkillsTestCase):
    def test_every_skill_is_packaged_with_its_bundled_scripts(self):
        out = self.tmp / "dist"
        result = self.run_script("--out", out)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr, "", "nothing goes wrong, cleanup included")
        names = sorted(path.parent.name for path in SKILLS.glob("*/SKILL.md"))
        self.assertEqual(sorted(path.name for path in out.iterdir()), sorted(f"{name}.skill" for name in names))
        for name in names:
            with self.subTest(skill=name), zipfile.ZipFile(out / f"{name}.skill") as archive:
                members = archive.namelist()
                self.assertIn(f"{name}/SKILL.md", members)
                self.assertFalse(any(member.startswith(f"{name}/evals/") for member in members))
                bundled = {f"{name}/scripts/{script}" for script in VERIFY_SCRIPTS}
                if name in BUNDLING:
                    self.assertLessEqual(bundled, set(members))
                else:
                    self.assertFalse(bundled & set(members))
        self.assertEqual(list(REPO.glob("skills/*/scripts/psd-verify.py")), [], "the checkout's skills stay as they are")

    def test_named_skills_only(self):
        out = self.tmp / "dist"
        result = self.run_script("--out", out, "compositor", "compositor-psd-templates")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sorted(path.name for path in out.iterdir()),
                         ["compositor-psd-templates.skill", "compositor.skill"])

    def test_an_unknown_skill_or_argument_is_a_usage_error(self):
        self.assertEqual(self.run_script("--out", self.tmp / "dist", "no-such-skill").returncode, 2)
        self.assertEqual(self.run_script("--bogus").returncode, 2)

    def test_without_skill_creator_it_says_where_to_point(self):
        result = self.run_script("--out", self.tmp / "dist", env={"SKILL_CREATOR": str(self.tmp / "nowhere")})
        self.assertEqual(result.returncode, 1)
        self.assertIn("SKILL_CREATOR", result.stderr)
        self.assertFalse((self.tmp / "dist").exists())

    def test_the_script_is_shellcheck_clean(self):
        if not shutil.which("shellcheck"):
            self.skipTest("shellcheck is not installed")
        result = subprocess.run(["shellcheck", str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
