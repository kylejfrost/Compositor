"""Shared pieces of the skill-eval harness: workspace paths, a JSON-RPC client for Compositor's MCP endpoint, the app
reset every run starts from, and file hashing. Standard library only (Python 3.9+).
"""

import hashlib
import json
import os
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SKILLS = REPO / "skills"
PROTOCOL = "2025-11-25"


def default_workspace():
    """`skills-workspace/` in this checkout (git-ignored), or SKILLS_EVAL_WORKSPACE."""
    return Path(os.environ.get("SKILLS_EVAL_WORKSPACE") or REPO / "skills-workspace")


def state_file(workspace):
    return Path(workspace) / "instance" / "state.json"


def sandbox(workspace):
    """The folder outside any checkout that holds the instance's home (so its Agent folder) and the sessions'
    projects: what instance.sh recorded, else SKILLS_EVAL_SANDBOX, else <temp>/compositor-skills-eval. Outside the
    repository, a session sees no git status and can't wander into skills/ from its working directory."""
    try:
        return Path(json.loads(state_file(workspace).read_text(encoding="utf-8"))["sandbox"])
    except (OSError, ValueError, KeyError):
        return Path(os.environ.get("SKILLS_EVAL_SANDBOX") or Path(tempfile.gettempdir()) / "compositor-skills-eval")


def endpoint_url(workspace, given=None):
    """The endpoint to use: `given`, else the one instance.sh recorded for this workspace."""
    if given:
        return given
    path = state_file(workspace)
    try:
        return json.loads(path.read_text(encoding="utf-8"))["url"]
    except (OSError, ValueError, KeyError):
        raise SystemExit(f"no Compositor instance recorded at {path}: run scripts/skills-eval/instance.sh start, "
                         "or pass --endpoint")


def instance_token(workspace):
    """The access token of the instance instance.sh recorded (read from the token file it keeps in the sandbox home),
    or None when it requires none or none is recorded. Never logged: callers put it in headers only."""
    try:
        token_file = json.loads(state_file(workspace).read_text(encoding="utf-8")).get("token_file")
        return Path(token_file).read_text(encoding="utf-8").strip() if token_file else None
    except (OSError, ValueError, AttributeError):
        return None


class ToolError(Exception):
    """A tool call Compositor answered with an error (isError), or a transport failure."""

    def __init__(self, tool, code, message):
        super().__init__(f"{tool}: {code}: {message}")
        self.tool, self.code, self.message = tool, code, message


class Endpoint:
    """Calls tools on a Compositor MCP endpoint over HTTP JSON-RPC, straight to loopback (no proxy, no Origin), with
    the access token when there is one."""

    def __init__(self, url, timeout=120, token=None):
        self.url, self.timeout, self.token = url, timeout, token
        self._opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self._protocol = None
        self._next_id = 0

    def _post(self, message):
        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if self._protocol:
            headers["MCP-Protocol-Version"] = self._protocol
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        request = urllib.request.Request(self.url, data=json.dumps(message).encode(), headers=headers, method="POST")
        with self._opener.open(request, timeout=self.timeout) as response:
            content_type = response.headers.get("Content-Type", "")
            body = response.read().decode("utf-8")
        if "text/event-stream" in content_type:
            data = [line[5:].strip() for line in body.splitlines() if line.startswith("data:")]
            body = data[-1] if data else "null"
        return json.loads(body) if body.strip() else None

    def rpc(self, method, params=None):
        self._next_id += 1
        message = {"jsonrpc": "2.0", "id": self._next_id, "method": method}
        if params is not None:
            message["params"] = params
        answer = self._post(message)
        if answer is None or "error" in answer:
            error = (answer or {}).get("error") or {}
            raise ToolError(method, error.get("code", "rpc_error"), error.get("message", "no answer"))
        return answer.get("result")

    def _initialize(self):
        if self._protocol is None:
            result = self.rpc("initialize", {"protocolVersion": PROTOCOL, "capabilities": {},
                                             "clientInfo": {"name": "compositor-skills-eval", "version": "1"}})
            self._protocol = (result or {}).get("protocolVersion") or PROTOCOL

    def call(self, tool, arguments=None):
        """The tool's result object (structuredContent, else its JSON text); raises ToolError when it failed."""
        try:
            self._initialize()
            result = self.rpc("tools/call", {"name": tool, "arguments": arguments or {}}) or {}
        except (urllib.error.URLError, OSError, ValueError) as error:
            raise ToolError(tool, "transport", str(error)) from None
        payload = result.get("structuredContent")
        if payload is None:
            texts = [item.get("text", "") for item in result.get("content", []) if item.get("type") == "text"]
            try:
                payload = json.loads(texts[0]) if texts else {}
            except ValueError:
                payload = {"text": texts[0]}
        if result.get("isError") or payload.get("ok") is False:
            error = payload.get("error") or {}
            raise ToolError(tool, error.get("code", "error"), error.get("message", json.dumps(payload)[:300]))
        return payload


