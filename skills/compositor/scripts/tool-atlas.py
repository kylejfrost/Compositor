#!/usr/bin/env python3
"""Write the compositor skill's tool atlas (references/tool-atlas.md) from Compositor's own tools/list.

The atlas groups every MCP tool by domain and lists its title, description, annotations (read-only, additive or
destructive, idempotent) and every parameter, nested members included, with its type, whether it is required, its
default, its enum values and its minimum and maximum. Because it is generated from the running app, it can't drift
from the tools agents actually call; --check says when the committed copy has.

Where the tool list comes from (one of):
  --endpoint URL          a running Compositor, e.g. http://127.0.0.1:2667/mcp
  --endpoint-file PATH    the endpoint file a running Compositor writes (the default:
                          ~/Library/Application Support/Compositor/mcp/endpoint.json)
  --from-json FILE        a saved tools/list result: {"tools": [...]}, the JSON-RPC response, or a bare list

Python 3.9+, standard library only. Exit status: 0 done (or up to date), 1 failure or drift, 2 bad arguments.
"""

import argparse
import difflib
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

SKILL = Path(__file__).resolve().parent.parent
DEFAULT_OUT = SKILL / "references" / "tool-atlas.md"
DEFAULT_ENDPOINT_FILE = "~/Library/Application Support/Compositor/mcp/endpoint.json"
PROTOCOL_VERSION = "2025-11-25"
TIMEOUT = 30

# Every tool by domain, in the order an agent meets them. A tool missing here lands under "Other", which the skill
# tests refuse, so a new tool gets a home when it is added. Names not (yet) in tools/list are simply left out.
DOMAINS = [
    ("Documents and app", [
        "list_documents", "get_document", "get_app_info", "select_document", "new_document", "open_document",
        "save_document", "save_document_as", "export_image", "close_document", "duplicate_document",
        "revert_document", "settle_pending_edits"]),
    ("Previews and sampling", [
        "render_document", "render_region", "render_layer", "get_layer_bounds", "get_pixel_color", "sample_colors"]),
    ("Files", ["list_files", "get_file_info", "reveal_in_finder"]),
    ("Layers", [
        "get_layer", "add_blank_layer", "add_image_layer", "add_group", "rename_layer", "set_layer_visibility",
        "set_layer_opacity", "set_layer_fill_opacity", "set_layer_blend_mode", "set_layer_locks", "delete_layers",
        "duplicate_layer", "layer_via_copy", "reorder_layer", "place_layer", "group_layers", "ungroup_layer",
        "set_clipping_mask", "select_layers", "merge_layers", "flatten_image", "rasterize_layer"]),
    ("Transforms and alignment", [
        "move_layer", "set_layer_transform", "set_layer_scale", "scale_layer_to_fit", "rotate_layer", "flip_layer",
        "distort_layer", "align_layers", "distribute_layers"]),
    ("Canvas and guides", [
        "resize_canvas", "resize_image", "set_resolution", "crop", "trim_canvas", "flip_canvas", "add_guide",
        "remove_guide", "clear_guides", "list_guides"]),
    ("Text and fonts", [
        "add_text_layer", "set_text", "set_text_style", "fit_text", "get_text_metrics", "list_fonts", "check_fonts"]),
    ("Shapes", ["add_shape", "set_shape_style"]),
    ("Smart objects", [
        "place_smart_object", "replace_smart_object_contents", "get_smart_object_info",
        "export_smart_object_contents"]),
    ("Layer effects", ["set_layer_effects", "add_layer_effect", "remove_layer_effect", "set_layer_effect_enabled"]),
    ("Adjustment layers and profiles", ["add_adjustment_layer", "set_adjustment", "list_profiles", "import_profile"]),
    ("Selection", [
        "select_rect", "select_ellipse", "select_polygon", "select_all", "select_none", "invert_selection",
        "select_by_color", "select_object", "select_subject", "load_layer_selection", "modify_selection",
        "transform_selection", "move_selected_pixels", "get_selection"]),
    ("Pixels and painting", [
        "fill_selection", "clear_selection", "invert_pixels", "stroke_path", "draw_gradient", "get_layer_pixels",
        "set_layer_pixels", "paste_image_into_layer", "copy_pixels", "paste_pixels"]),
    ("Filters and destructive adjustments", [
        "apply_filter", "apply_levels", "apply_hue_saturation", "content_aware_fill", "remove_background"]),
    ("Masks", [
        "add_layer_mask", "set_mask_enabled", "set_mask_linked", "delete_layer_mask", "apply_layer_mask",
        "copy_layer_mask"]),
    ("History and batches", ["undo", "redo", "get_history", "run_batch"]),
    ("View and app window", ["zoom_to_fit", "set_zoom", "select_tool", "bring_app_to_front", "set_palette_colors"]),
]
OTHER = "Other"


