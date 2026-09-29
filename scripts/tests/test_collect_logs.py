"""scripts/collect-logs.sh: gathers Compositor's diagnostic logs (and the bridge's, the unified log, crash reports,
preferences, Hermes logs) since a time into one folder, on this Mac or over SSH.

Every run uses a stub home folder and stub `log`, `defaults`, `hermes` and `ssh` commands on PATH, so nothing
reads the real logs, preferences or network. Run from the repository root with the system python3:
    python3 -m unittest discover -s scripts/tests -p test_collect_logs.py
"""

import calendar
import json
import os
import shutil
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "collect-logs.sh"

STUB_LOG = """#!/bin/bash
printf '%s\\n' "$@" > "$STUB_RECORD/log-args"
echo '{"subsystem":"com.wonderassembly.compositor","category":"mcp","eventMessage":"unified line one"}'
echo '{"subsystem":"com.wonderassembly.compositor","category":"app","eventMessage":"unified line two"}'
"""

STUB_DEFAULTS = """#!/bin/bash
[ "$1 $2" = "read com.wonderassembly.compositor" ] || exit 1
cat <<'EOF'
{
    "log.enabled" = 1;
    "mcp.enabled" = 1;
    "mcp.requireToken" = 1;
    "sessionTokenCache" = abc;
}
EOF
"""

STUB_HERMES = """#!/bin/bash
[ "$1 $2" = "mcp list" ] || exit 1
echo "compositor  stdio  /Applications/Compositor.app/Contents/MacOS/compositor-mcp"
echo "other       http   Authorization: Bearer sk-live-Q2xhdWRlQ29kZVRva2Vu"
"""

# Runs the command ssh was given in a shell on "the remote", whose home is FAKE_REMOTE_HOME, with ssh's stdin.
STUB_SSH = """#!/bin/bash
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) shift 2 ;;
        -*) shift ;;
        *) break ;;
    esac
done
echo "$1" > "$STUB_RECORD/ssh-host"
shift
HOME="$FAKE_REMOTE_HOME" exec /bin/bash -c "$*"
"""


def utc(text):
    """Seconds since 1970 for an ISO time in UTC."""
    return calendar.timegm(time.strptime(text, "%Y-%m-%dT%H:%M:%SZ"))


def local_stamp(text):
    """`YYYY-MM-DD HH:MM:SS` in local time (as Hermes writes it) for an ISO time in UTC."""
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(utc(text)))


def event(ts, name, **fields):
    return json.dumps({"ts": ts, "level": "info", "cat": "mcp", "event": name, **fields}, separators=(",", ":"))


