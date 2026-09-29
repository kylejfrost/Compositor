"""Tests for scripts/skills-eval/run_eval.py, which runs one eval prompt through headless Claude Code.

Run from the repository root with the system python3 (no packages needed):
    python3 -B -m unittest discover -s scripts/tests -p 'test_skills_eval*.py'

`claude` is a fake here: a small script that records how it was started and prints a stream-json session. The
endpoint is a stub on an ephemeral loopback port, and the workspace, Agent folder and skills are temporary.
"""

import contextlib
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path

from test_skills_eval_support import EVAL_SCRIPTS, StubCompositor, load

RUN_EVAL = EVAL_SCRIPTS / "run_eval.py"

FAKE_CLAUDE = textwrap.dedent("""\
    #!/usr/bin/env python3
    import json, os, subprocess, sys, time, urllib.request
    from pathlib import Path

    agent = Path(os.environ["FAKE_AGENT_FOLDER"])
    skills_dir = Path.cwd() / ".claude" / "skills"
    record = {
        "pid": os.getpid(),
        "argv": sys.argv[1:],
        "cwd": os.getcwd(),
        "env": {key: os.environ.get(key) for key in ("CLAUDE_CODE_DISABLE_AUTO_MEMORY", "CLAUDECODE", "CLAUDE_EFFORT",
                                                   "CLAUDE_CODE_SESSION_ID", "CFFIXED_USER_HOME")},
        "agent_files": sorted(str(p.relative_to(agent)) for p in agent.rglob("*") if p.is_file()),
        "skills": sorted(p.name for p in skills_dir.iterdir()) if skills_dir.is_dir() else [],
        "skill_files": sorted(str(p.relative_to(skills_dir)) for p in skills_dir.rglob("*") if p.is_file())
                       if skills_dir.is_dir() else [],
        "settings": json.loads((Path.cwd() / ".claude" / "settings.json").read_text()),
    }
    if os.environ.get("FAKE_CLAUDE_BACKGROUND"):
        # commands left running in the background: one in claude's process group, and one in a session of its own,
        # as Claude Code's Bash tool starts every command (it calls setsid), so killing claude's group misses it
        record["background_pids"] = [
            subprocess.Popen(["sleep", "120"], stdout=subprocess.DEVNULL).pid,
            subprocess.Popen(["sleep", "121"], stdout=subprocess.DEVNULL, start_new_session=True).pid]
    if os.environ.get("FAKE_CLAUDE_OPEN"):
        # opens a document through the endpoint and leaves it open, as an agent that never saves does
        config = json.loads(Path(sys.argv[sys.argv.index("--mcp-config") + 1]).read_text())
        call = {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": {"name": "new_document", "arguments": {"name": os.environ["FAKE_CLAUDE_OPEN"]}}}
        request = urllib.request.Request(config["mcpServers"]["compositor"]["url"], data=json.dumps(call).encode(),
                                         headers={"Content-Type": "application/json"})
        urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=30).read()
    Path(os.environ["FAKE_CLAUDE_LOG"]).write_text(json.dumps(record))
    if os.environ.get("FAKE_CLAUDE_SLEEP"):
        time.sleep(float(os.environ["FAKE_CLAUDE_SLEEP"]))
    (agent / "out").mkdir(exist_ok=True)
    (agent / "out" / "x.png").write_bytes(b"png")
    skills = record["skills"] + ["debug"] + os.environ.get("FAKE_CLAUDE_EXTRA_SKILLS", "").split()
    def emit(event):
        print(json.dumps(event), flush=True)
    emit({"type": "system", "subtype": "init", "model": "claude-test", "skills": skills,
          "mcp_servers": [{"name": "compositor", "status": "connected"}], "cwd": os.getcwd()})
    emit({"type": "assistant", "message": {"content": [
        {"type": "text", "text": "Looking at the document."},
        {"type": "tool_use", "id": "t1", "name": "mcp__compositor__get_document", "input": {"detail": "full"}}]}})
    emit({"type": "user", "message": {"content": [
        {"type": "tool_result", "tool_use_id": "t1", "content": [{"type": "text", "text": "{\\"ok\\":true}"}]}]}})
    if os.environ.get("FAKE_CLAUDE_INVOKE"):
        emit({"type": "assistant", "message": {"content": [
            {"type": "tool_use", "id": "s1", "name": "Skill", "input": {"skill": os.environ["FAKE_CLAUDE_INVOKE"]}}]}})
        emit({"type": "user", "message": {"content": [
            {"type": "tool_result", "tool_use_id": "s1", "content": "Launching skill"}]}})
    if os.environ.get("FAKE_CLAUDE_DENIAL"):
        # what Claude Code streams when the allowlist refuses a call: a system event whose message is a string
        emit({"type": "system", "subtype": "permission_denied", "message": "Contains process_substitution"})
    if os.environ.get("FAKE_CLAUDE_BATCH"):
        emit({"type": "assistant", "message": {"content": [
            {"type": "tool_use", "id": "b1", "name": "mcp__compositor__run_batch", "input": {"steps": [
                {"tool": "move_layer", "arguments": {"layer": "Badge", "dx": 4}},
                {"tool": "set_layer_opacity", "arguments": {"layer": "Badge", "opacity": 0.5}}]}}]}})
        emit({"type": "user", "message": {"content": [
            {"type": "tool_result", "tool_use_id": "b1", "content": [{"type": "text", "text": "{\\"ok\\":true}"}]}]}})
    emit({"type": "assistant", "message": {"content": [
        {"type": "tool_use", "id": "t2", "name": "mcp__compositor__export_image", "input": {"path": "out/x.png"}},
        {"type": "tool_use", "id": "t3", "name": "Bash", "input": {"command": "sips -g pixelWidth out/x.png"}}]}})
    emit({"type": "user", "message": {"content": [
        {"type": "tool_result", "tool_use_id": "t2", "content": [{"type": "text", "text": "{\\"ok\\":true}"}]},
        {"type": "tool_result", "tool_use_id": "t3", "content": "no such file", "is_error": True}]}})
    emit({"type": "assistant", "message": {"content": [{"type": "text", "text": "Done: out/x.png"}]}})
    emit({"type": "result", "subtype": "success", "is_error": False, "duration_ms": 1234, "num_turns": 3,
          "result": "Done: out/x.png", "total_cost_usd": 0.5,
          "permission_denials": [{"tool_name": "Bash", "tool_use_id": "t9", "tool_input": {"command": "diff <(a) <(b)"}}]
          if os.environ.get("FAKE_CLAUDE_DENIAL") else [],
          "usage": {"input_tokens": 10, "output_tokens": 20},
          "modelUsage": {"claude-test": {"inputTokens": 10, "outputTokens": 20, "cacheReadInputTokens": 300,
                                         "cacheCreationInputTokens": 40}}})
""")

