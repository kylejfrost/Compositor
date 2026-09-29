#!/usr/bin/env python3
"""Grades the script-checkable expectations of eval runs and writes each run's grading.json.

    python3 scripts/skills-eval/grade_scripted.py <run folder or any folder above runs> [...] [--checks FILE]

A run folder is one run_eval.py wrote (eval_metadata.json, transcript.jsonl, outputs/, final-state/); one without
timing.json was stopped during its session and is skipped. The checks come from scripts/skills-eval/checks/<skill>.json
(or --checks): per eval id, a list of {"match": <text found in exactly one expectation>, "checks": [...]}; an
expectation passes when all its checks pass. Expectations no spec matches are listed under "needs_grader" for a
grader agent (skill-creator agents/grader.md; grade_agent.py runs one), which adds its verdicts to the same
"expectations" list and recomputes "summary"; "grader_inputs" tells it where to look, including final-state/ (what
the app had open when the session ended). Grading again recomputes every scripted verdict and keeps the agent's
verdicts (for expectations the eval still has, and no spec now scripts) and its claims, notes and eval feedback. A spec whose text matches no expectation is listed under "stale_checks". Paths are relative to
the run's outputs/ (the Agent folder after the session); "baseline" paths are relative to the replayed fixture
folder, which nothing has touched.

Check types (all fields but "type" as listed):
  exists        path | glob [exclude, min=1]            the file or folder exists / at least min matches
  image_size    path | glob [exclude] width height      one file has that size (sips) [tolerance, format, alpha]
  image_sizes   glob [exclude] sizes: [[w, h], ...]     the matched files have exactly these sizes
  unchanged     path                                    same sha256 as when the session started (every file of
                                                        a folder such as a .comp)
  psd_verify    path | glob [exclude]                   psd-verify.py exits 0 on every match (at least one)
  psd_same_structure  path | glob, baseline             the same layer kinds and depths, in order
  psd_layer     path | glob, layer, one or more of: equals {field: value or operators}, center_x [tolerance],
                baseline with delta {field: n} or same [fields], bits {field: mask}
                                                        layer is a path of names ("Card/Name"); fields are dotted
                                                        into the psd-verify --raw report ("text.text", "bbox.1")
  comp_layer    path (a .comp), layer, and the same conditions as psd_layer, read from manifest.json
                                                        ("transform.origin.0", "locks", "opacity")
  pixel         path, x, y (or "center"), equals {r|g|b|a: value or operators}   one point's color, 0-1
  image_compare path, other, stat (mean_luminance | mean_red_minus_blue), relation (< > <= >=)
                                                        path's statistic relates so to other's
  image_differs path, other [min_fraction=0.01]         at least that share of pixels differs by more than 8/255
                (the pixel and image checks run image_stats.py with Pillow through uv)
  called / not_called   a call matcher (no tool: any tool)   some / no call matches
  order         steps: [matcher, ...] [after_last: matcher]   the calls happen in this order (others in between),
                                                        after the last after_last call when given
  first_before  first: matcher, before: matcher         the first "first" call comes before any "before" call
  last_after    last: matcher, after: matcher           a "last" call comes after the final "after" call
  any           checks: [...]                           at least one of the checks passes
A call matcher is {"tool": name} or {"any": [names]}, with optional "args" (a subset of the arguments; a value
may be {"<=": n}, {">=": n}, {"<": n}, {">": n}, {"in": [...]} or {"matches": regex}) and "ok" (the call
succeeded, or failed). Compositor tools are named without Claude Code's mcp__compositor__ prefix; run_batch steps
count as calls after their batch.
"""

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.dont_write_bytecode = True  # no __pycache__ for evalkit in the checkout

from evalkit import REPO, read_events, session_steps, sha256, tool_calls, write_json  # noqa: E402

CHECKS = Path(__file__).resolve().parent / "checks"
PSD_VERIFY = REPO / "scripts" / "psd-verify.py"
FILE_TYPES = {"exists", "image_size", "image_sizes", "unchanged", "psd_verify", "psd_same_structure", "psd_layer",
              "comp_layer", "pixel", "image_compare", "image_differs"}