class AtlasError(Exception):
    """A failure the script reports in one line (exit status 1)."""


# MARK: - Getting the tool list

def tools_from_json(path):
    try:
        data = json.loads(Path(path).expanduser().read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise AtlasError(f"can't read a tools/list result from {path}: {error}") from None
    if isinstance(data, dict) and isinstance(data.get("result"), dict):
        data = data["result"]
    if isinstance(data, dict):
        data = data.get("tools")
    if not isinstance(data, list) or not all(isinstance(tool, dict) and isinstance(tool.get("name"), str) for tool in data):
        raise AtlasError(f"{path} holds no tools/list result (expected {{\"tools\": [...]}})")
    return data


def endpoint_url_from_file(path):
    file = Path(path).expanduser()
    if not file.exists():
        raise AtlasError(f"no endpoint file at {file}: Compositor's MCP server isn't running. Start it (Compositor > "
                         "Settings…, or launch Compositor with --mcp; see the compositor-setup skill), or pass --endpoint.")
    try:
        url = json.loads(file.read_text(encoding="utf-8")).get("url")
    except (OSError, ValueError, AttributeError) as error:
        raise AtlasError(f"can't read the endpoint file {file}: {error}") from None
    if not isinstance(url, str) or not url.startswith("http"):
        raise AtlasError(f"the endpoint file {file} names no URL")
    return url


def post(opener, url, message, protocol=None):
    """One JSON-RPC request; returns its result. Compositor's stateless server answers with JSON, but an event
    stream is read too."""
    headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    if protocol:
        headers["MCP-Protocol-Version"] = protocol
    request = urllib.request.Request(url, data=json.dumps(message).encode(), headers=headers, method="POST")
    try:
        with opener.open(request, timeout=TIMEOUT) as response:
            body = response.read().decode("utf-8", "replace")
            content_type = response.headers.get("Content-Type", "")
    except urllib.error.HTTPError as error:
        raise AtlasError(f"{url} refused {message['method']} with HTTP {error.code} {error.reason}") from None
    except (urllib.error.URLError, OSError) as error:
        reason = getattr(error, "reason", error)
        raise AtlasError(f"can't reach {url}: {reason}. Is Compositor's MCP server running? (compositor-setup skill)") from None
    if "text/event-stream" in content_type:
        events = [line[5:].strip() for line in body.splitlines() if line.startswith("data:")]
        body = next((event for event in events if '"id"' in event), events[-1] if events else "")
    try:
        answer = json.loads(body)
    except ValueError:
        raise AtlasError(f"{url} answered {message['method']} with something that isn't JSON") from None
    if "error" in answer:
        error = answer["error"]
        raise AtlasError(f"{message['method']} failed: {error.get('message', error)} (code {error.get('code')})")
    if not isinstance(answer.get("result"), dict):
        raise AtlasError(f"{url} answered {message['method']} without a result")
    return answer["result"]


def tools_from_endpoint(url):
    # Straight to the loopback server: a proxy would forward the request and Compositor would refuse its Host.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    initialized = post(opener, url, {
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": PROTOCOL_VERSION, "capabilities": {},
                   "clientInfo": {"name": "compositor-tool-atlas", "version": "1"}},
    })
    protocol = initialized.get("protocolVersion") or PROTOCOL_VERSION
    tools, cursor, request_id = [], None, 2
    while True:
        message = {"jsonrpc": "2.0", "id": request_id, "method": "tools/list"}
        if cursor:
            message["params"] = {"cursor": cursor}
        result = post(opener, url, message, protocol)
        page = result.get("tools")
        if not isinstance(page, list):
            raise AtlasError(f"{url} answered tools/list without a tools array")
        tools += page
        cursor = result.get("nextCursor")
        request_id += 1
        if not cursor or request_id > 1000:
            return tools


