"""Tests for skills/compositor/scripts/tool-atlas.py, which writes the compositor skill's tool atlas from tools/list.

Run from the repository root with the system python3 (no packages needed):
    python3 -m unittest discover -s scripts/tests -p test_tool_atlas.py

The script runs with HOME pointed at a temporary folder, so it never reads Compositor's real endpoint file, and it
only ever talks to a stub server on an ephemeral loopback port (never 2667). Atlases are written to temporary files,
never over the committed one.
"""

import http.server
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "skills" / "compositor" / "scripts" / "tool-atlas.py"
FIXTURE = Path(__file__).resolve().parent / "fixtures" / "tools-list.json"


def fixture_tools():
    return json.loads(FIXTURE.read_text(encoding="utf-8"))["tools"]


class StubServer:
    """A loopback stand-in for Compositor's MCP endpoint: answers `initialize` and pages `tools/list` (two tools per
    page, with nextCursor), optionally as a server-sent event stream. Records every request."""

    def __init__(self, tools, protocol="2025-06-18", status=200, stream=False, page_size=2, error=None):
        self.tools, self.protocol, self.status, self.stream = tools, protocol, status, stream
        self.page_size, self.error = page_size, error
        self.requests = []
        stub = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers.get("Content-Length", 0))
                body = json.loads(self.rfile.read(length) or b"null")
                stub.requests.append({"path": self.path, "headers": {k.lower(): v for k, v in self.headers.items()},
                                      "body": body})
                if stub.status != 200:
                    self.reply(stub.status, b"refused", "text/plain")
                    return
                if "id" not in body:  # a notification
                    self.reply(202, b"", "text/plain")
                    return
                answer = {"jsonrpc": "2.0", "id": body["id"]}
                if stub.error and body["method"] == stub.error:
                    answer["error"] = {"code": -32601, "message": "Method not found"}
                elif body["method"] == "initialize":
                    answer["result"] = {"protocolVersion": stub.protocol, "capabilities": {"tools": {}},
                                        "serverInfo": {"name": "Compositor", "version": "9.9"}}
                elif body["method"] == "tools/list":
                    start = int((body.get("params") or {}).get("cursor") or 0)
                    page = stub.tools[start:start + stub.page_size]
                    answer["result"] = {"tools": page}
                    if start + stub.page_size < len(stub.tools):
                        answer["result"]["nextCursor"] = str(start + stub.page_size)
                else:
                    answer["error"] = {"code": -32601, "message": "Method not found"}
                payload = json.dumps(answer).encode()
                if stub.stream:
                    self.reply(200, b"event: message\ndata: " + payload + b"\n\n", "text/event-stream")
                else:
                    self.reply(200, payload, "application/json")

            def reply(self, status, payload, content_type):
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        self.url = f"http://127.0.0.1:{self.port}/mcp"

    def __enter__(self):
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        return self

    def __exit__(self, *exc):
        self.server.shutdown()
        self.server.server_close()

    @property
    def methods(self):
        return [request["body"].get("method") for request in self.requests]


class ToolAtlasTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="tool-atlas-")
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.out = self.tmp / "tool-atlas.md"

    def run_atlas(self, *args):
        env = {**os.environ, "HOME": str(self.home)}
        env.pop("PYTHONDONTWRITEBYTECODE", None)
        result = subprocess.run([sys.executable, "-B", str(SCRIPT), *map(str, args)], capture_output=True, text=True,
                                env=env, timeout=60)
        return result.returncode, result.stdout, result.stderr

    def render(self, *args, source=FIXTURE):
        code, out, err = self.run_atlas("--from-json", source, "--out", self.out, *args)
        self.assertEqual(code, 0, out + err)
        return self.out.read_text(encoding="utf-8")

    def section(self, atlas, name):
        """The markdown of one tool's section: from its heading to the next heading."""
        match = re.search(rf"(?ms)^### `{re.escape(name)}`.*?(?=^##)", atlas + "\n## end")
        self.assertIsNotNone(match, f"no section for {name}")
        return match.group(0)

    def row(self, section, parameter):
        """The cells after the parameter's name in its table row: type, required, default, allowed, description."""
        for line in section.splitlines():
            if line.startswith(f"| `{parameter}` |"):
                return [cell.strip() for cell in re.split(r"(?<!\\)\|", line)[2:-1]]
        self.fail(f"no row for {parameter} in:\n{section}")


