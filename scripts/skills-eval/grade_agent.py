#!/usr/bin/env python3
"""Has a headless grader agent grade the expectations grade_scripted.py left for it, and merges the verdicts.

    python3 scripts/skills-eval/grade_agent.py <run folder or any folder above runs> [...]
        [--model MODEL] [--jobs N] [--instructions PATH] [--claude claude] [--timeout SECONDS]

Run grade_scripted.py first: this grades each run's "needs_grader" expectations and nothing else. For each such run
it starts `claude -p` from the run folder with skill-creator's agents/grader.md (--instructions, else found through
SKILL_CREATOR or under ~/.claude/skills) followed by the run's task, its expected output, the expectations to grade
and where the evidence is: transcript.md, outputs/ and final-state/. The session may only read the run folder and
run ls, sips, shasum, file and the repository's psd-verify.py and psd-diff.py (--allowedTools; never
bypassPermissions), talks to no MCP server (so never to Compositor), and answers with a JSON block, which is merged
into grading.json:
- a verdict counts only for an expectation still under needs_grader, with its text copied exactly (the scripted
  verdicts stay the script's; a verdict for any other text is ignored);
- expectations and needs_grader follow the eval's order, and summary is recomputed;
- claims, user_notes_summary and eval_feedback are stored as the agent gave them, and grader_agent records the
  model, how many it graded, tokens, time and cost.
grading.json keeps no "timing" (skill-creator's aggregate_benchmark would count output characters as tokens).
Runs are graded --jobs at a time (default 4). Exit status: 0 done, 1 when any run could not be graded (its
grading.json is left as it was), 2 bad arguments.
"""

import argparse
import concurrent.futures
import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.dont_write_bytecode = True  # no __pycache__ for the harness modules in the checkout

from evalkit import REPO, write_json  # noqa: E402
from grade_scripted import run_dirs, summarize  # noqa: E402
from run_eval import default_model, session_env, total_tokens  # noqa: E402

AGENT_FIELDS = ("claims", "user_notes_summary", "eval_feedback")
INSPECTION = ("ls", "sips", "shasum", "file")
PSD_VERIFY = REPO / "scripts" / "psd-verify.py"
PSD_DIFF = REPO / "scripts" / "psd-diff.py"

HEADLESS = """\
---

You are grading one run of a skill evaluation, headless, as the Grader Agent above, with two differences:

- You can read files (images too) and run ls, sips, shasum, file, `uv run --with psd-tools python3 {psd_verify}
  <file.psd> [--raw]` (a summary of the PSD's layers; --raw adds names and text) and `uv run --with pillow python3
  {psd_diff} <a.png> <b.png>` (how many pixels differ), but you cannot write files. Instead of saving
  grading.json, end your answer with one ```json block holding {{"expectations": [{{"text", "passed", "evidence"}}],
  "claims": [...], "user_notes_summary": {{...}}, "eval_feedback": {{"suggestions": [...], "overall": "..."}}}}.
- Grade exactly the expectations under "Expectations to grade", one entry each, with "text" copied exactly. The others
  were checked by a script; they are listed for context only.

The burden of proof is on the expectation: pass it only on evidence you can quote from the transcript, the outputs or
the final state.

## The task the agent was given

{prompt}

## What a good run does (the eval author's description)

{expected_output}

## Where the evidence is

- Transcript (the prompt, every tool call with its result, and the final answer): {transcript}
- Outputs folder (the Compositor Agent folder after the session; the agent's relative paths start here): {outputs}
- Final state: {final_state}
{note}

## Already checked by a script (context only)

{scripted}

## Expectations to grade

{to_grade}
"""


def find_instructions():
    """skill-creator's agents/grader.md: under SKILL_CREATOR, else the first skill-creator under ~/.claude/skills."""
    creator = os.environ.get("SKILL_CREATOR")
    if creator:
        return Path(creator) / "agents" / "grader.md"
    for path in sorted((Path.home() / ".claude" / "skills").glob("**/skill-creator/agents/grader.md")):
        return path
    return None


def allowed_tools(run):
    folder = os.path.realpath(run)
    return [f"Read(/{folder}/**)", *(f"Bash({command}:*)" for command in INSPECTION),
            f"Bash(uv run --with psd-tools python3 {PSD_VERIFY}:*)",
            f"Bash(uv run --with pillow python3 {PSD_DIFF}:*)"]


def bullets(texts):
    return "\n".join(f"- {text}" for text in texts) or "(none)"


def build_prompt(instructions, run, metadata, grading):
    open_texts = grading.get("needs_grader") or []
    inputs = grading.get("grader_inputs") or {}
    final_state = run / "final-state"
    return instructions.rstrip() + "\n\n" + HEADLESS.format(
        psd_verify=PSD_VERIFY, psd_diff=PSD_DIFF, prompt=metadata.get("prompt", "").strip(),
        expected_output=metadata.get("expected_output", "").strip() or "(not given)",
        transcript=run / "transcript.md", outputs=run / "outputs",
        final_state=final_state if final_state.is_dir() else "none (the session left nothing open)",
        note=f"- Note: {inputs['note']}" if inputs.get("note") else "",
        scripted=bullets(entry["text"] for entry in grading.get("expectations", [])),
        to_grade=bullets(open_texts))