IMAGE_STATS = Path(__file__).resolve().parent / "image_stats.py"
IMAGE_STAT_NAMES = ("mean_luminance", "mean_red_minus_blue")
CALL_TYPES = {"called", "not_called", "order", "first_before", "last_after"}
CHECK_TYPES = FILE_TYPES | CALL_TYPES | {"any"}
OPERATORS = {"<=", ">=", "<", ">", "in", "matches"}
LAYER_CONDITIONS = ("equals", "center_x", "delta", "same", "bits")
MISSING = object()


def psd_report(path):
    """(exit status, report) of scripts/psd-verify.py --raw on a PSD, run with psd-tools through uv."""
    with tempfile.TemporaryDirectory(prefix="psd-verify-") as folder:
        out = Path(folder) / "report.json"
        result = subprocess.run(["uv", "run", "--quiet", "--with", "psd-tools", "python3", str(PSD_VERIFY), str(path),
                                 "--raw", "--json", str(out)], capture_output=True, text=True, timeout=300)
        report = json.loads(out.read_text(encoding="utf-8")) if out.is_file() else {
            "errors": [result.stderr.strip()[-500:]], "layers": []}
    return result.returncode, report


def image_stats(path, points=(), other=None):
    """image_stats.py's report on an image (run with Pillow through uv): width, height, mean_luminance,
    mean_red_minus_blue, the {r, g, b, a} of each point, and with `other` diff_fraction."""
    command = ["uv", "run", "--quiet", "--with", "pillow", "python3", str(IMAGE_STATS), str(path),
               "--points", json.dumps(list(points))]
    if other is not None:
        command += ["--other", str(other)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=300)
    if result.returncode != 0:
        raise ValueError(f"image_stats.py failed on {Path(path).name}: {result.stderr.strip()[-300:]}")
    return json.loads(result.stdout)


def image_info(path):
    """{"width", "height", "format", "alpha"} from sips, or None when sips can't read it."""
    result = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "format", "-g", "hasAlpha",
                             str(path)], capture_output=True, text=True, timeout=60)
    fields = dict(re.findall(r"^\s+(\w+): (.+)$", result.stdout, re.M))
    if result.returncode != 0 or "pixelWidth" not in fields:
        return None
    return {"width": int(fields["pixelWidth"]), "height": int(fields["pixelHeight"]),
            "format": fields.get("format", "").strip(), "alpha": fields.get("hasAlpha", "").strip() == "yes"}


def dig(value, field):
    for part in str(field).split("."):
        if isinstance(value, dict) and part in value:
            value = value[part]
        elif isinstance(value, list) and re.fullmatch(r"-?\d+", part) and -len(value) <= int(part) < len(value):
            value = value[int(part)]
        else:
            return MISSING
    return value


def show(value):
    return "missing" if value is MISSING else json.dumps(value, ensure_ascii=False)


class Run:
    def __init__(self, run_dir):
        self.dir = Path(run_dir)
        self.outputs = self.dir / "outputs"
        self.metadata = json.loads((self.dir / "eval_metadata.json").read_text(encoding="utf-8"))
        before = self.dir / "agent-folder-before.json"
        self.before = json.loads(before.read_text(encoding="utf-8")) if before.is_file() else {}
        fixture_dir = self.metadata.get("fixture_dir")
        self.fixture_dir = Path(fixture_dir) if fixture_dir else None
        self._calls = None
        self._psd = {}

    @property
    def calls(self):
        if self._calls is None:
            transcript = self.dir / "transcript.jsonl"
            self._calls = tool_calls(session_steps(read_events(transcript))) if transcript.is_file() else []
        return self._calls

    def files(self, check, folders=True):
        """The outputs the check names (path or glob, minus exclude), relative to outputs/."""
        exclude = set(check.get("exclude", []))
        if "path" in check:
            candidates = [self.outputs / check["path"]] if (self.outputs / check["path"]).exists() else []
        else:
            candidates = sorted(self.outputs.glob(check["glob"]))
        return [path for path in candidates if str(path.relative_to(self.outputs)) not in exclude
                and (folders or path.is_file()) and path.name != "metrics.json"]

    def baseline(self, relative):
        if self.fixture_dir is None:
            raise LookupError("the run has no fixture folder to read a baseline from")
        path = self.fixture_dir / relative
        if not path.exists():
            raise LookupError(f"no baseline {relative} in {self.fixture_dir}")
        return path

    def psd(self, path):
        key = str(path)
        if key not in self._psd:
            self._psd[key] = psd_report(path)
        return self._psd[key]