class RenderingTests(ToolAtlasTestCase):
    def test_writes_a_generated_atlas_with_a_contents_list(self):
        atlas = self.render()
        lines = atlas.splitlines()
        self.assertEqual(lines[0], "# Compositor tool atlas")
        head = "\n".join(lines[:40])
        self.assertRegex(head, r"(?i)generated .*tools/list")
        self.assertIn("tool-atlas.py", head)
        self.assertRegex(head, r"\b5 tools\b")
        self.assertRegex(head, r"(?m)^## Contents$")
        for group, count in [("Documents and app", 2), ("Layers", 1), ("History and batches", 1), ("Other", 1)]:
            self.assertRegex(head, rf"(?m)^- \[{re.escape(group)}\]\(#[a-z0-9-]+\) \({count}\)")

    def test_tools_are_grouped_by_domain_in_the_tables_order_with_unknown_tools_under_other(self):
        atlas = self.render()
        headings = re.findall(r"(?m)^(##|###) (.+)$", atlas)
        order = [title for level, title in headings if level == "##" and title != "Contents"]
        self.assertEqual(order, ["Documents and app", "Layers", "History and batches", "Other"])
        documents = atlas.index("## Documents and app")
        layers = atlas.index("## Layers")
        other = atlas.index("## Other")
        self.assertTrue(documents < atlas.index("### `list_documents`") < layers)
        self.assertTrue(documents < atlas.index("### `export_image`") < layers)
        self.assertTrue(other < atlas.index("### `frobnicate_widgets`"))

    def test_each_tool_shows_its_title_description_and_annotations(self):
        atlas = self.render()
        export = self.section(atlas, "export_image")
        self.assertIn("Export image", export)
        self.assertIn("Never replaces an existing file unless overwrite is true.", export)
        self.assertRegex(export, r"(?m)^\*\*Effect:\*\* destructive, idempotent$")
        self.assertRegex(self.section(atlas, "list_documents"), r"(?m)^\*\*Effect:\*\* read-only, idempotent$")
        self.assertRegex(self.section(atlas, "add_blank_layer"), r"(?m)^\*\*Effect:\*\* additive$")
        self.assertRegex(self.section(atlas, "frobnicate_widgets"), r"(?m)^\*\*Effect:\*\* no annotations declared$")

    def test_every_parameter_shows_type_required_default_and_allowed_values(self):
        export = self.section(self.render(), "export_image")
        self.assertEqual(self.row(export, "path")[:4], ["string", "yes", "", ""])
        self.assertEqual(self.row(export, "quality")[:4], ["number", "", "`0.85`", "0–1"])
        self.assertEqual(self.row(export, "format")[:4], ["string", "", "", "`png`, `jpeg`"])
        self.assertEqual(self.row(export, "max_size")[:4], ["integer", "", "", "16–30000"])
        self.assertEqual(self.row(export, "overwrite")[:4], ["boolean", "", "`false`", ""])
        self.assertEqual(self.row(export, "document")[:4], ["integer ≥ 0 \\| string", "", "", ""])
        self.assertIn("JPEG quality.", self.row(export, "quality")[4])

    def test_nested_object_and_array_members_get_their_own_rows(self):
        atlas = self.render()
        export = self.section(atlas, "export_image")
        self.assertEqual(self.row(export, "region")[:2], ["object", ""])
        self.assertEqual(self.row(export, "region.x")[:2], ["number", "yes"])
        self.assertEqual(self.row(export, "region.width")[:4], ["number", "yes", "", "≥ 0"])
        batch = self.section(atlas, "run_batch")
        self.assertEqual(self.row(batch, "steps")[:4], ["array of object", "yes", "", "1–200 items"])
        self.assertEqual(self.row(batch, "steps[].tool")[:2], ["string", "yes"])
        self.assertEqual(self.row(batch, "steps[].arguments")[:2], ["object", ""])

    def test_alternatives_are_summarized_inline(self):
        blank = self.section(self.render(), "add_blank_layer")
        self.assertEqual(self.row(blank, "fill")[0], "object {r, g, b} \\| string `^#[0-9A-Fa-f]{6}$` \\| null")
        self.assertNotIn("| `fill.r` |", blank, "a small value object (a color, a point) stays inline")

    def test_a_structured_alternative_gets_rows_for_its_members(self):
        blank = self.section(self.render(), "add_blank_layer")
        self.assertEqual(self.row(blank, "style")[0], "object {enabled, inside, opacity, size} \\| null")
        self.assertEqual(self.row(blank, "style.size")[:4], ["number", "", "", "0–500"])
        self.assertEqual(self.row(blank, "style.inside")[0], "boolean")

    def test_table_breaking_characters_are_escaped(self):
        atlas = self.render()
        blank = self.section(atlas, "add_blank_layer")
        self.assertIn("Takes a name \\| or none.", blank)
        self.assertIn("(a \\| in it is fine)", self.row(blank, "name")[4])
        self.assertIn("Runs several tool calls as one undo step. Stops at the first failure.", self.section(atlas, "run_batch"))

    def test_a_tool_without_parameters_says_so(self):
        self.assertIn("No parameters.", self.section(self.render(), "list_documents"))

    def parameters(self, section):
        return re.findall(r"(?m)^\| `([^`]+)` \|", section)

    def test_parameters_come_in_one_order_whatever_order_the_server_lists_them_in(self):
        # Compositor's schemas list their keys in no particular order (export_image's `document` comes last, a color's
        # members as b, g, r), so the atlas orders them itself: the document and layer selectors, then the required
        # parameters, then the optional ones, each group with x, y, width, height and r, g, b, a in that order and the
        # rest alphabetically. Members of objects and arrays follow their parent in the same order.
        atlas = self.render()
        export = self.section(atlas, "export_image")
        self.assertEqual(self.parameters(export), ["document", "path", "format", "max_size", "overwrite", "quality",
                                                   "region", "region.x", "region.y", "region.width", "region.height"])
        shuffled = fixture_tools()
        for tool in shuffled:
            schema = tool["inputSchema"]
            schema["properties"] = dict(reversed(list((schema.get("properties") or {}).items())))
            region = schema["properties"].get("region")
            if region:
                region["properties"] = dict(reversed(list(region["properties"].items())))
        source = self.tmp / "shuffled.json"
        source.write_text(json.dumps({"tools": shuffled}), encoding="utf-8")
        self.assertEqual(self.render(source=source), atlas)

    def test_color_members_read_r_g_b(self):
        tools = fixture_tools()
        blank = next(tool for tool in tools if tool["name"] == "add_blank_layer")
        color = blank["inputSchema"]["properties"]["fill"]["anyOf"][0]
        color["properties"] = {key: color["properties"][key] for key in ("b", "g", "r")}
        source = self.tmp / "bgr.json"
        source.write_text(json.dumps({"tools": tools}), encoding="utf-8")
        fill = self.row(self.section(self.render(source=source), "add_blank_layer"), "fill")
        self.assertTrue(fill[0].startswith("object {r, g, b} "), fill[0])

    def test_the_output_is_deterministic_and_ends_with_one_newline(self):
        first = self.render()
        second = self.render()
        self.assertEqual(first, second)
        self.assertTrue(first.endswith("\n") and not first.endswith("\n\n"))
        self.assertFalse(any(line != line.rstrip() for line in first.splitlines()), "trailing whitespace")

    def test_a_note_goes_under_the_title(self):
        atlas = self.render("--note", "Provisional; regenerated in 5.5b-2.")
        self.assertIn("Provisional; regenerated in 5.5b-2.", "\n".join(atlas.splitlines()[:8]))

    def test_the_saved_result_may_be_a_json_rpc_response_or_a_bare_list(self):
        expected = self.render()
        tools = fixture_tools()
        for shape in ({"jsonrpc": "2.0", "id": 1, "result": {"tools": tools}}, tools):
            with self.subTest(shape=type(shape).__name__):
                source = self.tmp / "shape.json"
                source.write_text(json.dumps(shape), encoding="utf-8")
                self.assertEqual(self.render(source=source), expected)

    def test_unreadable_json_fails_without_writing(self):
        source = self.tmp / "broken.json"
        source.write_text("{ not json", encoding="utf-8")
        code, out, err = self.run_atlas("--from-json", source, "--out", self.out)
        self.assertEqual(code, 1)
        self.assertIn("broken.json", out + err)
        self.assertFalse(self.out.exists())

    def test_dump_json_saves_the_tool_list(self):
        dump = self.tmp / "dump.json"
        code, out, err = self.run_atlas("--from-json", FIXTURE, "--out", self.out, "--dump-json", dump)
        self.assertEqual(code, 0, out + err)
        self.assertEqual(json.loads(dump.read_text(encoding="utf-8")), {"tools": fixture_tools()})


