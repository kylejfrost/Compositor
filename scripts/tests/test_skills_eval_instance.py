"""Tests for scripts/skills-eval/instance.sh, which starts, checks and stops the dedicated Compositor for evals.

Run from the repository root with the system python3 (no packages needed):
    python3 -B -m unittest discover -s scripts/tests -p 'test_skills_eval*.py'

The app and portclaim are fakes: a small Python "Compositor" that answers a JSON-RPC ping on the port it is given
and writes its endpoint file under CFFIXED_USER_HOME (with FAKE_APP_TOKEN, it also keeps an access token there, names
it in the endpoint file and answers 401 to a request without it, as Compositor does by default), and a portclaim that hands out a free ephemeral port (never
2667). The defaults domain is one that doesn't exist, which the script only ever reads.
"""

import json
import os
import shutil
import socket
import stat
import subprocess
import tempfile
import textwrap
import time
import unittest
from pathlib import Path

from test_skills_eval_support import EVAL_SCRIPTS

INSTANCE = EVAL_SCRIPTS / "instance.sh"

FAKE_APP = textwrap.dedent("""\
    #!/usr/bin/env python3
    import http.server, json, os, sys
    from pathlib import Path

    args = sys.argv[1:]
    port = int(args[args.index("-mcp.port") + 1])
    Path(os.environ["FAKE_APP_LOG"]).write_text(json.dumps({
        "argv": args, "home": os.environ.get("CFFIXED_USER_HOME"), "pid": os.getpid(), "cwd": os.getcwd()}))

    token = os.environ.get("FAKE_APP_TOKEN")

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            payload = json.dumps({"jsonrpc": "2.0", "id": body.get("id"), "result": {}}).encode()
            status = 200
            if token and self.headers.get("Authorization") != f"Bearer {token}":
                status, payload = 401, b'{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Unauthorized"}}'
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, *a):
            pass

    server = http.server.HTTPServer(("127.0.0.1", port), Handler)
    endpoint = Path(os.environ["CFFIXED_USER_HOME"]) / "Library/Application Support/Compositor/mcp/endpoint.json"
    endpoint.parent.mkdir(parents=True, exist_ok=True)
    record = {"pid": os.getpid(), "port": port, "url": f"http://127.0.0.1:{port}/mcp", "app_version": "9.9"}
    if token:
        token_file = endpoint.parent / "token"
        token_file.write_text(token)
        token_file.chmod(0o600)
        record.update(auth="bearer", token_file=str(token_file))
    endpoint.write_text(json.dumps(record))
    server.serve_forever()
""")

FAKE_PORTCLAIM = textwrap.dedent("""\
    #!/bin/bash
    echo "$*" >> "$FAKE_PORTCLAIM_LOG"
    case "$1" in
        acquire) echo "{\\"port\\":$FAKE_PORT,\\"lease\\":\\"persistent\\"}" ;;
        release) echo "released port $2" ;;
        find) echo "[]" ;;
    esac
""")


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def executable(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


class InstanceTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="skills-eval-instance-")
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name).resolve()
        self.workspace = self.tmp / "workspace"
        self.sandbox = self.tmp / "sandbox"
        self.dd = self.tmp / "DD"
        self.app = self.dd / "Build" / "Products" / "Debug" / "Compositor.app" / "Contents" / "MacOS" / "Compositor"
        self.portclaim = self.tmp / "bin" / "portclaim"
        executable(self.portclaim, FAKE_PORTCLAIM)
        self.port = free_port()
        self.app_log = self.tmp / "app-log.json"
        self.portclaim_log = self.tmp / "portclaim.log"
        self.state = self.workspace / "instance" / "state.json"
        self.addCleanup(self.kill_leftover)

    def kill_leftover(self):
        if self.app_log.exists():
            pid = json.loads(self.app_log.read_text())["pid"]
            try:
                os.kill(pid, 9)
            except ProcessLookupError:
                pass

    def instance(self, *args, extra_env=None):
        env = {**os.environ, "SKILLS_EVAL_WORKSPACE": str(self.workspace), "SKILLS_EVAL_DD": str(self.dd),
               "SKILLS_EVAL_SANDBOX": str(self.sandbox),
               "PORTCLAIM": str(self.portclaim), "COMPOSITOR_DEFAULTS_DOMAIN": "com.example.skills-eval-test-absent",
               "FAKE_APP_LOG": str(self.app_log), "FAKE_PORTCLAIM_LOG": str(self.portclaim_log),
               "FAKE_PORT": str(self.port), **(extra_env or {})}
        return subprocess.run(["bash", str(INSTANCE), *args], capture_output=True, text=True, env=env, timeout=120)

    def portclaim_calls(self):
        return self.portclaim_log.read_text().splitlines() if self.portclaim_log.exists() else []