def named(check):
    return check.get("path") or check.get("glob")


# MARK: - File checks

def check_exists(run, check):
    found = run.files(check)
    need = check.get("min", 1)
    names = ", ".join(str(path.relative_to(run.outputs)) for path in found) or "nothing"
    return len(found) >= need, f"{named(check)}: found {names}"


def check_image_size(run, check):
    found = run.files(check, folders=False)
    if not found:
        return False, f"no file matches {named(check)}"
    tolerance = check.get("tolerance", 0)
    seen = []
    for path in found:
        info = image_info(path)
        label = str(path.relative_to(run.outputs))
        if info is None:
            seen.append(f"{label}: unreadable")
            continue
        seen.append(f"{label}: {info['width']} x {info['height']} {info['format']}{' with alpha' if info['alpha'] else ''}")
        if (abs(info["width"] - check["width"]) <= tolerance and abs(info["height"] - check["height"]) <= tolerance
                and check.get("format", info["format"]) == info["format"]
                and check.get("alpha", info["alpha"]) == info["alpha"]):
            return True, "; ".join(seen)
    return False, f"wanted {check['width']} x {check['height']}: " + "; ".join(seen)


def check_image_sizes(run, check):
    found = run.files(check, folders=False)
    sizes = {}
    for path in found:
        info = image_info(path)
        sizes[str(path.relative_to(run.outputs))] = [info["width"], info["height"]] if info else None
    wanted = sorted(map(list, check["sizes"]))
    got = sorted(size for size in sizes.values() if size)
    listing = "; ".join(f"{name}: {size[0]} x {size[1]}" if size else f"{name}: unreadable"
                        for name, size in sizes.items()) or "no files"
    return got == wanted and None not in sizes.values(), f"wanted {wanted}: {listing}"


def check_unchanged(run, check):
    prefix = check["path"].rstrip("/")
    tracked = {path: digest for path, digest in run.before.items() if path == prefix or path.startswith(prefix + "/")}
    if not tracked:
        return False, f"{prefix} was not among the files the session started with"
    changed = []
    for path, digest in sorted(tracked.items()):
        current = run.outputs / path
        if not current.is_file():
            changed.append(f"{path} is gone")
        elif sha256(current) != digest:
            changed.append(f"{path} changed")
    if changed:
        return False, "; ".join(changed)
    return True, f"{len(tracked)} file(s) under {prefix} have the sha256 they started with"


def psd_files(run, check):
    return [path for path in run.files(check, folders=False) if path.suffix.lower() == ".psd"]


def check_psd_verify(run, check):
    found = psd_files(run, check)
    if not found:
        return False, f"no PSD matches {named(check)}"
    results = []
    for path in found:
        status, report = run.psd(path)
        problems = (report.get("errors") or []) + (report.get("warnings") or [])
        results.append((status, f"{path.relative_to(run.outputs)}: exit {status}"
                        + (f" ({'; '.join(map(str, problems))[:300]})" if problems else "")))
    return all(status == 0 for status, _ in results), "; ".join(text for _, text in results)


def structure(report):
    return [(layer.get("kind"), layer.get("depth")) for layer in report.get("layers", [])]


def check_psd_same_structure(run, check):
    found = psd_files(run, check)
    if not found:
        return False, f"no PSD matches {named(check)}"
    wanted = structure(run.psd(run.baseline(check["baseline"]))[1])
    for path in found:
        got = structure(run.psd(path)[1])
        if got == wanted:
            return True, f"{path.relative_to(run.outputs)}: {len(got)} layers, kinds and depths as in {check['baseline']}"
    return False, f"{check['baseline']} has {wanted}; " + "; ".join(
        f"{path.relative_to(run.outputs)} has {structure(run.psd(path)[1])}" for path in found)