class CheckTests(ToolAtlasTestCase):
    def test_check_passes_when_the_committed_atlas_matches(self):
        before = self.render()
        code, out, err = self.run_atlas("--from-json", FIXTURE, "--out", self.out, "--check")
        self.assertEqual(code, 0, out + err)
        self.assertIn("up to date", out)
        self.assertEqual(self.out.read_text(encoding="utf-8"), before)

    def test_check_reports_drift_as_a_unified_diff_and_changes_nothing(self):
        self.render()
        stale = self.out.read_text(encoding="utf-8").replace("JPEG quality.", "JPEG quality (old).")
        self.out.write_text(stale, encoding="utf-8")
        code, out, err = self.run_atlas("--from-json", FIXTURE, "--out", self.out, "--check")
        self.assertEqual(code, 1, out + err)
        self.assertRegex(out, r"(?m)^--- ")
        self.assertRegex(out, r"(?m)^\+\+\+ ")
        self.assertRegex(out, r"(?m)^-.*JPEG quality \(old\)\.")
        self.assertRegex(out, r"(?m)^\+.*JPEG quality\.")
        self.assertRegex(out, r"(?i)1 line removed, 1 line added|drift")
        self.assertEqual(self.out.read_text(encoding="utf-8"), stale)

    def test_check_fails_when_there_is_no_committed_atlas(self):
        code, out, err = self.run_atlas("--from-json", FIXTURE, "--out", self.out, "--check")
        self.assertEqual(code, 1)
        self.assertIn(str(self.out), out + err)
        self.assertFalse(self.out.exists())