# MARK: - Rendering

def cell(text):
    """Text for one markdown table cell or paragraph: one line, pipes escaped."""
    return re.sub(r"\s+", " ", str(text)).strip().replace("|", "\\|")


def literal(value):
    return "`" + json.dumps(value, ensure_ascii=False) + "`"


def number(value):
    return str(int(value)) if isinstance(value, float) and value.is_integer() else str(value)


def type_name(schema):
    """The schema's type in a few words; alternatives are joined with |, objects inside them name their members."""
    if "anyOf" in schema or "oneOf" in schema:
        return " | ".join(type_name(branch) for branch in schema.get("anyOf") or schema.get("oneOf"))
    kind = schema.get("type", "any")
    if isinstance(kind, list):
        return " | ".join(kind)
    if kind == "array" and isinstance(schema.get("items"), dict):
        return f"array of {type_name(schema['items'])}"
    return kind


# Compositor's schemas list their keys in no particular order, so the atlas orders them itself (see ordered()).
SELECTORS = ("document", "layer", "layers")
PAIRED = ("x", "y", "width", "height", "r", "g", "b", "a")


def ordered(properties, required=()):
    """Parameter names in the atlas's order: the document and layer selectors, then the required parameters, then
    the optional ones; within each group x, y, width, height and r, g, b, a come in that order, the rest
    alphabetically. The same schema gives the same atlas whatever order the server lists its keys in."""
    def key(name):
        if name in SELECTORS:
            return (0, SELECTORS.index(name), name)
        return (1 if name in required else 2, PAIRED.index(name) if name in PAIRED else len(PAIRED), name)
    return sorted(properties, key=key)


def inline_type(schema):
    """An alternative inside anyOf/oneOf, spelled out in full since it gets no rows of its own."""
    kind = schema.get("type", "any")
    if kind == "object" and schema.get("properties"):
        return "object {" + ", ".join(ordered(schema["properties"])) + "}"
    if kind == "string" and "pattern" in schema:
        return f"string `{schema['pattern']}`"
    if kind == "string" and "enum" in schema:
        return "one of " + ", ".join(f"`{value}`" for value in schema["enum"])
    bounds = limits(schema)
    return f"{kind} {bounds}" if bounds and kind in ("integer", "number") else type_name(schema)


def limits(schema):
    low, high = schema.get("minimum"), schema.get("maximum")
    if low is not None and high is not None:
        return f"{number(low)}–{number(high)}"
    if low is not None:
        return f"≥ {number(low)}"
    if high is not None:
        return f"≤ {number(high)}"
    return ""


def allowed(schema):
    """Enum values, the numeric range, the item count or the length an argument must have."""
    parts = []
    if "enum" in schema:
        parts.append(", ".join(f"`{value}`" for value in schema["enum"]))
    if limits(schema):
        parts.append(limits(schema))
    low, high = schema.get("minItems"), schema.get("maxItems")
    if low is not None or high is not None:
        parts.append(f"{low}–{high} items" if low is not None and high is not None
                     else f"≥ {low} items" if low is not None else f"≤ {high} items")
    if schema.get("type") == "string" and "pattern" in schema:
        parts.append(f"`{schema['pattern']}`")
    return "; ".join(parts)