def psd_layers(report):
    """{path of names: layer} from psd-verify's top-to-bottom, groups-before-contents order."""
    layers, stack = {}, []
    for layer in report.get("layers", []):
        stack = stack[:layer.get("depth", 0)] + [str(layer.get("name", "#" + str(layer.get("index"))))]
        layers.setdefault("/".join(stack), layer)
    return layers


def comp_layers(manifest):
    records = manifest.get("layers", [])
    by_id = {record.get("id"): record for record in records}
    layers = {}
    for record in records:
        names, node, depth = [], record, 0
        while node is not None and depth < 64:
            names.append(str(node.get("name")))
            node, depth = by_id.get(node.get("parentID")), depth + 1
        layers.setdefault("/".join(reversed(names)), record)
    return layers


def psd_center_x(layer):
    bbox = layer.get("bbox") or [0, 0, 0, 0]
    return (bbox[0] + bbox[2]) / 2


def comp_center_x(layer):
    transform = layer.get("transform") or {}
    return (transform.get("origin") or [0, 0])[0] + (transform.get("size") or [0, 0])[0] / 2


def layer_conditions(check, layer, base, center_x):
    """Problems with one layer against the check's conditions (empty when it passes)."""
    problems = []
    for field, expected in (check.get("equals") or {}).items():
        actual = dig(layer, field)
        if not value_matches(actual, expected):
            problems.append(f"{field} is {show(actual)}, not {show(expected)}")
    if "center_x" in check:
        center = center_x(layer)
        if abs(center - check["center_x"]) > check.get("tolerance", 0):
            problems.append(f"center x is {center:g}, not {check['center_x']} ± {check.get('tolerance', 0)}")
    for field, mask in (check.get("bits") or {}).items():
        actual = dig(layer, field)
        if not isinstance(actual, int) or actual & mask != mask:
            problems.append(f"{field} is {show(actual)}, without bits {mask:#x}")
    if base is not None:
        for field, difference in (check.get("delta") or {}).items():
            actual, before = dig(layer, field), dig(base, field)
            if not all(isinstance(value, (int, float)) for value in (actual, before)) \
                    or abs(actual - before - difference) > check.get("tolerance", 0):
                problems.append(f"{field} went from {show(before)} to {show(actual)}, not by {difference:+g}")
        for field in check.get("same") or []:
            if dig(layer, field) != dig(base, field):
                problems.append(f"{field} is {show(dig(layer, field))}, was {show(dig(base, field))}")
    return problems


def check_layer(run, check, files, read_layers, center_x):
    if not files:
        return False, f"no file matches {named(check)}"
    base = None
    if "baseline" in check:
        base = read_layers(run.baseline(check["baseline"])).get(check["layer"])
        if base is None:
            return False, f"no layer {check['layer']} in the baseline {check['baseline']}"
    evidence = []
    for path in files:
        label = str(path.relative_to(run.outputs))
        layer = read_layers(path).get(check["layer"])
        if layer is None:
            evidence.append(f"{label}: no layer {check['layer']}")
            continue
        problems = layer_conditions(check, layer, base, center_x)
        if not problems:
            return True, f"{label}: {check['layer']} " + ", ".join(
                f"{k} {show(check[k])}" for k in LAYER_CONDITIONS if k in check)
        evidence.append(f"{label}: {check['layer']} " + "; ".join(problems))
    return False, " | ".join(evidence)


def check_psd_layer(run, check):
    return check_layer(run, check, psd_files(run, check), lambda path: psd_layers(run.psd(path)[1]), psd_center_x)


def read_comp(path):
    manifest = Path(path) / "manifest.json"
    return comp_layers(json.loads(manifest.read_text(encoding="utf-8"))) if manifest.is_file() else {}


def check_comp_layer(run, check):
    files = [path for path in run.files(check) if (path / "manifest.json").is_file()]
    return check_layer(run, check, files, read_comp, comp_center_x)


def one_image(run, check, key="path"):
    path = run.outputs / check[key]
    if not path.is_file():
        raise LookupError(f"no file {check[key]}")
    return path


