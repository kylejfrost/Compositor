"""Shared helpers for the scripts/skills-eval tests (no tests here).

`StubCompositor` stands in for a dedicated Compositor instance's MCP endpoint on an ephemeral loopback port (never
2667): it answers `initialize` and `tools/call`, keeps a list of open tabs, and writes files where save and export
calls point so that the scripts under test can hash them. `load` imports a script from scripts/skills-eval by path.
"""

import http.server
import importlib.util
import json
import sys
import threading
import uuid
import zlib
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
EVAL_SCRIPTS = REPO / "scripts" / "skills-eval"


def load(name):
    """Imports scripts/skills-eval/<name>.py without writing bytecode into the repository."""
    if str(EVAL_SCRIPTS) not in sys.path:
        sys.path.insert(0, str(EVAL_SCRIPTS))
    path = EVAL_SCRIPTS / f"{name}.py"
    spec = importlib.util.spec_from_file_location(f"skills_eval_{name}", path)
    module = importlib.util.module_from_spec(spec)
    dont_write = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = dont_write
    return module


def read_png(path):
    """(width, height, rows of (r, g, b) tuples) of an 8-bit RGB PNG whose rows all use filter 0."""
    data = Path(path).read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    offset, idat, header = 8, b"", None
    while offset < len(data):
        length = int.from_bytes(data[offset:offset + 4], "big")
        kind = data[offset + 4:offset + 8]
        body = data[offset + 8:offset + 8 + length]
        if kind == b"IHDR":
            header = body
        elif kind == b"IDAT":
            idat += body
        offset += 12 + length
    width, height = int.from_bytes(header[0:4], "big"), int.from_bytes(header[4:8], "big")
    assert header[8:10] == bytes([8, 2]), "expected 8-bit RGB"
    raw = zlib.decompress(idat)
    stride = width * 3 + 1
    rows = []
    for y in range(height):
        line = raw[y * stride:(y + 1) * stride]
        assert line[0] == 0, "expected filter 0"
        rows.append([tuple(line[1 + 3 * x:4 + 3 * x]) for x in range(width)])
    return width, height, rows