def is_value_object(schema):
    """A small object of plain members, such as a color {r, g, b} or a point {x, y}: its summary says enough."""
    members = schema.get("properties") or {}
    return len(members) <= 3 and all(member.get("type") in ("number", "integer", "string", "boolean")
                                     for member in members.values())


def parameter_rows(properties, required, prefix=""):
    """One row per parameter, depth first: an object's members follow it as `name.member`, an array of objects'
    members as `name[].member`. Alternatives (anyOf) are summarized inline; one that is a structured object (not a
    small value object such as a color) also gets rows for its members."""
    rows = []
    for name in ordered(properties, required):
        schema, path = properties[name], prefix + name
        alternatives = schema.get("anyOf") or schema.get("oneOf")
        kind = " | ".join(inline_type(branch) for branch in alternatives) if alternatives else type_name(schema)
        rows.append("| `{}` | {} | {} | {} | {} | {} |".format(
            path, cell(kind), "yes" if name in required else "",
            literal(schema["default"]) if "default" in schema else "", cell(allowed(schema)),
            cell(schema.get("description", ""))))
        if alternatives:
            for branch in alternatives:
                if branch.get("type") == "object" and branch.get("properties") and not is_value_object(branch):
                    rows += parameter_rows(branch["properties"], set(branch.get("required", [])), path + ".")
            continue
        if schema.get("type") == "object" and schema.get("properties"):
            rows += parameter_rows(schema["properties"], set(schema.get("required", [])), path + ".")
        items = schema.get("items")
        if schema.get("type") == "array" and isinstance(items, dict) and items.get("properties"):
            rows += parameter_rows(items["properties"], set(items.get("required", [])), path + "[].")
    return rows


def effect(annotations):
    if not annotations:
        return "no annotations declared"
    if annotations.get("readOnlyHint"):
        words = ["read-only"]
    else:
        # MCP's default for a tool that isn't read-only is destructive.
        words = ["additive" if annotations.get("destructiveHint") is False else "destructive"]
    if annotations.get("idempotentHint"):
        words.append("idempotent")
    if annotations.get("openWorldHint"):
        words.append("open world")
    return ", ".join(words)


def anchor(title):
    return re.sub(r"[^a-z0-9 -]", "", title.lower()).replace(" ", "-")


def group(tools):
    """[(domain, [tool, ...])] in DOMAINS order, tools in tools/list order, unknown tools under Other."""
    domain_of = {name: domain for domain, names in DOMAINS for name in names}
    grouped = {}
    for tool in tools:
        grouped.setdefault(domain_of.get(tool["name"], OTHER), []).append(tool)
    order = [domain for domain, _ in DOMAINS] + [OTHER]
    return [(domain, grouped[domain]) for domain in order if domain in grouped]