def check_pixel(run, check):
    path = one_image(run, check)
    point = "center" if check["x"] == "center" or check["y"] == "center" else [check["x"], check["y"]]
    key = "center" if point == "center" else f"{int(point[0])},{int(point[1])}"
    color = image_stats(path, points=[point])["points"].get(key)
    if color is None:
        return False, f"{check['path']}: {key} is outside the image"
    problems = [f"{channel} is {color.get(channel)}, not {show(want)}"
                for channel, want in check["equals"].items() if not value_matches(color.get(channel, MISSING), want)]
    rgba = ", ".join(f"{channel} {color[channel]:g}" for channel in "rgba")
    return not problems, f"{check['path']} at {key}: {rgba}" + (f" ({'; '.join(problems)})" if problems else "")


def check_image_compare(run, check):
    path, other = one_image(run, check), one_image(run, check, "other")
    mine, theirs = image_stats(path)[check["stat"]], image_stats(other)[check["stat"]]
    passed = value_matches(mine, {check["relation"]: theirs})
    return passed, f"{check['stat']} {mine:g} in {check['path']}, {theirs:g} in {check['other']}"


def check_image_differs(run, check):
    path, other = one_image(run, check), one_image(run, check, "other")
    fraction = image_stats(path, other=other).get("diff_fraction")
    if fraction is None:
        return False, f"{check['path']} and {check['other']} have different sizes"
    need = check.get("min_fraction", 0.01)
    return fraction >= need, f"{fraction:.2%} of the pixels of {check['path']} differ from {check['other']} (need {need:.0%})"


# MARK: - Transcript checks

def is_operator(want):
    return isinstance(want, dict) and bool(want) and set(want) <= OPERATORS


def value_matches(have, want):
    """`have` equals `want`, or passes its operators ({"<=": n}, {"matches": regex}, ...)."""
    if have is MISSING:
        return False
    if is_operator(want):
        for op, operand in want.items():
            try:
                ok = {"<=": lambda: have <= operand, ">=": lambda: have >= operand, "<": lambda: have < operand,
                      ">": lambda: have > operand, "in": lambda: have in operand,
                      "matches": lambda: re.search(operand, str(have)) is not None}[op]()
            except TypeError:
                ok = False
            if not ok:
                return False
        return True
    return have == want and (type(have) is bool) == (type(want) is bool)


def args_match(actual, expected):
    for key, want in expected.items():
        have = actual.get(key, MISSING) if isinstance(actual, dict) else MISSING
        if isinstance(want, dict) and not is_operator(want):
            if not isinstance(have, dict) or not args_match(have, want):
                return False
        elif not value_matches(have, want):
            return False
    return True


def matches(call, matcher):
    names = matcher.get("any") or ([matcher["tool"]] if "tool" in matcher else None)
    if names is not None and call["name"] not in names:
        return False
    if "ok" in matcher and call["ok"] is not matcher["ok"]:
        return False
    return args_match(call["args"], matcher.get("args") or {})


def describe(matcher):
    names = matcher.get("any") or ([matcher["tool"]] if "tool" in matcher else [])
    text = " or ".join(names) + " call" if names else "call"
    if matcher.get("args"):
        text += " with " + json.dumps(matcher["args"], ensure_ascii=False)
    if "ok" in matcher:
        text += " that succeeded" if matcher["ok"] else " that failed"
    return text


def indices(run, matcher):
    return [index for index, call in enumerate(run.calls) if matches(call, matcher)]


def call_label(run, index):
    call = run.calls[index]
    return f"call {index + 1} {call['name']}" + (" (in run_batch)" if call["via"] else "")


def names_seen(run):
    names = [call["name"] for call in run.calls]
    return ", ".join(names[:40]) + (f" … ({len(names)} calls)" if len(names) > 40 else "") if names else "no tool calls"


def check_called(run, check):
    hits = indices(run, check)
    if hits:
        return True, f"{call_label(run, hits[0])}: {json.dumps(run.calls[hits[0]]['args'], ensure_ascii=False)[:300]}"
    return False, f"no {describe(check)}; calls: {names_seen(run)}"