EVALS = {
    "skill_name": "demo-skill",
    "evals": [
        {"id": 1, "prompt": "Open draft.comp and export out/x.png.", "expected_output": "An export.",
         "files": [], "fixtures": ["draft"], "expectations": ["out/x.png exists", "The answer names the file"]},
        {"id": 2, "prompt": "Fill the card template.", "expected_output": "A card.", "files": [],
         "fixtures": ["template"], "expectations": ["a PSD exists"]},
        {"id": 3, "prompt": "Set Compositor up for my clients.", "expected_output": "The setup lines.", "files": [],
         "mcp": False, "expectations": ["The answer gives the claude mcp add line"]},
    ],
}


@contextlib.contextmanager
def sigint_default():
    ignored = signal.getsignal(signal.SIGINT) is signal.SIG_IGN
    if ignored:
        signal.signal(signal.SIGINT, signal.default_int_handler)
    try:
        yield
    finally:
        if ignored:
            signal.signal(signal.SIGINT, signal.SIG_IGN)


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def gone(pid, seconds=10):
    """Whether process `pid` has ended within `seconds` (an orphan is reaped by launchd a moment after it exits)."""
    deadline = time.monotonic() + seconds
    while alive(pid):
        if time.monotonic() > deadline:
            return False
        time.sleep(0.05)
    return True


def kill_quietly(pid):
    with contextlib.suppress(OSError):
        os.kill(pid, signal.SIGKILL)


class RunEvalTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="skills-eval-run-")
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name).resolve()
        self.workspace = self.tmp / "workspace"
        self.sandbox = self.tmp / "sandbox"
        self.agent = self.sandbox / "home" / "Library" / "Application Support" / "Compositor" / "Agent"
        self.agent.mkdir(parents=True)
        self.skills = self.tmp / "skills"
        skill = self.skills / "demo-skill"
        (skill / "evals").mkdir(parents=True)
        (skill / "references").mkdir()
        (skill / "SKILL.md").write_text("---\nname: demo-skill\ndescription: Demo.\n---\n# Demo\n", encoding="utf-8")
        (skill / "references" / "notes.md").write_text("notes\n", encoding="utf-8")
        (skill / "evals" / "evals.json").write_text(json.dumps(EVALS), encoding="utf-8")
        (skill / "evals" / "fixtures.json").write_text(json.dumps({"skill_name": "demo-skill", "fixtures": []}),
                                                       encoding="utf-8")
        fixtures = self.workspace / "fixtures" / "demo-skill"
        (fixtures / "draft.comp").mkdir(parents=True)
        (fixtures / "draft.comp" / "manifest.json").write_text("{}", encoding="utf-8")
        (fixtures / "eval-inputs").mkdir()
        (fixtures / "eval-inputs" / "logo.png").write_bytes(b"logo")
        manifest = {"skill": "demo-skill", "fixture_dir": str(fixtures), "ok": False,
                    "files": {"draft.comp/manifest.json": "x", "eval-inputs/logo.png": "y"},
                    "fixtures": [{"id": "draft", "ok": True, "error": None, "outputs": ["draft.comp"]},
                                 {"id": "template", "ok": False, "outputs": ["templates/card.psd"],
                                  "error": "call 2 save_document_as failed: unsupported: Compositor can't write "
                                           "Photoshop files yet."}]}
        (self.workspace / "fixtures" / "demo-skill.manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        self.claude = self.tmp / "bin" / "claude"
        self.claude.parent.mkdir()
        self.claude.write_text(FAKE_CLAUDE, encoding="utf-8")
        self.claude.chmod(self.claude.stat().st_mode | stat.S_IEXEC)
        self.log = self.tmp / "claude-log.json"

    def eval_command(self, *args, agent=None, extra_env=None, stub=None):
        env = {**os.environ, "SKILLS_EVAL_SANDBOX": str(self.sandbox),
               "FAKE_AGENT_FOLDER": str(agent or self.agent), "FAKE_CLAUDE_LOG": str(self.log),
               "CLAUDECODE": "1", "CLAUDE_EFFORT": "high", "CLAUDE_CODE_SESSION_ID": "outer-session",
               **(extra_env or {})}
        command = [sys.executable, "-B", str(RUN_EVAL), "--skill", "demo-skill", "--skills-root", str(self.skills),
                   "--workspace", str(self.workspace), "--claude", str(self.claude), "--endpoint", stub.url,
                   "--model", "claude-test", *args]
        return command, env

    def run_eval(self, *args, **kwargs):
        command, env = self.eval_command(*args, **kwargs)
        return subprocess.run(command, capture_output=True, text=True, env=env, timeout=120)

    def start_eval(self, *args, **kwargs):
        """run_eval in the background, with Python's default SIGINT handling even when this process ignores SIGINT
        (a child inherits an ignored SIGINT, as under `nohup` or `&` in a script, and would then never see Ctrl-C)."""
        command, env = self.eval_command(*args, **kwargs)
        with sigint_default():
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        return process

    def wait_for_claude(self, process, seconds=30):
        """The fake claude's record, once it has started (the run_eval `process` must still be running)."""
        deadline = time.monotonic() + seconds
        while not self.log.exists():
            self.assertIsNone(process.poll(), "run_eval ended before claude started")
            self.assertLess(time.monotonic(), deadline, "claude never started")
            time.sleep(0.05)
        time.sleep(0.3)
        record = self.recorded()
        for pid in [record["pid"], *record.get("background_pids", [])]:
            self.addCleanup(kill_quietly, pid)
        return record

    def run_dir(self, config, eval_id=1, iteration=1, run=1):
        return self.workspace / "demo-skill" / f"iteration-{iteration}" / f"eval-{eval_id}" / config / f"run-{run}"

    def recorded(self):
        return json.loads(self.log.read_text(encoding="utf-8"))


class RunLayoutTests(RunEvalTestCase):
    def test_a_with_skill_run_writes_the_skill_creator_layout(self):
        with StubCompositor(self.agent) as stub:
            result = self.run_eval("--eval", "1", "--config", "with_skill", stub=stub)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        run = self.run_dir("with_skill")
        for name in ("transcript.jsonl", "transcript.md", "timing.json", "eval_metadata.json", "outputs/metrics.json"):
            self.assertTrue((run / name).is_file(), name)
        metadata = json.loads((run.parents[1] / "eval_metadata.json").read_text(encoding="utf-8"))
        self.assertEqual(metadata["eval_id"], 1)
        self.assertEqual(metadata["prompt"], EVALS["evals"][0]["prompt"])
        self.assertEqual(metadata["assertions"], EVALS["evals"][0]["expectations"])
        self.assertEqual(json.loads((run / "eval_metadata.json").read_text(encoding="utf-8"))["configuration"],
                         "with_skill")

    def test_the_skill_is_copied_into_the_project_without_its_evals(self):
        with StubCompositor(self.agent) as stub:
            self.run_eval("--eval", "1", "--config", "with_skill", stub=stub)
        record = self.recorded()
        self.assertEqual(record["skills"], ["demo-skill"])
        self.assertIn("demo-skill/SKILL.md", record["skill_files"])
        self.assertIn("demo-skill/references/notes.md", record["skill_files"])
        self.assertFalse(any("/evals/" in path for path in record["skill_files"]), record["skill_files"])

    def add_entry_skill(self):
        entry = self.skills / "compositor"
        (entry / "scripts").mkdir(parents=True)
        (entry / "evals").mkdir()
        (entry / "SKILL.md").write_text("---\nname: compositor\ndescription: Entry.\n---\n# Entry\n", encoding="utf-8")
        (entry / "scripts" / "tool-atlas.py").write_text("print('atlas')\n", encoding="utf-8")
        (entry / "evals" / "evals.json").write_text("{}", encoding="utf-8")
        return entry

    def test_a_workflow_skill_is_evaluated_with_the_entry_skill_it_builds_on(self):
        # The workflow skills send agents to the compositor skill first ("Read the compositor skill first"), and every
        # install ships them together, so with_skill has both; the baseline has neither.
        self.add_entry_skill()
        with StubCompositor(self.agent) as stub:
            result = self.run_eval("--eval", "1", "--config", "with_skill", stub=stub,
                                   extra_env={"FAKE_CLAUDE_EXTRA_SKILLS": "compositor"})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            record = self.recorded()
            self.assertEqual(record["skills"], ["compositor", "demo-skill"])
            self.assertIn("compositor/SKILL.md", record["skill_files"])
            self.assertNotIn("compositor/evals/evals.json", record["skill_files"])
            argv = record["argv"]
            scripts = Path(record["cwd"]) / ".claude" / "skills" / "compositor" / "scripts"
            self.assertIn(f"Bash(python3 {scripts}/tool-atlas.py:*)", argv[argv.index("--allowedTools") + 1:])
            metadata = json.loads((self.run_dir("with_skill") / "eval_metadata.json").read_text(encoding="utf-8"))
            self.assertEqual(metadata["skills_installed"], ["demo-skill", "compositor"])
            baseline = self.run_eval("--eval", "1", "--config", "without_skill", stub=stub)
            self.assertEqual(baseline.returncode, 0, baseline.stderr)
            self.assertEqual(self.recorded()["skills"], [])

    def test_the_entry_skill_itself_is_evaluated_alone(self):
        entry = self.add_entry_skill()
        (entry / "evals" / "evals.json").write_text(json.dumps({**EVALS, "skill_name": "compositor"}), encoding="utf-8")
        manifest = json.loads((self.workspace / "fixtures" / "demo-skill.manifest.json").read_text(encoding="utf-8"))
        (entry / "evals" / "fixtures.json").write_text(json.dumps({"skill_name": "compositor", "fixtures": []}),
                                                      encoding="utf-8")
        (self.workspace / "fixtures" / "compositor.manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        with StubCompositor(self.agent) as stub:
            command, env = self.eval_command("--eval", "1", "--config", "with_skill", stub=stub)
            command[command.index("demo-skill")] = "compositor"
            result = subprocess.run(command, capture_output=True, text=True, env=env, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.recorded()["skills"], ["compositor"])

    def test_a_without_skill_run_has_no_skill_and_the_same_guard_settings(self):
        with StubCompositor(self.agent) as stub:
            self.run_eval("--eval", "1", "--config", "with_skill", stub=stub)
            with_settings = self.recorded()["settings"]
            result = self.run_eval("--eval", "1", "--config", "without_skill", stub=stub)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        record = self.recorded()
        self.assertEqual(record["skills"], [])
        self.assertEqual(record["settings"], with_settings)

    def test_the_project_is_in_the_sandbox_and_its_path_does_not_reveal_the_configuration(self):
        with StubCompositor(self.agent) as stub:
            self.run_eval("--eval", "1", "--config", "without_skill", stub=stub)
        cwd = Path(self.recorded()["cwd"]).resolve()
        self.assertIn(self.sandbox, cwd.parents, "outside any checkout, so the session sees no repository")
        self.assertNotIn("skill", cwd.name)
        self.assertNotIn("with_skill", str(cwd))
        self.assertNotIn("without_skill", str(cwd))

    def test_claude_runs_headless_with_only_the_compositor_server_and_project_settings(self):
        with StubCompositor(self.agent) as stub:
            self.run_eval("--eval", "1", "--config", "with_skill", stub=stub)
        argv = self.recorded()["argv"]
        self.assertEqual(argv[:2], ["-p", EVALS["evals"][0]["prompt"]])

        def value(flag):
            self.assertIn(flag, argv)
            return argv[argv.index(flag) + 1]

        config = json.loads(Path(value("--mcp-config")).read_text(encoding="utf-8"))
        self.assertEqual(config, {"mcpServers": {"compositor": {"type": "http", "url": stub.url}}})
        self.assertIn("--strict-mcp-config", argv)
        self.assertEqual(value("--output-format"), "stream-json")
        self.assertIn("--verbose", argv)
        # Never a blanket bypass: the session gets an explicit allowlist (see test_the_session_may_use_...).
        self.assertNotIn("--permission-mode", argv)
        self.assertNotIn("bypassPermissions", " ".join(argv))
        self.assertNotIn("--dangerously-skip-permissions", argv)
        self.assertIn("--allowedTools", argv)
        self.assertEqual(value("--setting-sources"), "project,local")
        self.assertIn("--no-session-persistence", argv)
        self.assertEqual(value("--model"), "claude-test")

    def test_an_eval_can_run_without_compositors_tools(self):
        # A setup question comes from someone whose clients aren't connected yet: the session gets no MCP server (the
        # instance's own port would otherwise leak into the setup lines) and no Compositor rule.
        with StubCompositor(self.agent) as stub:
            result = self.run_eval("--eval", "3", "--config", "with_skill", stub=stub)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        argv = self.recorded()["argv"]
        config = json.loads(Path(argv[argv.index("--mcp-config") + 1]).read_text(encoding="utf-8"))
        self.assertEqual(config, {"mcpServers": {}})
        self.assertNotIn("mcp__compositor", argv[argv.index("--allowedTools") + 1:])
        self.assertIn("--strict-mcp-config", argv)

    def test_the_session_does_not_inherit_the_calling_claude_sessions_environment(self):
        with StubCompositor(self.agent) as stub:
            self.run_eval("--eval", "1", "--config", "with_skill", stub=stub)
        env = self.recorded()["env"]
        self.assertEqual(env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"], "1")
        self.assertIsNone(env["CLAUDECODE"])
        self.assertIsNone(env["CLAUDE_EFFORT"])
        self.assertIsNone(env["CLAUDE_CODE_SESSION_ID"])

    def allowed(self):
        argv = self.recorded()["argv"]
        return argv[argv.index("--allowedTools") + 1:]

    def test_the_session_may_use_only_the_allowlisted_tools(self):
        # In -p mode a tool call that no rule allows is denied: Compositor's tools, file tools inside the sandbox
        # (the project and the instance's Agent folder), a few inspection commands, and the repository's PSD checks.
        with StubCompositor(self.agent) as stub:
            self.run_eval("--eval", "1", "--config", "without_skill", stub=stub)
        sandbox = os.path.realpath(self.sandbox)
        # macOS reports /private/tmp and /private/var paths as /tmp and /var (Compositor's results do), and the
        # rules match the text of a path: both spellings are allowed.
        self.assertTrue(sandbox.startswith("/private/"), sandbox)
        alias = sandbox[len("/private"):]
        repo = EVAL_SCRIPTS.parents[1]
        self.assertEqual(self.allowed(), [
            "mcp__compositor",
            f"Read(/{sandbox}/**)", f"Read(/{alias}/**)", f"Edit(/{sandbox}/**)", f"Edit(/{alias}/**)",
            f"Write(/{sandbox}/**)", f"Write(/{alias}/**)",
            "Bash(sips:*)", "Bash(shasum:*)", "Bash(ls:*)", "Bash(file:*)", "Bash(mkdir:*)", "Bash(cp:*)",
            f"Bash(uv run --with psd-tools python3 {repo}/scripts/psd-verify.py:*)",
            f'Bash(uv run --with psd-tools python3 "{repo}/scripts/psd-verify.py":*)',
            f"Bash(python3 {repo}/scripts/psd-diff.py:*)",
            f'Bash(python3 "{repo}/scripts/psd-diff.py":*)',
            f"Bash(uv run --with pillow python3 {repo}/scripts/psd-diff.py:*)",
            f'Bash(uv run --with pillow python3 "{repo}/scripts/psd-diff.py":*)',
        ])

    def test_a_with_skill_session_may_also_run_the_skills_own_scripts_but_never_photoshop(self):
        # A staged psd-templates skill carries the repository's verification scripts; photoshop-verify.sh drives the
        # owner's live Photoshop, which only the operator runs, one check at a time.
        skill = self.skills / "compositor-psd-templates"
        shutil.copytree(self.skills / "demo-skill", skill)
        (skill / "SKILL.md").write_text("---\nname: compositor-psd-templates\ndescription: Demo.\n---\n# Demo\n",
                                        encoding="utf-8")
        (skill / "scripts").mkdir()
        (skill / "scripts" / "slots.sh").write_text("#!/bin/bash\necho slots\n", encoding="utf-8")
        evals = json.loads((skill / "evals" / "evals.json").read_text(encoding="utf-8"))
        evals["skill_name"] = "compositor-psd-templates"
        (skill / "evals" / "evals.json").write_text(json.dumps(evals), encoding="utf-8")
        manifest = json.loads((self.workspace / "fixtures" / "demo-skill.manifest.json").read_text(encoding="utf-8"))
        manifest["skill"] = "compositor-psd-templates"
        (self.workspace / "fixtures" / "compositor-psd-templates.manifest.json").write_text(json.dumps(manifest),
                                                                                           encoding="utf-8")
        with StubCompositor(self.agent) as stub:
            command, env = self.eval_command("--eval", "1", "--config", "with_skill", stub=stub)
            command[command.index("demo-skill")] = "compositor-psd-templates"
            result = subprocess.run(command, capture_output=True, text=True, env=env, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        record = self.recorded()
        for script in ("psd-verify.py", "psd-diff.py", "photoshop-verify.sh", "photoshop-verify.jsx", "slots.sh"):
            self.assertIn(f"compositor-psd-templates/scripts/{script}", record["skill_files"])
        scripts = Path(record["cwd"]) / ".claude" / "skills" / "compositor-psd-templates" / "scripts"
        allowed = self.allowed()
        # Rules match command text: a script path written in quotes is another text, and the skills tell agents to
        # quote the paths they pass.
        for rule in (f"Bash({scripts}/slots.sh:*)", f"Bash(bash {scripts}/slots.sh:*)",
                     f"Bash(uv run --with psd-tools python3 {scripts}/psd-verify.py:*)",
                     f'Bash(uv run --with psd-tools python3 "{scripts}/psd-verify.py":*)',
                     f'Bash("{scripts}/slots.sh":*)',
                     f"Bash(uv run --with pillow python3 {scripts}/psd-diff.py:*)"):
            self.assertIn(rule, allowed)
        self.assertEqual([rule for rule in allowed if "photoshop" in rule], [])
        self.assertFalse(any(rule in ("Bash", "Bash(*)", "Read", "Edit", "Write") for rule in allowed))

    def test_guard_settings_deny_protected_folders_and_client_configuration(self):
        with StubCompositor(self.agent) as stub:
            self.run_eval("--eval", "1", "--config", "without_skill", stub=stub)
        deny = self.recorded()["settings"]["permissions"]["deny"]
        for rule in ("Read(~/Documents/**)", "Read(~/Desktop/**)", "Read(~/Downloads/**)",
                     "Read(~/Library/Mobile Documents/**)", "Read(~/Library/CloudStorage/**)", "Read(//Volumes/**)",
                     "Edit(~/.claude.json)", "Edit(~/.codex/**)", "Edit(~/Library/Application Support/Claude/**)",
                     "Bash(claude mcp:*)", "Bash(codex mcp:*)", "Bash(defaults write:*)", "Bash(open:*)",
                     "Bash(osascript:*)",
                     # tools that would reach past the session: the network, the owner's devices, other sessions
                     # and schedules outliving the run
                     "WebFetch", "WebSearch", "PushNotification", "SendMessage", "RemoteTrigger", "CronCreate",
                     "ScheduleWakeup"):
            self.assertIn(rule, deny)


class AccessTokenTests(RunEvalTestCase):
    TOKEN = "tests-only-not-a-real-access-token-00000001"  # 43 base64url characters, made up for these tests

    def record_instance_token(self):
        """The state instance.sh leaves for an instance that requires its access token: the token file it keeps in the
        sandbox home, named in state.json."""
        token_file = self.sandbox / "home" / "Library" / "Application Support" / "Compositor" / "mcp" / "token"
        token_file.parent.mkdir(parents=True, exist_ok=True)
        token_file.write_text(self.TOKEN, encoding="utf-8")
        token_file.chmod(0o600)
        state = self.workspace / "instance" / "state.json"
        state.parent.mkdir(parents=True, exist_ok=True)
        state.write_text(json.dumps({"url": "http://127.0.0.1:1/mcp", "token_file": str(token_file)}), encoding="utf-8")

    def test_run_eval_and_the_session_send_the_instances_token_which_no_saved_file_holds(self):
        self.record_instance_token()
        with StubCompositor(self.agent, token=self.TOKEN) as stub:
            result = self.run_eval("--eval", "1", "--config", "with_skill", stub=stub)
            calls = stub.tool_names()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("get_app_info", calls, "run_eval's own calls must carry the token")
        argv = self.recorded()["argv"]
        config_path = Path(argv[argv.index("--mcp-config") + 1])
        self.assertEqual(json.loads(config_path.read_text(encoding="utf-8")),
                         {"mcpServers": {"compositor": {"type": "http", "url": stub.url,
                                                        "headers": {"Authorization": f"Bearer {self.TOKEN}"}}}})
        self.assertEqual(stat.S_IMODE(config_path.stat().st_mode), 0o600)
        self.assertTrue(config_path.is_relative_to(self.sandbox), config_path)
        self.assertNotIn(self.TOKEN, " ".join(argv))
        self.assertNotIn(self.TOKEN, result.stdout + result.stderr)
        for path in self.run_dir("with_skill").rglob("*"):
            if path.is_file():
                self.assertNotIn(self.TOKEN, path.read_text(encoding="utf-8", errors="ignore"), str(path))

    def test_without_a_token_the_config_has_no_headers(self):
        with StubCompositor(self.agent) as stub:
            self.run_eval("--eval", "1", "--config", "with_skill", stub=stub)
        argv = self.recorded()["argv"]
        config_path = Path(argv[argv.index("--mcp-config") + 1])
        self.assertNotIn("headers", json.loads(config_path.read_text(encoding="utf-8"))["mcpServers"]["compositor"])
        self.assertEqual(stat.S_IMODE(config_path.stat().st_mode), 0o600)

    def test_an_eval_without_compositors_tools_gets_no_server_and_no_token(self):
        self.record_instance_token()
        with StubCompositor(self.agent, token=self.TOKEN) as stub:
            result = self.run_eval("--eval", "3", "--config", "with_skill", stub=stub)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        argv = self.recorded()["argv"]
        config_path = Path(argv[argv.index("--mcp-config") + 1])
        self.assertEqual(json.loads(config_path.read_text(encoding="utf-8")), {"mcpServers": {}})
        self.assertEqual(stat.S_IMODE(config_path.stat().st_mode), 0o600)


class AgentFolderTests(RunEvalTestCase):
    def test_the_agent_folder_starts_with_only_the_skills_fixtures_and_ends_up_in_outputs(self):
        (self.agent / "left-over.png").write_bytes(b"old")
        with StubCompositor(self.agent) as stub:
            result = self.run_eval("--eval", "1", "--config", "with_skill", stub=stub)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.recorded()["agent_files"], ["draft.comp/manifest.json", "eval-inputs/logo.png"])
        outputs = self.run_dir("with_skill") / "outputs"
        self.assertTrue((outputs / "out" / "x.png").is_file())
        self.assertTrue((outputs / "draft.comp" / "manifest.json").is_file())
        self.assertFalse((outputs / "left-over.png").exists())
        self.assertEqual(list(self.agent.iterdir()), [], "the Agent folder is empty again")
        before = json.loads((self.run_dir("with_skill") / "agent-folder-before.json").read_text(encoding="utf-8"))
        self.assertEqual(sorted(before), ["draft.comp/manifest.json", "eval-inputs/logo.png"])

    def test_the_app_is_reset_before_and_after_the_session(self):
        with StubCompositor(self.agent) as stub:
            stub.tabs = [{"tab_id": "a", "document_id": "d1", "title": "draft", "is_modified": True}]
            self.run_eval("--eval", "1", "--config", "with_skill", stub=stub)
            closes = [arguments for name, arguments in stub.calls if name == "close_document"]
            self.assertTrue(closes)
            self.assertTrue(all(arguments.get("discard_changes") is True for arguments in closes))
            self.assertEqual(stub.tool_names()[-1], "list_documents")
            self.assertEqual(stub.tabs[0]["document_id"], None)

    def test_refuses_an_agent_folder_outside_the_sandbox_and_touches_nothing(self):
        elsewhere = self.tmp / "real-agent-folder"
        elsewhere.mkdir()
        (elsewhere / "keep.png").write_bytes(b"keep")
        with StubCompositor(elsewhere) as stub:
            result = self.run_eval("--eval", "1", "--config", "with_skill", agent=elsewhere, stub=stub)
        self.assertEqual(result.returncode, 1)
        self.assertIn("outside", result.stderr)
        self.assertTrue((elsewhere / "keep.png").is_file())
        self.assertFalse(self.log.exists(), "claude was not started")

    def test_refuses_a_sandbox_that_holds_the_home_folder(self):
        home = self.sandbox / "user"
        home.mkdir()
        with StubCompositor(self.agent) as stub:
            result = self.run_eval("--eval", "1", "--config", "with_skill", stub=stub, extra_env={"HOME": str(home)})
        self.assertEqual(result.returncode, 1)
        self.assertIn("home folder", result.stderr)
        self.assertFalse(self.log.exists())

    def test_an_endpoint_that_fails_is_refused_without_leaving_a_run_folder(self):
        with StubCompositor(self.agent, failures={"list_documents": "busy"}) as stub:
            result = self.run_eval("--eval", "1", "--config", "with_skill", stub=stub)
        self.assertEqual(result.returncode, 1)
        self.assertIn("busy", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertFalse(self.run_dir("with_skill").exists())
        self.assertFalse(self.log.exists())

    def test_refuses_an_eval_whose_fixture_failed_to_replay(self):
        with StubCompositor(self.agent) as stub:
            result = self.run_eval("--eval", "2", "--config", "with_skill", stub=stub)
        self.assertEqual(result.returncode, 1)
        self.assertIn("template", result.stderr)
        self.assertIn("unsupported", result.stderr)
        self.assertFalse(self.log.exists())

    def test_refuses_to_overwrite_a_run_unless_forced(self):
        with StubCompositor(self.agent) as stub:
            self.assertEqual(self.run_eval("--eval", "1", "--config", "with_skill", stub=stub).returncode, 0)
            again = self.run_eval("--eval", "1", "--config", "with_skill", stub=stub)
            self.assertEqual(again.returncode, 1)
            self.assertIn("--force", again.stderr)
            forced = self.run_eval("--eval", "1", "--config", "with_skill", "--force", stub=stub)
            self.assertEqual(forced.returncode, 0, forced.stderr)

    def test_a_forced_run_that_is_refused_keeps_the_old_results(self):
        with StubCompositor(self.agent) as stub:
            self.assertEqual(self.run_eval("--eval", "1", "--config", "with_skill", stub=stub).returncode, 0)
        timing = self.run_dir("with_skill") / "timing.json"
        self.assertTrue(timing.is_file())
        elsewhere = self.tmp / "real-agent-folder"
        elsewhere.mkdir()
        with StubCompositor(elsewhere) as stub:
            refused = self.run_eval("--eval", "1", "--config", "with_skill", "--force", agent=elsewhere, stub=stub)
        self.assertEqual(refused.returncode, 1, refused.stderr)
        self.assertIn("outside", refused.stderr)
        self.assertTrue(timing.is_file(), "--force deleted the old run although the new one was refused")


class TranscriptAndTimingTests(RunEvalTestCase):
    def run_once(self, *args, **kwargs):
        with StubCompositor(self.agent) as stub:
            result = self.run_eval("--eval", "1", "--config", "with_skill", *args, stub=stub, **kwargs)
        run = self.run_dir("with_skill")
        return result, run

    def test_timing_holds_tokens_and_duration_from_the_result_event(self):
        result, run = self.run_once()
        self.assertEqual(result.returncode, 0, result.stderr)
        timing = json.loads((run / "timing.json").read_text(encoding="utf-8"))
        self.assertEqual(timing["total_tokens"], 370)
        self.assertEqual(timing["duration_ms"], 1234)
        self.assertEqual(timing["executor_model"], "claude-test")
        self.assertFalse(timing["timed_out"])
        self.assertGreater(timing["total_duration_seconds"], 0)
        for key in ("executor_start", "executor_end", "executor_duration_seconds", "total_cost_usd", "num_turns"):
            self.assertIn(key, timing)

    def test_the_markdown_transcript_has_the_prompt_the_calls_and_the_answer(self):
        _, run = self.run_once()
        text = (run / "transcript.md").read_text(encoding="utf-8")
        self.assertIn("## Eval Prompt\n\n" + EVALS["evals"][0]["prompt"], text)
        self.assertIn("get_document", text)
        self.assertIn("export_image", text)
        self.assertIn("sips -g pixelWidth", text)
        self.assertIn("Done: out/x.png", text)
        self.assertEqual((run / "transcript.jsonl").read_text(encoding="utf-8").count("\n"), 7)

    def test_metrics_count_tool_calls_errors_and_created_files(self):
        _, run = self.run_once()
        metrics = json.loads((run / "outputs" / "metrics.json").read_text(encoding="utf-8"))
        self.assertEqual(metrics["tool_calls"], {"get_document": 1, "export_image": 1, "Bash": 1})
        self.assertEqual(metrics["total_tool_calls"], 3)
        self.assertEqual(metrics["errors_encountered"], 1)
        self.assertEqual(metrics["files_created"], ["out/x.png"])

    def test_a_run_batch_counts_as_one_call_in_metrics_and_timing_and_its_steps_are_counted_apart(self):
        result, run = self.run_once(extra_env={"FAKE_CLAUDE_BATCH": "1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        metrics = json.loads((run / "outputs" / "metrics.json").read_text(encoding="utf-8"))
        timing = json.loads((run / "timing.json").read_text(encoding="utf-8"))
        self.assertEqual(metrics["tool_calls"], {"get_document": 1, "run_batch": 1, "export_image": 1, "Bash": 1})
        self.assertEqual(metrics["total_tool_calls"], 4)
        self.assertEqual(metrics["batched_calls"], 2)
        self.assertEqual(timing["tool_calls"], metrics["total_tool_calls"])

    def test_permission_denials_are_recorded_and_their_events_read(self):
        # A refused call streams a system event whose "message" is a string, not a message object.
        result, run = self.run_once(extra_env={"FAKE_CLAUDE_DENIAL": "1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        timing = json.loads((run / "timing.json").read_text(encoding="utf-8"))
        self.assertEqual(timing["permission_denials"], [{"tool": "Bash", "input": {"command": "diff <(a) <(b)"}}])
        self.assertIn("export_image", (run / "transcript.md").read_text(encoding="utf-8"))

    def test_a_with_skill_run_records_whether_the_skill_was_invoked(self):
        result, run = self.run_once(extra_env={"FAKE_CLAUDE_INVOKE": "demo-skill"})
        self.assertEqual(result.returncode, 0, result.stderr)
        timing = json.loads((run / "timing.json").read_text(encoding="utf-8"))
        self.assertTrue(timing["skill_loaded"])
        self.assertTrue(timing["skill_invoked"])
        self.assertNotIn("never invoked", result.stderr)

    def test_a_with_skill_run_that_never_invokes_the_skill_says_so(self):
        # Listed is not used: an agent that never calls the Skill tool ran as a baseline would, which points at the
        # skill's description rather than its body.
        result, run = self.run_once()
        self.assertEqual(result.returncode, 0, result.stderr)
        timing = json.loads((run / "timing.json").read_text(encoding="utf-8"))
        self.assertTrue(timing["skill_loaded"])
        self.assertFalse(timing["skill_invoked"])
        self.assertIn("never invoked demo-skill", result.stderr)

    def test_a_baseline_that_sees_a_compositor_skill_is_flagged_as_contaminated(self):
        with StubCompositor(self.agent) as stub:
            result = self.run_eval("--eval", "1", "--config", "without_skill", stub=stub,
                                   extra_env={"FAKE_CLAUDE_EXTRA_SKILLS": "compositor-setup"})
        self.assertEqual(result.returncode, 1)
        self.assertIn("contaminated", result.stderr)
        timing = json.loads((self.run_dir("without_skill") / "timing.json").read_text(encoding="utf-8"))
        self.assertEqual(timing["contamination"], ["compositor-setup"])

    def test_a_session_past_its_timeout_is_stopped_and_recorded(self):
        result, run = self.run_once("--timeout", "2", extra_env={"FAKE_CLAUDE_SLEEP": "30"})
        self.assertEqual(result.returncode, 3, result.stderr)
        timing = json.loads((run / "timing.json").read_text(encoding="utf-8"))
        self.assertTrue(timing["timed_out"])
        self.assertLess(timing["total_duration_seconds"], 20)
        self.assertTrue((run / "outputs").is_dir())


class StoppingTests(RunEvalTestCase):
    """No claude session outlives its run: a session left running would go on working on the shared instance and its
    one Agent folder while the next run resets and refills them."""

    def interrupt(self, signum):
        with StubCompositor(self.agent) as stub:
            process = self.start_eval("--eval", "1", "--config", "with_skill", stub=stub,
                                      extra_env={"FAKE_CLAUDE_SLEEP": "60", "FAKE_CLAUDE_BACKGROUND": "1"})
            record = self.wait_for_claude(process)
            self.assertTrue(alive(record["pid"]))
            started = time.monotonic()
            process.send_signal(signum)
            _, stderr = process.communicate(timeout=60)
        return process.returncode, stderr, record, time.monotonic() - started

    def check_stopped(self, returncode, stderr, record, seconds):
        self.assertNotEqual(returncode, 0)
        self.assertTrue(gone(record["pid"]), "the claude session is still running after run_eval ended")
        for pid in record["background_pids"]:
            self.assertTrue(gone(pid), f"a command the session left in the background still runs ({pid})")
        self.assertLess(seconds, 30)
        self.assertIn("stopped", stderr)
        self.assertNotIn("Traceback", stderr)
        run = self.run_dir("with_skill")
        self.assertFalse((run / "timing.json").exists(), "an interrupted run is left incomplete")
        self.assertIn(str(run), stderr)

    def test_ctrl_c_stops_the_claude_session_too(self):
        returncode, stderr, record, seconds = self.interrupt(signal.SIGINT)
        self.check_stopped(returncode, stderr, record, seconds)
        self.assertEqual(returncode, -signal.SIGINT, "ends by SIGINT, so a calling shell loop stops as well")

    def test_sigterm_stops_the_claude_session_too(self):
        returncode, stderr, record, seconds = self.interrupt(signal.SIGTERM)
        self.check_stopped(returncode, stderr, record, seconds)
        self.assertEqual(returncode, -signal.SIGTERM)

    def test_commands_a_finished_session_left_in_the_background_are_stopped(self):
        with StubCompositor(self.agent) as stub:
            result = self.run_eval("--eval", "1", "--config", "with_skill", stub=stub,
                                   extra_env={"FAKE_CLAUDE_BACKGROUND": "1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        record = self.recorded()
        in_group, in_own_session = record["background_pids"]
        for pid in record["background_pids"]:
            self.addCleanup(kill_quietly, pid)
            self.assertTrue(gone(pid), f"the session's background command {pid} outlived the run")
        timing = json.loads((self.run_dir("with_skill") / "timing.json").read_text(encoding="utf-8"))
        self.assertEqual([stray["pid"] for stray in timing["stray_processes"]], [in_own_session])
        self.assertIn("sleep 121", timing["stray_processes"][0]["command"])
        self.assertIn("sleep 121", result.stderr)

    def test_the_sweep_leaves_processes_outside_the_project_folder_alone(self):
        run_eval = load("run_eval")
        project, elsewhere = self.tmp / "project", self.tmp / "elsewhere"
        project.mkdir()
        elsewhere.mkdir()
        inside = subprocess.Popen(["sleep", "122"], cwd=project, start_new_session=True)
        outside = subprocess.Popen(["sleep", "123"], cwd=elsewhere, start_new_session=True)
        for process in (inside, outside):
            self.addCleanup(kill_quietly, process.pid)
        stopped = run_eval.stop_strays(project, grace=5)
        self.assertEqual([stray["pid"] for stray in stopped], [inside.pid])
        self.assertEqual(inside.wait(timeout=10), -signal.SIGTERM)
        self.assertIsNone(outside.poll())
        self.assertEqual(run_eval.stop_strays(project, grace=5), [])

    def test_a_session_that_ignores_sigterm_is_killed_after_the_grace_period(self):
        run_eval = load("run_eval")
        process = subprocess.Popen([sys.executable, "-c", "import signal, time; "
                                    "signal.signal(signal.SIGTERM, signal.SIG_IGN); print('ready', flush=True); "
                                    "time.sleep(60)"], stdout=subprocess.PIPE, text=True, start_new_session=True)
        self.addCleanup(kill_quietly, process.pid)
        self.assertEqual(process.stdout.readline().strip(), "ready")
        started = time.monotonic()
        run_eval.stop_session(process, grace=0.5)
        self.assertEqual(process.returncode, -signal.SIGKILL)
        self.assertLess(time.monotonic() - started, 5)

    def test_stopping_a_session_that_already_ended_is_harmless(self):
        run_eval = load("run_eval")
        process = subprocess.Popen([sys.executable, "-c", "pass"], start_new_session=True)
        process.wait(timeout=30)
        run_eval.stop_session(process, grace=0.5)
        self.assertEqual(process.returncode, 0)


QUOTE_LAYERS = [
    {"id": "L-bg", "name": "Background", "path": "Background", "kind": "raster",
     "content_bounds": {"x": 0, "y": 0, "width": 1080, "height": 1920}},
    {"id": "L-text", "name": "Text", "path": "Text", "kind": "folder", "children": [
        {"id": "L-quote", "name": "Quote", "path": "Text/Quote", "kind": "text",
         "text": {"font_name": "Georgia-Italic", "font_size": 64},
         "content_bounds": {"x": 120, "y": 600, "width": 840, "height": 420}}]},
    {"id": "L-attr", "name": "Attribution", "path": "Attribution", "kind": "text",
     "text": {"font_name": "Helvetica", "font_size": 36},
     "content_bounds": {"x": 300, "y": 1100, "width": 480, "height": 44}},
]


class FinalStateTests(RunEvalTestCase):
    """What the session left open is written to <run>/final-state/ before the reset closes it: expectations checked
    "on the open document" (text bounds, font sizes, get_history) need it when the agent never saved or measured."""

    def run_with_open_document(self, failures=None):
        with StubCompositor(self.agent, failures=failures) as stub:
            stub.new_document_layers = QUOTE_LAYERS
            result = self.run_eval("--eval", "1", "--config", "without_skill", stub=stub,
                                   extra_env={"FAKE_CLAUDE_OPEN": "quote-story"})
            calls = list(stub.calls)
        return result, calls, self.run_dir("without_skill")

    def test_open_documents_are_captured_before_the_reset_closes_them(self):
        result, calls, run = self.run_with_open_document()
        self.assertEqual(result.returncode, 0, result.stderr)
        state = run / "final-state"
        listing = json.loads((state / "list_documents.json").read_text(encoding="utf-8"))
        self.assertEqual([tab["title"] for tab in listing["tabs"]], ["quote-story"])
        tab_id = listing["tabs"][0]["tab_id"]
        captured = json.loads((state / "tab-0.json").read_text(encoding="utf-8"))
        self.assertEqual(captured["tab"]["title"], "quote-story")
        document = captured["get_document"]["document"]
        self.assertEqual(document["detail"], "full")
        self.assertEqual(document["layers"], QUOTE_LAYERS)
        self.assertEqual(captured["get_history"]["undo_names"], ["New Document"])
        text = captured["text_layers"]
        self.assertEqual([(layer["id"], layer["path"]) for layer in text],
                         [("L-quote", "Text/Quote"), ("L-attr", "Attribution")])
        quote = QUOTE_LAYERS[1]["children"][0]
        self.assertEqual(text[0]["get_layer_bounds"]["content_bounds"], quote["content_bounds"])
        self.assertIs(text[1]["get_text_metrics"]["overflows"], False)
        self.assertEqual(captured["errors"], [])

        names = [name for name, _ in calls]
        opened = names.index("new_document")
        first_close = names.index("close_document", opened)
        for tool in ("get_document", "get_history", "get_layer_bounds", "get_text_metrics"):
            self.assertLess(names.index(tool, opened), first_close, f"{tool} ran after the reset")
        by_tool = {}
        for name, arguments in calls[opened:first_close]:
            by_tool.setdefault(name, []).append(arguments)
        self.assertEqual(by_tool["get_document"], [{"document": tab_id, "detail": "full"}])
        self.assertEqual(by_tool["get_history"], [{"document": tab_id}])
        self.assertEqual(sorted(arguments["layer"] for arguments in by_tool["get_layer_bounds"]), ["L-attr", "L-quote"])
        self.assertTrue(all(arguments["document"] == tab_id for arguments in by_tool["get_layer_bounds"]))

        # Outside outputs/, so files_created still lists only what the agent made.
        self.assertFalse((run / "outputs" / "final-state").exists())
        metrics = json.loads((run / "outputs" / "metrics.json").read_text(encoding="utf-8"))
        self.assertEqual(metrics["files_created"], ["out/x.png"])
        timing = json.loads((run / "timing.json").read_text(encoding="utf-8"))
        self.assertEqual(timing["final_state_errors"], [])

    def test_a_session_that_leaves_nothing_open_gets_only_the_tab_list(self):
        with StubCompositor(self.agent) as stub:
            result = self.run_eval("--eval", "1", "--config", "with_skill", stub=stub)
        self.assertEqual(result.returncode, 0, result.stderr)
        state = self.run_dir("with_skill") / "final-state"
        self.assertEqual(sorted(path.name for path in state.iterdir()), ["list_documents.json"])
        listing = json.loads((state / "list_documents.json").read_text(encoding="utf-8"))
        self.assertEqual([tab["document_id"] for tab in listing["tabs"]], [None])

    def test_a_call_that_fails_is_recorded_and_the_run_still_completes(self):
        result, _, run = self.run_with_open_document(failures={"get_history": "busy"})
        self.assertEqual(result.returncode, 0, result.stderr)
        captured = json.loads((run / "final-state" / "tab-0.json").read_text(encoding="utf-8"))
        self.assertIn("busy", captured["get_history"]["error"])
        self.assertEqual(captured["get_document"]["document"]["layers"], QUOTE_LAYERS)
        self.assertEqual(len(captured["errors"]), 1)
        timing = json.loads((run / "timing.json").read_text(encoding="utf-8"))
        self.assertEqual(len(timing["final_state_errors"]), 1)
        self.assertIn("final state", result.stderr)


if __name__ == "__main__":
    unittest.main()