class EndpointTests(ToolAtlasTestCase):
    def test_initialize_then_every_page_of_tools_list(self):
        with StubServer(fixture_tools()) as stub:
            code, out, err = self.run_atlas("--endpoint", stub.url, "--out", self.out)
        self.assertEqual(code, 0, out + err)
        self.assertEqual(stub.methods, ["initialize", "tools/list", "tools/list", "tools/list"])
        self.assertEqual(self.out.read_text(encoding="utf-8"), self.render())

    def test_requests_carry_the_headers_compositor_requires(self):
        with StubServer(fixture_tools()) as stub:
            self.run_atlas("--endpoint", stub.url, "--out", self.out)
        initialize, *listing = stub.requests
        for request in stub.requests:
            headers = request["headers"]
            self.assertEqual(request["path"], "/mcp")
            self.assertEqual(headers.get("content-type"), "application/json")
            self.assertIn("application/json", headers.get("accept", ""))
            self.assertIn("text/event-stream", headers.get("accept", ""))
            self.assertNotIn("origin", headers, "Compositor refuses any request with an Origin header")
            self.assertEqual(headers.get("host"), f"127.0.0.1:{stub.port}")
            self.assertEqual(request["body"]["jsonrpc"], "2.0")
        self.assertIn("protocolVersion", initialize["body"]["params"])
        for request in listing:
            self.assertEqual(request["headers"].get("mcp-protocol-version"), "2025-06-18",
                             "tools/list must carry the version initialize negotiated")
        self.assertEqual([request["body"].get("params", {}).get("cursor") for request in listing], [None, "2", "4"])

    def test_an_event_stream_answer_is_read(self):
        with StubServer(fixture_tools(), stream=True) as stub:
            code, out, err = self.run_atlas("--endpoint", stub.url, "--out", self.out)
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.out.read_text(encoding="utf-8"), self.render())

    def test_the_endpoint_file_names_the_url(self):
        with StubServer(fixture_tools()) as stub:
            endpoint = self.tmp / "endpoint.json"
            endpoint.write_text(json.dumps({"url": stub.url, "port": stub.port, "pid": os.getpid()}), encoding="utf-8")
            code, out, err = self.run_atlas("--endpoint-file", endpoint, "--out", self.out)
        self.assertEqual(code, 0, out + err)
        self.assertEqual(stub.methods[0], "initialize")

    def test_the_default_endpoint_file_is_compositors_under_home(self):
        with StubServer(fixture_tools()) as stub:
            endpoint = self.home / "Library" / "Application Support" / "Compositor" / "mcp" / "endpoint.json"
            endpoint.parent.mkdir(parents=True)
            endpoint.write_text(json.dumps({"url": stub.url, "port": stub.port}), encoding="utf-8")
            code, out, err = self.run_atlas("--out", self.out)
        self.assertEqual(code, 0, out + err)
        self.assertEqual(stub.methods[0], "initialize")

    def test_dump_json_saves_what_the_server_listed(self):
        dump = self.tmp / "dump.json"
        with StubServer(fixture_tools()) as stub:
            code, out, err = self.run_atlas("--endpoint", stub.url, "--out", self.out, "--dump-json", dump)
        self.assertEqual(code, 0, out + err)
        self.assertEqual(json.loads(dump.read_text(encoding="utf-8")), {"tools": fixture_tools()})

    def test_check_against_a_live_endpoint(self):
        self.render()
        with StubServer(fixture_tools()) as stub:
            code, out, _ = self.run_atlas("--endpoint", stub.url, "--out", self.out, "--check")
        self.assertEqual(code, 0, out)
        with StubServer(fixture_tools()[:-1]) as stub:
            code, out, _ = self.run_atlas("--endpoint", stub.url, "--out", self.out, "--check")
        self.assertEqual(code, 1, out)
        self.assertIn("frobnicate_widgets", out)

    def test_a_missing_endpoint_file_explains_how_to_start_the_server(self):
        code, out, err = self.run_atlas("--out", self.out)
        self.assertEqual(code, 1)
        self.assertIn("endpoint.json", out + err)
        self.assertRegex(out + err, r"compositor-setup|--mcp|Settings")
        # The app has one Settings window, with no "AI Agents" pane to point at.
        self.assertIn("Compositor > Settings…", out + err)
        self.assertNotIn("AI Agents", out + err)
        self.assertFalse(self.out.exists())

    def test_http_refusals_and_json_rpc_errors_fail(self):
        with StubServer(fixture_tools(), status=421) as stub:
            code, out, err = self.run_atlas("--endpoint", stub.url, "--out", self.out)
        self.assertEqual(code, 1)
        self.assertIn("421", out + err)
        with StubServer(fixture_tools(), error="tools/list") as stub:
            code, out, err = self.run_atlas("--endpoint", stub.url, "--out", self.out)
        self.assertEqual(code, 1)
        self.assertIn("Method not found", out + err)
        self.assertFalse(self.out.exists())

    def test_nothing_listening_fails_cleanly(self):
        with StubServer([]) as stub:
            url = stub.url  # the port is closed once the stub stops
        code, out, err = self.run_atlas("--endpoint", url, "--out", self.out)
        self.assertEqual(code, 1)
        self.assertIn(url, out + err)
        self.assertNotIn("Traceback", err)


class ArgumentTests(ToolAtlasTestCase):
    def test_bad_arguments_exit_2(self):
        for args in (["--bogus"], ["--endpoint", "http://127.0.0.1:9/mcp", "--from-json", FIXTURE]):
            with self.subTest(args=args):
                code, _, err = self.run_atlas(*args)
                self.assertEqual(code, 2)
                self.assertIn("usage", err.lower())

    def test_the_default_output_is_the_skills_reference(self):
        code, out, _ = self.run_atlas("--help")
        self.assertEqual(code, 0)
        self.assertIn("references/tool-atlas.md", out)


if __name__ == "__main__":
    unittest.main()