def render(tools, note=None):
    groups = group(tools)
    lines = ["# Compositor tool atlas", ""]
    if note:
        lines += [f"> {cell(note)}", ""]
    lines += [
        f"Generated from Compositor's `tools/list` by `scripts/tool-atlas.py`; do not edit by hand. {len(tools)} tools "
        f"in {len(groups)} groups. Each parameter row gives its type, whether it is required, its default and what "
        "it allows; `a.b` rows are members of object `a`, `a[].b` members of the objects in array `a`. Effect comes "
        "from the tool's annotations: read-only tools change nothing, additive ones only add (and are undoable), "
        "destructive ones can replace or discard something.",
        "",
        "When a call's schema and this file disagree, the server is right: regenerate with `python3 scripts/tool-atlas.py` "
        "from the compositor skill's folder while Compositor's MCP server runs.",
        "",
        "## Contents",
        "",
    ]
    for domain, members in groups:
        names = ", ".join(f"`{tool['name']}`" for tool in members)
        lines.append(f"- [{domain}](#{anchor(domain)}) ({len(members)}): {names}")
    for domain, members in groups:
        lines += ["", f"## {domain}"]
        for tool in members:
            title = tool.get("title") or (tool.get("annotations") or {}).get("title") or ""
            schema = tool.get("inputSchema") or {}
            properties = schema.get("properties") or {}
            lines += ["", f"### `{tool['name']}`" + (f" — {cell(title)}" if title else ""), "",
                      f"**Effect:** {effect(tool.get('annotations'))}", "", cell(tool.get("description", "")), ""]
            if not properties:
                lines.append("No parameters.")
                continue
            lines += ["| Parameter | Type | Required | Default | Allowed | Description |",
                      "|---|---|---|---|---|---|"]
            lines += parameter_rows(properties, set(schema.get("required", [])))
    return "\n".join(line.rstrip() for line in lines) + "\n"


# MARK: - Main

def parse_arguments(argv):
    parser = argparse.ArgumentParser(
        prog="tool-atlas.py",
        description="Write references/tool-atlas.md from Compositor's tools/list, or --check the committed copy.")
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--endpoint", metavar="URL", help="a running Compositor's MCP URL, e.g. http://127.0.0.1:2667/mcp")
    source.add_argument("--endpoint-file", metavar="PATH",
                        help=f"the endpoint file to read the URL from (default {DEFAULT_ENDPOINT_FILE})")
    source.add_argument("--from-json", metavar="FILE", help="a saved tools/list result instead of a running app")
    parser.add_argument("--out", metavar="PATH", default=str(DEFAULT_OUT),
                        help="the atlas to write or check (default: this skill's references/tool-atlas.md)")
    parser.add_argument("--check", action="store_true",
                        help="write nothing; exit 1 with a unified diff when the atlas at --out differs")
    parser.add_argument("--dump-json", metavar="FILE", help="also save the tools/list result as JSON")
    parser.add_argument("--note", metavar="TEXT", help="a note to show under the title (e.g. which build it was made from)")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_arguments(argv)
    out = Path(args.out).expanduser()
    try:
        if args.from_json:
            tools = tools_from_json(args.from_json)
        else:
            tools = tools_from_endpoint(args.endpoint or endpoint_url_from_file(args.endpoint_file or DEFAULT_ENDPOINT_FILE))
        if args.dump_json:
            Path(args.dump_json).expanduser().write_text(json.dumps({"tools": tools}, indent=2, ensure_ascii=False) + "\n",
                                                         encoding="utf-8")
        atlas = render(tools, args.note)
        if args.check:
            if not out.exists():
                raise AtlasError(f"no atlas at {out} to check; run without --check to write it")
            committed = out.read_text(encoding="utf-8")
            if committed == atlas:
                print(f"tool atlas up to date: {out} ({len(tools)} tools)")
                return 0
            diff = list(difflib.unified_diff(committed.splitlines(), atlas.splitlines(),
                                             f"{out} (committed)", "tools/list (now)", lineterm=""))
            removed = sum(1 for line in diff if line.startswith("-") and not line.startswith("---"))
            added = sum(1 for line in diff if line.startswith("+") and not line.startswith("+++"))
            print("\n".join(diff))
            print(f"tool atlas drift: {removed} line{'s' if removed != 1 else ''} removed, "
                  f"{added} line{'s' if added != 1 else ''} added; regenerate with tool-atlas.py (without --check)")
            return 1
        out.parent.mkdir(parents=True, exist_ok=True)
        temporary = out.with_name(out.name + ".tmp")
        temporary.write_text(atlas, encoding="utf-8")
        os.replace(temporary, out)
        print(f"wrote {out}: {len(tools)} tools")
        return 0
    except AtlasError as error:
        print(f"tool-atlas: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