def parse_answer(text):
    """The last ```json block (or, failing that, the last JSON object) holding an "expectations" list."""
    for block in reversed(re.findall(r"```(?:json)?[ \t]*\n(.*?)```", text, re.S)):
        try:
            value = json.loads(block)
        except ValueError:
            continue
        if isinstance(value, dict) and isinstance(value.get("expectations"), list):
            return value
    decoder = json.JSONDecoder()
    for start in reversed([match.start() for match in re.finditer(r"\{", text)]):
        try:
            value, _ = decoder.raw_decode(text[start:])
        except ValueError:
            continue
        if isinstance(value, dict) and isinstance(value.get("expectations"), list):
            return value
    return None


def merge(grading, metadata, answer, agent):
    """grading.json with the agent's verdicts for its open expectations; returns (grading, how many it graded)."""
    texts = metadata.get("assertions", [])
    still_open = set(grading.get("needs_grader") or [])
    by_text = {entry["text"]: entry for entry in grading.get("expectations", [])}
    graded = 0
    for verdict in answer.get("expectations", []):
        if (isinstance(verdict, dict) and verdict.get("text") in still_open and verdict["text"] not in by_text
                and isinstance(verdict.get("passed"), bool)):
            by_text[verdict["text"]] = {"text": verdict["text"], "passed": verdict["passed"],
                                        "evidence": str(verdict.get("evidence", ""))}
            graded += 1
    merged = dict(grading)
    merged["expectations"] = [by_text[text] for text in texts if text in by_text]
    merged["needs_grader"] = [text for text in texts if text not in by_text]
    merged["summary"] = summarize(merged["expectations"])
    for key in AGENT_FIELDS:
        if key in answer:
            merged[key] = answer[key]
    merged["grader_agent"] = {**agent, "graded": graded}
    merged.pop("timing", None)
    return merged, graded


def grade(run, args, instructions):
    """Grades one run; returns (ok, message)."""
    grading_path = run / "grading.json"
    if not grading_path.is_file():
        return False, f"{run}: no grading.json; run grade_scripted.py on it first"
    grading = json.loads(grading_path.read_text(encoding="utf-8"))
    if not grading.get("needs_grader"):
        return True, f"{run}: nothing to grade"
    metadata = json.loads((run / "eval_metadata.json").read_text(encoding="utf-8"))
    command = [args.claude, "-p", "--output-format", "json", "--mcp-config", json.dumps({"mcpServers": {}}),
               "--strict-mcp-config", "--setting-sources", "project,local", "--no-session-persistence"]
    if args.model:
        command += ["--model", args.model]
    command += ["--allowedTools", *allowed_tools(run)]  # last: the option takes every argument after it
    try:
        result = subprocess.run(command, input=build_prompt(instructions, run, metadata, grading), cwd=run,
                                env=session_env(), capture_output=True, text=True, timeout=args.timeout)
    except subprocess.TimeoutExpired:
        return False, f"{run}: the grader didn't answer within {args.timeout:g} s"
    try:
        event = json.loads(result.stdout)
    except ValueError:
        event = {}
    answer = parse_answer(event.get("result") or "") if isinstance(event, dict) else None
    if result.returncode != 0 or answer is None:
        detail = (result.stderr.strip() or str(event.get("result", ""))[-300:] or "no answer")[-300:]
        return False, f"{run}: the grader gave no verdicts (exit {result.returncode}): {detail}"
    agent = {"model": args.model, "tokens": total_tokens(event), "duration_ms": event.get("duration_ms"),
             "cost_usd": event.get("total_cost_usd")}
    merged, graded = merge(grading, metadata, answer, agent)
    write_json(grading_path, merged)
    summary = merged["summary"]
    return True, (f"{run}: {graded} graded, {len(merged['needs_grader'])} still open; "
                  f"{summary['passed']}/{summary['total']} passed")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("paths", nargs="+", type=Path, help="run folders, or folders to search for runs")
    parser.add_argument("--model", default=None, help="default: the model in ~/.claude/settings.json")
    parser.add_argument("--jobs", type=int, default=4, help="runs graded at once (default 4)")
    parser.add_argument("--instructions", type=Path, default=None, help="default: skill-creator's agents/grader.md")
    parser.add_argument("--claude", default="claude", help="the Claude Code executable")
    parser.add_argument("--timeout", type=float, default=900, help="seconds per run (default 900)")
    args = parser.parse_args(argv)
    if args.model is None:
        args.model = default_model()
    path = args.instructions or find_instructions()
    if path is None or not Path(path).is_file():
        print(f"grade_agent: no grader instructions{f' at {path}' if path else ''}; pass --instructions or set "
              "SKILL_CREATOR", file=sys.stderr)
        return 2
    instructions = Path(path).read_text(encoding="utf-8")
    runs = []
    for folder in args.paths:
        complete, _ = run_dirs(folder)
        runs += [Path(run).resolve() for run in complete]
    if not runs:
        print("grade_agent: no runs found", file=sys.stderr)
        return 1
    failed = False
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        for ok, message in pool.map(lambda run: grade(run, args, instructions), runs):
            print(message, file=sys.stdout if ok else sys.stderr, flush=True)
            failed |= not ok
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
