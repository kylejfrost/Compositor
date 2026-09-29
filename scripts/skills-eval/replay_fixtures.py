#!/usr/bin/env python3
"""Builds a skill's eval fixtures by replaying its evals/fixtures.json against the dedicated Compositor instance.

    python3 scripts/skills-eval/replay_fixtures.py <skill> [<skill> ...] [--endpoint URL] [--workspace DIR]
    python3 scripts/skills-eval/replay_fixtures.py --all
    python3 scripts/skills-eval/replay_fixtures.py --recipe path/to/fixtures.json

For each skill, into <workspace>/fixtures/<skill>/ (emptied first):
  1. writes the recipe's "images" (fixture_images.py) and "profiles" (synthetic Look profiles, below);
  2. closes every open document without saving, then runs each fixture's calls in order, each one tools/call
     that must succeed. A relative "path" argument is rebased into the fixture folder, so nothing is written to
     the instance's Agent folder. A fixture that fails is reported with the call that failed and the error, the
     app is reset, and the next fixture still runs;
  3. checks that each fixture's declared "outputs" exist, and writes <workspace>/fixtures/<skill>.manifest.json:
     the sha256 of every file left in the folder (the "source unchanged" baselines) and each fixture's outcome.
Exit status: 0 when every fixture of every skill replayed, 1 otherwise.

A "profiles" entry, {"path", "from", "name", "group"}, copies the committed synthetic profile
CompositorTests/Fixtures/Profiles/profile-<from>.xmp (tables made from formulas by scripts/profiles/make_fixtures.py,
never from Adobe's files) under a new name, group and UUID. A fixture then imports it with import_profile.
"""

import argparse
import datetime
import hashlib
import json
import re
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.dont_write_bytecode = True  # no __pycache__ for evalkit in the checkout

import fixture_images  # noqa: E402
from evalkit import (REPO, SKILLS, Endpoint, ToolError, default_workspace, endpoint_url, instance_token,  # noqa: E402
                     reset_app, tree_sha256, write_json)

PROFILE_FIXTURES = REPO / "CompositorTests" / "Fixtures" / "Profiles"


def rebase(value, root):
    """A copy of a call's arguments with every relative "path" string made absolute under root."""
    if isinstance(value, dict):
        rebased = {}
        for key, item in value.items():
            if key == "path" and isinstance(item, str) and item and not item.startswith(("/", "~")):
                rebased[key] = str(Path(root) / item)
            else:
                rebased[key] = rebase(item, root)
        return rebased
    if isinstance(value, list):
        return [rebase(item, root) for item in value]
    return value


def write_profile(spec, root):
    """Writes a synthetic Look profile at root/spec["path"] from a committed profile fixture; returns the path."""
    source = PROFILE_FIXTURES / f"profile-{spec['from']}.xmp"
    if not re.fullmatch(r"[a-z0-9-]+", str(spec["from"])) or not source.is_file():
        raise ValueError(f"no synthetic profile fixture named {spec['from']!r} in {PROFILE_FIXTURES}")
    text = source.read_text(encoding="utf-8")
    uuid = hashlib.md5(f"{spec['group']}/{spec['name']}".encode()).hexdigest().upper()
    text, count = re.subn(r'crs:UUID="[0-9A-Fa-f]{32}"', f'crs:UUID="{uuid}"', text)
    for key in ("Name", "Group"):
        pattern = rf'(<crs:{key}>\s*<rdf:Alt>\s*<rdf:li xml:lang="x-default">)[^<]*(</rdf:li>)'
        text, found = re.subn(pattern, lambda match: match.group(1) + spec[key.lower()] + match.group(2), text)
        count += found
    if count != 3:
        raise ValueError(f"{source.name} doesn't have the UUID, Name and Group this expects")
    path = Path(root) / spec["path"]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def replay_fixture(fixture, endpoint, root):
    """Runs one fixture's calls; returns (ok, error)."""
    reset_app(endpoint)
    for number, call in enumerate(fixture["calls"], start=1):
        try:
            endpoint.call(call["tool"], rebase(call.get("arguments", {}), root))
        except ToolError as error:
            return False, f"call {number} {call['tool']} failed: {error.code}: {error.message}"
    missing = [output for output in fixture.get("outputs", []) if not (Path(root) / output).exists()]
    if missing:
        return False, f"declared outputs missing after the calls: {', '.join(missing)}"
    return True, None


def replay_recipe(recipe, endpoint, workspace):
    """Replays one recipe into <workspace>/fixtures/<skill>/ and returns (and writes) its manifest."""
    skill = recipe["skill_name"]
    root = Path(workspace) / "fixtures" / skill
    if root.exists():
        shutil.rmtree(root)
    root.mkdir(parents=True)
    for spec in recipe.get("images", []):
        fixture_images.write_image(spec, root)
    for spec in recipe.get("profiles", []):
        write_profile(spec, root)
    outcomes = []
    for fixture in recipe.get("fixtures", []):
        try:
            ok, error = replay_fixture(fixture, endpoint, root)
        except ToolError as failure:  # the reset itself failed
            ok, error = False, f"could not reset the app: {failure}"
        if not ok:
            try:
                reset_app(endpoint)
            except ToolError:
                pass
        outcomes.append({"id": fixture["id"], "ok": ok, "error": error, "outputs": fixture.get("outputs", [])})
    manifest = {
        "skill": skill,
        "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "endpoint": endpoint.url,
        "fixture_dir": str(root),
        "ok": all(outcome["ok"] for outcome in outcomes),
        "images": [spec["path"] for spec in recipe.get("images", [])],
        "profiles": [spec["path"] for spec in recipe.get("profiles", [])],
        "fixtures": outcomes,
        "files": tree_sha256(root),
    }
    write_json(Path(workspace) / "fixtures" / f"{skill}.manifest.json", manifest)
    return manifest


def main(argv=None):
    parser = argparse.ArgumentParser(description="Replay skills' evals/fixtures.json against the eval instance.")
    parser.add_argument("skills", nargs="*", help="skill names (folders under skills/)")
    parser.add_argument("--all", action="store_true", help="every skill that has an evals/fixtures.json")
    parser.add_argument("--recipe", action="append", default=[], help="a fixtures.json file to replay")
    parser.add_argument("--endpoint", help="MCP URL; default: the instance recorded by instance.sh")
    parser.add_argument("--workspace", type=Path, default=None, help="default: skills-workspace/ in this checkout")
    args = parser.parse_args(argv)

    workspace = args.workspace or default_workspace()
    recipes = [Path(path) for path in args.recipe]
    names = [path.parents[1].name for path in sorted(SKILLS.glob("*/evals/fixtures.json"))] if args.all else []
    recipes += [SKILLS / name / "evals" / "fixtures.json" for name in args.skills + names]
    if not recipes:
        parser.error("name a skill, --all or --recipe")
    endpoint = Endpoint(endpoint_url(workspace, args.endpoint), token=instance_token(workspace))
    all_ok = True
    for path in recipes:
        manifest = replay_recipe(json.loads(path.read_text(encoding="utf-8")), endpoint, workspace)
        for outcome in manifest["fixtures"]:
            mark = "ok  " if outcome["ok"] else "FAIL"
            print(f"{mark} {manifest['skill']}/{outcome['id']}" + (f": {outcome['error']}" if outcome["error"] else ""))
        print(f"     {manifest['skill']}: {len(manifest['files'])} files in {manifest['fixture_dir']}")
        all_ok &= manifest["ok"]
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