def reset_app(endpoint, rounds=40):
    """Closes every document without saving until one empty tab is left; returns how many tabs were closed."""
    closed = 0
    for _ in range(rounds):
        tabs = endpoint.call("list_documents").get("tabs", [])
        if len(tabs) <= 1 and all(tab.get("document_id") is None for tab in tabs):
            return closed
        endpoint.call("close_document", {"document": tabs[-1]["tab_id"], "discard_changes": True})
        closed += 1
    raise ToolError("close_document", "reset_failed", f"documents still open after {rounds} closes")


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def tree_sha256(root):
    """{relative path: sha256} of every file under root (a .comp package is a folder, so its files are listed)."""
    root = Path(root)
    return {str(path.relative_to(root)): sha256(path)
            for path in sorted(root.rglob("*")) if path.is_file() and path.name != ".DS_Store"}


def is_inside(path, folder):
    """Whether `path` is `folder` or lies inside it, comparing real paths (/tmp and /private/tmp are the same)."""
    path, folder = Path(os.path.realpath(path)), Path(os.path.realpath(folder))
    return path == folder or folder in path.parents


MCP_PREFIX = "mcp__compositor__"


def read_events(path):
    """The stream-json events of a `claude -p --output-format stream-json` transcript; unreadable lines skipped."""
    events = []
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if isinstance(event, dict):
            events.append(event)
    return events


def result_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(item.get("text", f"[{item.get('type')}]") for item in content if isinstance(item, dict))
    return ""


def session_steps(events):
    """The session in order: {"kind": "text", "text"} for what the model said and {"kind": "tool", "name", "input",
    "ok", "result"} for each tool call, answered from its tool_result. Compositor's tools lose Claude Code's
    mcp__compositor__ prefix; other tools (Bash, Read, ...) keep their names."""
    steps, by_id = [], {}
    for event in events:
        message = event.get("message")
        # Some events carry a string message (a permission_denied system event), not a message object.
        content = message.get("content") if isinstance(message, dict) else None
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            if event.get("type") == "assistant" and block.get("type") == "text" and block.get("text", "").strip():
                steps.append({"kind": "text", "text": block["text"]})
            elif event.get("type") == "assistant" and block.get("type") == "tool_use":
                name = block.get("name", "")
                step = {"kind": "tool", "id": block.get("id"), "name": name[len(MCP_PREFIX):]
                        if name.startswith(MCP_PREFIX) else name, "input": block.get("input") or {}, "ok": None,
                        "result": ""}
                steps.append(step)
                by_id[step["id"]] = step
            elif event.get("type") == "user" and block.get("type") == "tool_result" and block.get("tool_use_id") in by_id:
                step = by_id[block["tool_use_id"]]
                step["ok"] = not block.get("is_error", False)
                step["result"] = result_text(block.get("content"))
    return steps


def tool_calls(steps):
    """Every tool call in order as {"name", "args", "ok", "via"}; each step of a run_batch follows its batch as a
    call of its own (via "run_batch"), since the batch made that call."""
    calls = []
    for step in steps:
        if step["kind"] != "tool":
            continue
        calls.append({"name": step["name"], "args": step["input"], "ok": step["ok"], "via": None})
        if step["name"] == "run_batch":
            for inner in step["input"].get("steps") or []:
                if isinstance(inner, dict):
                    calls.append({"name": inner.get("tool"), "args": inner.get("arguments") or {}, "ok": step["ok"],
                                  "via": "run_batch"})
    return calls


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