class CollectLogsTests(unittest.TestCase):
    since = "2026-09-24T11:00:00Z"

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="collect-logs-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.record = self.tmp / "record"
        self.record.mkdir()
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        for name, text in [("log", STUB_LOG), ("defaults", STUB_DEFAULTS), ("hermes", STUB_HERMES), ("ssh", STUB_SSH)]:
            path = self.bin / name
            path.write_text(text)
            path.chmod(0o755)
        self.home = self.make_home(self.tmp / "home", marker="local")
        self.remote_home = self.make_home(self.tmp / "remote-home", marker="remote")
        self.app = self.tmp / "Compositor.app"
        (self.app / "Contents").mkdir(parents=True)
        (self.app / "Contents" / "Info.plist").write_text(
            '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
            "<key>CFBundleShortVersionString</key><string>9.8.7</string>"
            "<key>CFBundleVersion</key><string>987</string></dict></plist>")

    def make_home(self, home, marker):
        logs = home / "Library" / "Logs" / "Compositor"
        logs.mkdir(parents=True)
        (logs / "compositor-2026-09-23.jsonl").write_text(event("2026-09-23T10:00:00.000Z", "yesterday") + "\n")
        (logs / "compositor-2026-09-24.jsonl").write_text("\n".join([
            event("2026-09-24T09:00:00.000Z", "too_early"),
            event("2026-09-24T13:00:00.000Z", "tool_call", tool="add_blank_layer", host=marker),
        ]) + "\n")
        (logs / "bridge.jsonl").write_text("\n".join([
            event("2026-09-22T08:00:00.000Z", "old_bridge"),
            event("2026-09-24T12:00:00.000Z", "forward", method="tools/call"),
        ]) + "\n")
        (logs / "collected" / "earlier-bundle").mkdir(parents=True)
        (logs / "collected" / "earlier-bundle" / "compositor-2026-09-24.jsonl").write_text(event("2026-09-24T13:30:00.000Z", "stale"))
        reports = home / "Library" / "Logs" / "DiagnosticReports"
        reports.mkdir(parents=True)
        (reports / "Compositor-2026-09-24-120000.ips").write_text("crash " + marker)
        (reports / "compositor-mcp-2026-09-24-120500.ips").write_text("bridge crash")
        (reports / "Other-2026-09-24-120000.ips").write_text("someone else's crash")
        old = reports / "Compositor-2026-09-01-120000.ips"
        old.write_text("old crash")
        os.utime(old, (utc("2026-09-01T12:00:00Z"),) * 2)
        hermes = home / ".hermes" / "logs"
        hermes.mkdir(parents=True)
        (hermes / "gateway.log").write_text("\n".join([
            local_stamp("2026-09-20T12:00:00Z") + ",000 INFO too old",
            local_stamp("2026-09-24T12:00:00Z") + ",000 INFO gateway started " + marker,
            "    continuation of the started line",
            local_stamp("2026-09-24T12:01:00Z") + ",000 INFO using api_key=sk-XYZ",
            local_stamp("2026-09-24T12:02:00Z") + ",000 INFO Password reset skipped",
        ]) + "\n")
        (hermes / "gateway.error.log").write_text(local_stamp("2026-09-24T12:03:00Z") + ",000 ERROR tool failed\n")
        (home / "Documents").mkdir()
        (home / "Documents" / "Client Poster.psd").write_text("private document")
        return home

    def run_script(self, *args, home=None):
        env = dict(os.environ)
        env.update(HOME=str(home or self.home), PATH=f"{self.bin}:{env['PATH']}", STUB_RECORD=str(self.record),
                   FAKE_REMOTE_HOME=str(self.remote_home), COMPOSITOR_APP=str(self.app))
        return subprocess.run(["/bin/bash", str(SCRIPT), *args], env=env, capture_output=True, text=True, timeout=120)

    def bundle(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        path = Path(result.stdout.strip().splitlines()[-1])
        self.assertTrue(path.is_dir(), f"{path} (stdout: {result.stdout!r}, stderr: {result.stderr!r})")
        return path

    def all_text(self, bundle):
        return "".join(p.read_text(errors="replace") for p in bundle.rglob("*") if p.is_file())

    def test_a_local_run_gathers_everything_since_the_time_and_nothing_else(self):
        out = self.tmp / "out"
        bundle = self.bundle(self.run_script("--since", self.since, "--out", str(out)))
        self.assertEqual(bundle.parent, out)
        self.assertTrue(bundle.name.startswith("compositor-logs-"), bundle.name)

        today = (bundle / "compositor" / "compositor-2026-09-24.jsonl").read_text()
        self.assertIn('"tool_call"', today)
        self.assertNotIn("too_early", today)
        self.assertFalse((bundle / "compositor" / "compositor-2026-09-23.jsonl").exists(), "A file with nothing since")
        bridge = (bundle / "compositor" / "bridge.jsonl").read_text()
        self.assertIn('"forward"', bridge)
        self.assertNotIn("old_bridge", bridge)

        unified = (bundle / "unified-log.ndjson").read_text()
        self.assertIn("unified line one", unified)
        log_args = (self.record / "log-args").read_text().splitlines()
        self.assertEqual(log_args[:5], ["show", "--predicate", 'subsystem == "com.wonderassembly.compositor"',
                                        "--style", "ndjson"])
        self.assertIn("--start", log_args)

        crashes = sorted(p.name for p in (bundle / "crash-reports").iterdir())
        self.assertEqual(crashes, ["Compositor-2026-09-24-120000.ips", "compositor-mcp-2026-09-24-120500.ips"])

        defaults = (bundle / "defaults.txt").read_text()
        self.assertIn("log.enabled", defaults)
        self.assertNotIn("oken", defaults, "A key containing 'token' was kept")

        app = (bundle / "app.txt").read_text()
        self.assertIn("9.8.7", app)
        self.assertIn("987", app)

        gateway = (bundle / "hermes" / "gateway.log").read_text()
        self.assertIn("gateway started local", gateway)
        self.assertIn("continuation of the started line", gateway)
        self.assertNotIn("too old", gateway)
        self.assertNotIn("sk-XYZ", gateway)
        self.assertNotIn("Password reset", gateway)
        self.assertIn("[line redacted", gateway)
        self.assertIn("tool failed", (bundle / "hermes" / "gateway.error.log").read_text())
        mcp_list = (bundle / "hermes" / "mcp-list.txt").read_text()
        self.assertIn("compositor-mcp", mcp_list)
        self.assertNotIn("sk-live", mcp_list)

        everything = self.all_text(bundle)
        self.assertNotIn("private document", everything, "Something from Documents was collected")
        self.assertNotIn("someone else's crash", everything)
        self.assertNotIn('"stale"', everything, "An earlier collected bundle was collected again")
        self.assertIn("2026-09-24T11:00:00Z", (bundle / "README.txt").read_text())

    def test_a_duration_goes_to_log_show_as_last_and_the_bundle_lands_under_the_log_folder(self):
        bundle = self.bundle(self.run_script("--since", "2h"))
        self.assertEqual(bundle.parent, self.home / "Library" / "Logs" / "Compositor" / "collected")
        log_args = (self.record / "log-args").read_text().splitlines()
        self.assertEqual(log_args[log_args.index("--last") + 1], "2h")

    def test_a_host_is_collected_over_ssh_and_copied_back(self):
        out = self.tmp / "out"
        bundle = self.bundle(self.run_script("--host", "mac-mini", "--since", self.since, "--out", str(out)))
        self.assertEqual((self.record / "ssh-host").read_text().strip(), "mac-mini")
        self.assertEqual(bundle.parent, out)
        self.assertIn("mac-mini", bundle.name)
        today = (bundle / "compositor" / "compositor-2026-09-24.jsonl").read_text()
        self.assertIn('"host":"remote"', today, "The bundle holds the remote Mac's logs")
        self.assertIn("gateway started remote", (bundle / "hermes" / "gateway.log").read_text())
        self.assertNotIn("private document", self.all_text(bundle))
        remote_collected = self.remote_home / "Library" / "Logs" / "Compositor" / "collected"
        self.assertEqual(sorted(p.name for p in remote_collected.iterdir()), ["earlier-bundle"], "The remote Mac kept a copy")

    def test_bad_arguments_exit_with_usage(self):
        result = self.run_script("--since")
        self.assertEqual(result.returncode, 64, result.stderr)
        self.assertIn("usage:", result.stderr)
        result = self.run_script("--frobnicate")
        self.assertEqual(result.returncode, 64, result.stderr)
        result = self.run_script("--since", "yesterday-ish")
        self.assertEqual(result.returncode, 64, result.stderr)
        self.assertIn("--since", result.stderr)

    def test_the_script_is_executable(self):
        self.assertTrue(SCRIPT.stat().st_mode & stat.S_IXUSR)


if __name__ == "__main__":
    unittest.main()