class ScriptTests(InstanceTestCase):
    def test_the_script_parses(self):
        self.assertEqual(subprocess.run(["bash", "-n", str(INSTANCE)]).returncode, 0)

    @unittest.skipUnless(shutil.which("shellcheck"), "shellcheck is not installed")
    def test_shellcheck_is_clean(self):
        result = subprocess.run(["shellcheck", str(INSTANCE)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_status_without_an_instance_says_so(self):
        result = self.instance("status")
        self.assertEqual(result.returncode, 1)
        self.assertIn("not running", result.stdout)

    def test_stop_without_an_instance_is_harmless(self):
        result = self.instance("stop")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.portclaim_calls(), [])

    def test_unknown_commands_are_refused(self):
        self.assertEqual(self.instance("restart-everything").returncode, 2)

    def test_start_refuses_a_missing_app_before_claiming_a_port(self):
        result = self.instance("start", "--no-build")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Compositor.app", result.stderr)
        self.assertEqual(self.portclaim_calls(), [])


class LifecycleTests(InstanceTestCase):
    def setUp(self):
        super().setUp()
        executable(self.app, FAKE_APP)

    def test_start_launches_the_app_on_a_claimed_port_with_an_isolated_home(self):
        result = self.instance("start", "--no-build")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        launched = json.loads(self.app_log.read_text())
        argv = launched["argv"]
        self.assertIn("--mcp", argv)
        self.assertEqual(argv[argv.index("-mcp.port") + 1], str(self.port))
        for key in ("-migration.sandboxPreferences.v1", "-migration.sandboxAgentFolder.v1"):
            self.assertEqual(argv[argv.index(key) + 1], "YES", key)
        for key in ("-SUEnableAutomaticChecks", "-SUAutomaticallyUpdate"):
            self.assertEqual(argv[argv.index(key) + 1], "NO", key)
        home = self.sandbox / "home"
        self.assertEqual(Path(launched["home"]), home)
        # A Debug build instrumented for coverage writes default.profraw into its working folder when it quits:
        # the sandbox, never the checkout instance.sh was run from.
        self.assertEqual(Path(launched["cwd"]).resolve(), self.sandbox.resolve())
        state = json.loads(self.state.read_text())
        self.assertEqual(state["pid"], launched["pid"])
        self.assertEqual(state["port"], self.port)
        self.assertEqual(state["url"], f"http://127.0.0.1:{self.port}/mcp")
        self.assertEqual(Path(state["agent_folder"]),
                         home / "Library" / "Application Support" / "Compositor" / "Agent")
        self.assertIn("compositor: OK", result.stdout)
        acquire = self.portclaim_calls()[0]
        self.assertIn("acquire", acquire)
        self.assertIn("--service compositor-mcp-eval", acquire)
        self.assertIn("--lease persistent", acquire)

        status = self.instance("status")
        self.assertEqual(status.returncode, 0, status.stdout + status.stderr)
        self.assertIn(str(self.port), status.stdout)

        stop = self.instance("stop")
        self.assertEqual(stop.returncode, 0, stop.stdout + stop.stderr)
        deadline = time.time() + 5
        while time.time() < deadline:
            try:
                os.kill(launched["pid"], 0)
            except ProcessLookupError:
                break
            time.sleep(0.1)
        else:
            self.fail("the app is still running")
        endpoint = home / "Library" / "Application Support" / "Compositor" / "mcp" / "endpoint.json"
        self.assertFalse(endpoint.exists(), "the endpoint file naming the dead pid was removed")
        self.assertIn(f"release {self.port}", self.portclaim_calls())
        self.assertFalse(self.state.exists())

    def test_an_instance_that_requires_its_token_is_checked_with_it(self):
        # The instance keeps its own token in the sandbox home; start and status ping with it, state.json names its
        # file for run_eval, and nothing prints it.
        token = "tests-only-not-a-real-access-token-00000001"
        result = self.instance("start", "--no-build", extra_env={"FAKE_APP_TOKEN": token})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("compositor: OK", result.stdout)
        state = json.loads(self.state.read_text())
        self.assertEqual(Path(state["token_file"]),
                         self.sandbox / "home" / "Library" / "Application Support" / "Compositor" / "mcp" / "token")
        status = self.instance("status")
        self.assertEqual(status.returncode, 0, status.stdout + status.stderr)
        self.assertIn("compositor: OK", status.stdout)
        for output in (result.stdout, result.stderr, status.stdout, status.stderr, self.state.read_text()):
            self.assertNotIn(token, output)
        self.assertEqual(self.instance("stop").returncode, 0)

    def test_start_twice_reuses_the_running_instance(self):
        self.assertEqual(self.instance("start", "--no-build").returncode, 0)
        pid = json.loads(self.state.read_text())["pid"]
        again = self.instance("start", "--no-build")
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn("already running", again.stdout)
        self.assertEqual(json.loads(self.state.read_text())["pid"], pid)
        self.assertEqual(sum("acquire" in call for call in self.portclaim_calls()), 1)
        self.instance("stop")

    def test_a_port_that_is_taken_fails_the_start_and_releases_the_claim(self):
        with socket.socket() as blocker:
            blocker.bind(("127.0.0.1", self.port))
            blocker.listen()
            result = self.instance("start", "--no-build")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(f"release {self.port}", self.portclaim_calls())
        self.assertFalse(self.state.exists())

    def test_stop_cleans_up_after_an_app_that_already_died(self):
        self.assertEqual(self.instance("start", "--no-build").returncode, 0)
        pid = json.loads(self.state.read_text())["pid"]
        os.kill(pid, 9)
        time.sleep(0.3)
        stop = self.instance("stop")
        self.assertEqual(stop.returncode, 0, stop.stdout + stop.stderr)
        home = self.sandbox / "home"
        self.assertFalse((home / "Library" / "Application Support" / "Compositor" / "mcp" / "endpoint.json").exists())
        self.assertIn(f"release {self.port}", self.portclaim_calls())

    def test_stop_removes_the_endpoint_file_the_instance_was_started_with(self):
        # stop cleans up what start recorded, even when the environment has changed since (another
        # SKILLS_EVAL_SANDBOX, or none): the endpoint file comes from state.json, not from today's variables.
        self.assertEqual(self.instance("start", "--no-build").returncode, 0)
        state = json.loads(self.state.read_text())
        endpoint = Path(state["endpoint_file"])
        self.assertTrue(endpoint.is_file())
        os.kill(state["pid"], 9)
        time.sleep(0.3)
        self.sandbox = self.tmp / "another-sandbox"
        stop = self.instance("stop")
        self.assertEqual(stop.returncode, 0, stop.stdout + stop.stderr)
        self.assertFalse(endpoint.exists(), "the endpoint file naming the dead pid was left behind")
        self.assertIn(f"dead pid {state['pid']}", stop.stdout)
        self.assertFalse((self.tmp / "another-sandbox").exists(), "stop created nothing in the new sandbox")


if __name__ == "__main__":
    unittest.main()