def check_not_called(run, check):
    hits = indices(run, check)
    if hits:
        return False, f"{call_label(run, hits[0])} is a forbidden {describe(check)}"
    return True, f"no {describe(check)} among {len(run.calls)} calls"


def check_order(run, check):
    position, found = 0, []
    if "after_last" in check:  # only what happened after the final anchor call counts (not an attempt undone before)
        anchors = indices(run, check["after_last"])
        if not anchors:
            return False, f"no {describe(check['after_last'])}; calls: {names_seen(run)}"
        position, found = anchors[-1] + 1, [f"after {call_label(run, anchors[-1])}"]
    for step in check["steps"]:
        hit = next((index for index in indices(run, step) if index >= position), None)
        if hit is None:
            return False, (f"after {', '.join(found) or 'the start'} there is no {describe(step)}; "
                           f"calls: {names_seen(run)}")
        found.append(call_label(run, hit))
        position = hit + 1
    return True, " then ".join(found)


def check_first_before(run, check):
    first, before = indices(run, check["first"]), indices(run, check["before"])
    if not first:
        return False, f"no {describe(check['first'])}; calls: {names_seen(run)}"
    if before and before[0] < first[0]:
        return False, f"{call_label(run, before[0])} comes before the first {describe(check['first'])} ({first[0] + 1})"
    return True, f"{call_label(run, first[0])} comes first" + (f", before {call_label(run, before[0])}" if before else "")


def check_last_after(run, check):
    last, after = indices(run, check["last"]), indices(run, check["after"])
    if not after:
        return False, f"no {describe(check['after'])}; calls: {names_seen(run)}"
    later = [index for index in last if index > after[-1]]
    if not later:
        return False, f"no {describe(check['last'])} after {call_label(run, after[-1])}"
    return True, f"{call_label(run, later[0])} follows the last {describe(check['after'])} ({after[-1] + 1})"


def check_any(run, check):
    results = [evaluate(run, sub) for sub in check["checks"]]
    for passed, evidence in results:
        if passed:
            return True, evidence
    return False, " / ".join(evidence for _, evidence in results)


CHECKERS = {
    "exists": check_exists, "image_size": check_image_size, "image_sizes": check_image_sizes,
    "unchanged": check_unchanged, "psd_verify": check_psd_verify, "psd_same_structure": check_psd_same_structure,
    "psd_layer": check_psd_layer, "comp_layer": check_comp_layer, "pixel": check_pixel,
    "image_compare": check_image_compare, "image_differs": check_image_differs, "called": check_called,
    "not_called": check_not_called, "order": check_order, "first_before": check_first_before,
    "last_after": check_last_after, "any": check_any,
}


def evaluate(run, check):
    try:
        return CHECKERS[check["type"]](run, check)
    except (LookupError, OSError, ValueError, subprocess.SubprocessError) as error:
        return False, f"{check['type']}: {error}"


# MARK: - Specs

def relative_path_problems(check):
    problems = []
    for key in ("path", "glob", "baseline", "other"):
        if key in check and (not isinstance(check[key], str) or not check[key] or Path(check[key]).is_absolute()
                             or ".." in Path(check[key]).parts):
            problems.append(f"{key} must be a relative path inside the folder")
    for item in check.get("exclude", []):
        if Path(item).is_absolute() or ".." in Path(item).parts:
            problems.append("exclude paths must be relative")
    return problems


def matcher_problems(matcher, needs_tool=True):
    if not isinstance(matcher, dict):
        return ["a call matcher is an object"]
    problems = []
    if needs_tool and "tool" not in matcher and not matcher.get("any"):
        problems.append("a call matcher needs tool or any")
    if "args" in matcher and not isinstance(matcher["args"], dict):
        problems.append("args must be an object")
    if "ok" in matcher and not isinstance(matcher["ok"], bool):
        problems.append("ok must be true or false")
    return problems