class StubCompositor:
    """A loopback stand-in for Compositor's MCP endpoint.

    Tools: get_app_info (reports `agent_folder`), list_documents, new_document, open_document, close_document
    (refuses unsaved changes unless discard_changes), save_document_as (a .comp is a folder with a manifest.json;
    .psd is refused as unsupported, as on a build without Photoshop saving), export_image (writes a small file),
    get_document (a new document gets a copy of `new_document_layers`, layers as get_document's detail full
    describes them, folders with `children`), get_history, get_layer_bounds (a layer's `content_bounds`) and
    get_text_metrics (text layers only), and any other tool answers ok. `failures` maps a tool name to an error code
    it answers with. Every tools/call is recorded in `calls` as (name, arguments). With a `token`, a request without
    `Authorization: Bearer <token>` gets 401, as Compositor answers when it requires its access token.
    """

    def __init__(self, agent_folder, failures=None, token=None):
        self.agent_folder = str(agent_folder)
        self.failures = dict(failures or {})
        self.token = token
        self.calls = []
        self.methods = []
        self.tabs = [self._empty_tab()]
        self.new_document_layers = []
        stub = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"null")
                if stub.token and self.headers.get("Authorization") != f"Bearer {stub.token}":
                    self.reply(401, b'{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Unauthorized"}}')
                    return
                stub.methods.append(body.get("method"))
                if "id" not in body:
                    self.reply(202, b"")
                    return
                answer = {"jsonrpc": "2.0", "id": body["id"]}
                if body["method"] == "initialize":
                    answer["result"] = {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}},
                                        "serverInfo": {"name": "Compositor", "version": "9.9"}}
                elif body["method"] == "tools/call":
                    params = body.get("params") or {}
                    answer["result"] = stub.call(params.get("name"), params.get("arguments") or {})
                else:
                    answer["error"] = {"code": -32601, "message": "Method not found"}
                self.reply(200, json.dumps(answer).encode())

            def reply(self, status, payload):
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
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

    @staticmethod
    def _empty_tab():
        return {"tab_id": str(uuid.uuid4()), "document_id": None, "title": "Untitled", "is_modified": False}

    def tool_names(self):
        return [name for name, _ in self.calls]

    @staticmethod
    def _public(tab, index):
        """A tab as list_documents describes it (without the stub's own layers and history)."""
        return {**{key: value for key, value in tab.items() if key not in ("layers", "history")}, "index": index}

    @staticmethod
    def _layers(layers):
        for layer in layers:
            yield layer
            yield from StubCompositor._layers(layer.get("children", []))

    def _layer(self, tab, selector):
        return next((layer for layer in self._layers(tab.get("layers", []))
                     if selector in (layer.get("id"), layer.get("name"), layer.get("path"))), None)

    @staticmethod
    def ok(payload):
        payload = {"ok": True, **payload}
        return {"content": [{"type": "text", "text": json.dumps(payload)}], "structuredContent": payload}

    @staticmethod
    def error(code, message):
        payload = {"ok": False, "error": {"code": code, "message": message}}
        return {"content": [{"type": "text", "text": json.dumps(payload)}], "structuredContent": payload,
                "isError": True}

    def _tab(self, selector):
        if selector is None:
            return self.tabs[-1]
        for index, tab in enumerate(self.tabs):
            if selector in (index, tab["tab_id"], tab["document_id"], tab["title"]):
                return tab
        return None

    def _path(self, raw):
        path = Path(raw)
        return path if path.is_absolute() else Path(self.agent_folder) / path

    def call(self, name, arguments):
        self.calls.append((name, arguments))
        if name in self.failures:
            return self.error(self.failures[name], f"{name} failed in the stub")
        if name == "get_app_info":
            return self.ok({"agent_folder": self.agent_folder, "name": "Compositor"})
        if name == "list_documents":
            return self.ok({"tabs": [self._public(tab, index) for index, tab in enumerate(self.tabs)]})
        if name in ("new_document", "open_document", "duplicate_document"):
            tab = {"tab_id": str(uuid.uuid4()), "document_id": str(uuid.uuid4()),
                   "title": arguments.get("name") or Path(arguments.get("path", "doc")).stem, "is_modified": True,
                   "layers": json.loads(json.dumps(self.new_document_layers)), "history": ["New Document"]}
            if len(self.tabs) == 1 and self.tabs[0]["document_id"] is None:
                self.tabs = []
            self.tabs.append(tab)
            return self.ok({"tab_id": tab["tab_id"], "document_id": tab["document_id"]})
        if name == "close_document":
            tab = self._tab(arguments.get("document"))
            if tab is None:
                return self.error("not_found", "no such document")
            if tab["is_modified"] and not arguments.get("discard_changes"):
                return self.error("precondition_failed", "unsaved_changes")
            self.tabs.remove(tab)
            if not self.tabs:
                self.tabs.append(self._empty_tab())
            return self.ok({"closed": True, "remaining_tabs": len(self.tabs)})
        if name == "save_document_as":
            path = self._path(arguments["path"])
            if path.suffix == ".psd":
                return self.error("unsupported", "Compositor can't write Photoshop files yet.")
            if path.suffix == ".comp":
                path.mkdir(parents=True, exist_ok=True)
                (path / "manifest.json").write_text(json.dumps({"version": 10, "layers": []}), encoding="utf-8")
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"saved")
            if self.tabs:
                self.tabs[-1]["is_modified"] = False
            return self.ok({"path": str(path), "saved": True})
        if name in ("get_document", "get_history", "get_layer_bounds", "get_text_metrics"):
            tab = self._tab(arguments.get("document"))
            if tab is None:
                return self.error("not_found", "no such document")
            public = self._public(tab, self.tabs.index(tab))
            if tab["document_id"] is None:
                return self.ok({"tab": public, "document": None, "note": "No document in this tab."})
            if name == "get_document":
                return self.ok({"tab": public, "document": {
                    "id": tab["document_id"], "width": 1080, "height": 1920, "is_modified": tab["is_modified"],
                    "detail": arguments.get("detail", "summary"), "layers": tab["layers"]}})
            if name == "get_history":
                return self.ok({"undo_names": list(reversed(tab["history"])), "redo_names": [],
                                "undo_count": len(tab["history"]), "redo_count": 0,
                                "has_unsaved_changes": tab["is_modified"]})
            layer = self._layer(tab, arguments.get("layer"))
            if layer is None:
                return self.error("not_found", "no such layer")
            if name == "get_layer_bounds":
                return self.ok({"layer_id": layer["id"], "bounds": layer.get("bounds"),
                                "content_bounds": layer.get("content_bounds")})
            if layer.get("kind") != "text":
                return self.error("invalid_argument", "not a text layer")
            return self.ok({"layer_id": layer["id"], "overflows": False, "line_count": 1,
                            "font_name": (layer.get("text") or {}).get("font_name")})
        if name == "export_image":
            path = self._path(arguments["path"])
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"exported " + arguments["path"].encode())
            return self.ok({"path": str(path)})
        return self.ok({})
