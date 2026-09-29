#!/usr/bin/env python3
"""Builds what skill-creator's review viewer shows of an iteration, beside it, leaving the runs untouched.

    python3 scripts/skills-eval/view_outputs.py <workspace>/<skill>/iteration-N <workspace>/<skill>/view-iteration-N
    python3 <skill-creator>/eval-viewer/generate_review.py <view folder> --skill-name <skill> \\
        --benchmark <iteration>/benchmark.json --static <html> [--previous-workspace <previous view folder>]

The viewer lists only the files at the top of each run's outputs/, but an eval's outputs keep the Agent folder's
own layout (out/, exports/, templates/). The view mirrors the iteration's eval and run folders (eval_metadata.json,
grading.json, timing.json, transcript.md) and gives each run an outputs/ holding:
- a copy of every image the agent made (outputs/metrics.json's files_created: PNG, JPEG, GIF, WebP), named by its
  path with "__" for "/" (out/card.png is out__card.png); one wider or taller than 1024 px is scaled down to 1024 with
  sips (files.txt says so);
- final-answer.md, the session's final answer from transcript.md;
- files.txt, every file the agent made or changed, with its size.
The view folder is replaced each time. Before deleting or reading anything, the script refuses a view inside the
iteration (the viewer would find it twice), one containing it (replacing it would delete the runs), and a non-empty
folder it didn't build (no MARKER file), so a mistyped view path can't delete anything.
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

IMAGES = {".png", ".jpg", ".jpeg", ".gif", ".webp"}
COPIED = ("eval_metadata.json", "grading.json", "timing.json", "transcript.md")
PREVIEW = 1024
MARKER = ".view_outputs"


def final_answer(transcript):
    text = transcript.read_text(encoding="utf-8") if transcript.is_file() else ""
    match = re.search(r"(?ms)^## Final Answer\n(.*)\Z", text)
    return (match.group(1).strip() if match else "(no final answer in the transcript)") + "\n"


def image_size(path):
    result = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)], capture_output=True,
                            text=True, timeout=60)
    fields = dict(re.findall(r"^\s+(\w+): (\d+)$", result.stdout, re.M))
    return (int(fields["pixelWidth"]), int(fields["pixelHeight"])) if "pixelWidth" in fields else None


def view_run(run, view):
    outputs = view / "outputs"
    outputs.mkdir(parents=True)
    for name in COPIED:
        if (run / name).is_file():
            shutil.copy2(run / name, view / name)
    metrics_path = run / "outputs" / "metrics.json"
    metrics = json.loads(metrics_path.read_text(encoding="utf-8")) if metrics_path.is_file() else {}
    made = list(metrics.get("files_created", [])) + list(metrics.get("files_changed", []))
    listing = []
    for relative in made:
        source = run / "outputs" / relative
        if not source.is_file():
            listing.append(f"{relative}: gone")
            continue
        note = f"{relative}: {source.stat().st_size} bytes"
        if source.suffix.lower() in IMAGES:
            target = outputs / relative.replace("/", "__")
            size = image_size(source)
            if size and max(size) > PREVIEW:
                subprocess.run(["sips", "-Z", str(PREVIEW), str(source), "--out", str(target)], capture_output=True,
                               timeout=120)
                note += f", {size[0]} x {size[1]} (shown scaled to {PREVIEW})"
            else:
                shutil.copy2(source, target)
                note += f", {size[0]} x {size[1]}" if size else ""
        listing.append(note)
    (outputs / "final-answer.md").write_text(final_answer(run / "transcript.md"), encoding="utf-8")
    (outputs / "files.txt").write_text("\n".join(listing or ["(the agent made no files)"]) + "\n", encoding="utf-8")


def refusal(iteration, view):
    """Why the view may not be (re)built there, or None. Checked before anything is deleted."""
    if not iteration.is_dir():
        return f"the iteration {iteration} isn't a folder"
    if view == iteration or iteration in view.parents:
        return "the view can't lie inside the iteration"
    if view in iteration.parents:
        return "the view can't contain the iteration (replacing it would delete the runs)"
    if view.exists() and not view.is_dir():
        return f"{view} isn't a folder"
    if view.is_dir() and not (view / MARKER).is_file() and any(view.iterdir()):
        return f"{view} isn't a view this script built ({MARKER} is missing); pick a new or empty folder"
    return None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("iteration", type=Path)
    parser.add_argument("view", type=Path)
    args = parser.parse_args(argv)
    iteration, view = args.iteration.resolve(), args.view.resolve()
    reason = refusal(iteration, view)
    if reason:
        print(f"view_outputs: {reason}", file=sys.stderr)
        return 2
    if view.exists():
        shutil.rmtree(view)
    view.mkdir(parents=True)
    (view / MARKER).write_text(f"built by view_outputs.py from {iteration}\n", encoding="utf-8")
    runs = sorted(folder.parent for folder in iteration.rglob("outputs") if folder.is_dir()
                  and (folder.parent / "eval_metadata.json").is_file())
    for run in runs:
        target = view / run.relative_to(iteration)
        view_run(run, target)
        for parent in run.relative_to(iteration).parents:
            metadata = iteration / parent / "eval_metadata.json"
            if parent != Path(".") and metadata.is_file() and not (view / parent / "eval_metadata.json").exists():
                shutil.copy2(metadata, view / parent / "eval_metadata.json")
    print(f"view of {len(runs)} runs: {view}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