def validate_check(check):
    """What is wrong with one check (an empty list when nothing is)."""
    kind = check.get("type")
    if kind not in CHECK_TYPES:
        return [f"unknown check type {kind!r}"]
    problems = relative_path_problems(check)
    if kind in FILE_TYPES:
        needs_path = kind in ("unchanged", "comp_layer")
        if needs_path and "path" not in check:
            problems.append(f"{kind} needs path")
        elif not needs_path and "path" not in check and "glob" not in check:
            problems.append(f"{kind} needs path or glob")
    if kind == "image_size" and not all(isinstance(check.get(key), int) for key in ("width", "height")):
        problems.append("image_size needs integer width and height")
    if kind == "image_sizes" and not (isinstance(check.get("sizes"), list) and check["sizes"] and "glob" in check):
        problems.append("image_sizes needs glob and sizes")
    if kind in ("pixel", "image_compare", "image_differs") and "path" not in check:
        problems.append(f"{kind} needs path")
    if kind == "pixel" and not ("x" in check and "y" in check and isinstance(check.get("equals"), dict)):
        problems.append("pixel needs x, y (numbers or \"center\") and equals")
    if kind in ("image_compare", "image_differs") and "other" not in check:
        problems.append(f"{kind} needs other")
    if kind == "image_compare" and (check.get("stat") not in IMAGE_STAT_NAMES
                                    or check.get("relation") not in ("<", ">", "<=", ">=")):
        problems.append(f"image_compare needs stat ({', '.join(IMAGE_STAT_NAMES)}) and relation (<, >, <=, >=)")
    if kind == "psd_same_structure" and "baseline" not in check:
        problems.append("psd_same_structure needs baseline")
    if kind in ("psd_layer", "comp_layer"):
        if not isinstance(check.get("layer"), str):
            problems.append(f"{kind} needs layer")
        if not any(key in check for key in LAYER_CONDITIONS):
            problems.append(f"{kind} needs one of {', '.join(LAYER_CONDITIONS)}")
        if ("delta" in check or "same" in check) and "baseline" not in check:
            problems.append("delta and same need baseline")
    if kind in ("called", "not_called"):
        problems += matcher_problems(check, needs_tool=kind == "called")
    if kind == "order":
        steps = check.get("steps")
        if not isinstance(steps, list) or not steps:
            problems.append("order needs steps")
        else:
            problems += [problem for step in steps for problem in matcher_problems(step)]
        if "after_last" in check:
            problems += matcher_problems(check["after_last"])
    if kind == "first_before":
        problems += matcher_problems(check.get("first")) + matcher_problems(check.get("before"))
    if kind == "last_after":
        problems += matcher_problems(check.get("last")) + matcher_problems(check.get("after"))
    if kind == "any":
        subs = check.get("checks")
        if not isinstance(subs, list) or not subs:
            problems.append("any needs checks")
        else:
            problems += [problem for sub in subs for problem in validate_check(sub)]
    return problems


def load_checks(skill):
    path = CHECKS / f"{skill}.json"
    return json.loads(path.read_text(encoding="utf-8")) if path.is_file() else {"skill_name": skill, "evals": {}}


AGENT_FIELDS = ("claims", "user_notes_summary", "eval_feedback", "grader_agent")


def read_previous(run_dir):
    try:
        previous = json.loads((Path(run_dir) / "grading.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return previous if isinstance(previous, dict) else {}


def summarize(results):
    passed = sum(1 for result in results if result["passed"])
    return {"passed": passed, "failed": len(results) - passed, "total": len(results),
            "pass_rate": round(passed / len(results), 2) if results else 0.0}


def grade_run(run_dir, checks=None):
    """Grades one run with `checks` (default: its skill's spec), writes <run>/grading.json and returns it."""
    run = Run(run_dir)
    checks = checks or load_checks(run.metadata["skill_name"])
    expectations = run.metadata.get("assertions", [])
    specs = checks.get("evals", {}).get(str(run.metadata["eval_id"]), [])
    scripted, stale = {}, []
    for spec in specs:
        hits = [index for index, text in enumerate(expectations) if spec["match"] in text]
        if len(hits) != 1:
            stale.append(spec["match"])
        else:
            scripted.setdefault(hits[0], []).append(spec)
    previous = read_previous(run.dir)
    agent = {entry["text"]: entry for entry in previous.get("expectations", [])
             if isinstance(entry, dict) and isinstance(entry.get("passed"), bool) and "text" in entry}
    results, needs_grader = [], []
    for index, text in enumerate(expectations):
        if index in scripted:
            outcomes = [evaluate(run, check) for spec in scripted[index] for check in spec["checks"]]
            results.append({"text": text, "passed": all(passed for passed, _ in outcomes),
                            "evidence": " | ".join(evidence for _, evidence in outcomes)})
        elif text in agent:  # the grader agent's verdict from before: kept, so a re-grade doesn't need it again
            results.append(agent[text])
        else:
            needs_grader.append(text)
    grading = {
        "expectations": results,
        "summary": summarize(results),
        "needs_grader": needs_grader,
        "stale_checks": stale,
        "grader": "grade_scripted.py",
        "grader_inputs": grader_inputs(run.dir),
        # What the grader agent wrote besides its verdicts (agents/grader.md), kept as it was.
        **{key: previous[key] for key in AGENT_FIELDS if key in previous},
    }
    # No "timing" here: skill-creator's aggregate_benchmark takes time and tokens from timing.json only when
    # grading.json has no timing.total_duration_seconds (with one, it counts output characters as tokens).
    metrics = run.outputs / "metrics.json"
    if metrics.is_file():
        grading["execution_metrics"] = json.loads(metrics.read_text(encoding="utf-8"))
    write_json(run.dir / "grading.json", grading)
    return grading


FINAL_STATE_NOTE = (
    "final-state/ is what Compositor had open when the session ended, captured by run_eval.py after the session and "
    "before its reset closed every document without saving: list_documents.json and, per tab with a document, "
    "tab-<index>.json with get_document (detail full: every layer's settings, text style and content_bounds), "
    "get_history, and get_layer_bounds and get_text_metrics for each text layer. Use it for expectations that may be "
    "checked on the open document (bounds, font sizes, opacity, undo entries); an expectation that asks what the "
    "agent itself did or checked still needs the transcript, since the agent never saw these calls.")


def grader_inputs(run_dir):
    """Where a grader agent finds the evidence for the needs_grader expectations, relative to the run folder."""
    return {"transcript": "transcript.md", "outputs": "outputs/",
            "final_state": "final-state/" if (Path(run_dir) / "final-state").is_dir() else None,
            "note": FINAL_STATE_NOTE}


def is_run(folder):
    return (folder / "eval_metadata.json").is_file() and (folder / "transcript.jsonl").is_file()


def run_dirs(path):
    """(complete runs, incomplete runs) at or under `path`. A run without timing.json never finished: run_eval.py was
    stopped during the session, and graded, it would count as a failed run."""
    path = Path(path)
    found = [path] if is_run(path) else sorted(folder for folder in path.rglob("*") if folder.is_dir()
                                               and is_run(folder))
    return ([run for run in found if (run / "timing.json").is_file()],
            [run for run in found if not (run / "timing.json").is_file()])


def main(argv=None):
    parser = argparse.ArgumentParser(description="Grade the scriptable expectations of eval runs.")
    parser.add_argument("paths", nargs="+", type=Path, help="run folders, or folders to search for runs")
    parser.add_argument("--checks", type=Path, help="a check spec to use instead of checks/<skill>.json")
    args = parser.parse_args(argv)
    checks = json.loads(args.checks.read_text(encoding="utf-8")) if args.checks else None
    found, incomplete = [], []
    for path in args.paths:
        complete, partial = run_dirs(path)
        found += complete
        incomplete += partial
    for run in incomplete:
        print(f"{run}: skipped, incomplete (no timing.json: run_eval.py was stopped during the session)",
              file=sys.stderr)
    if not found:
        print("no runs found", file=sys.stderr)
        return 1
    for run in found:
        grading = grade_run(run, checks)
        summary = grading["summary"]
        print(f"{run}: {summary['passed']}/{summary['total']} scripted passed, "
              f"{len(grading['needs_grader'])} left for the grader"
              + (f", stale checks: {grading['stale_checks']}" if grading["stale_checks"] else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
