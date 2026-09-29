#!/usr/bin/env python3
"""Runs one eval of one skill, with or without the skill, through headless Claude Code against the eval instance.

    python3 scripts/skills-eval/run_eval.py --skill <skill> --eval <id> --config with_skill|without_skill
        [--iteration N] [--run K] [--timeout SECONDS] [--model MODEL] [--endpoint URL] [--workspace DIR] [--force]

Needs a running instance (instance.sh start) and, for a skill with evals/fixtures.json, its replayed fixtures
(replay_fixtures.py). Writes <workspace>/<skill>/iteration-N/eval-<id>/<config>/run-K/ in the skill-creator layout:
  outputs/                  the instance's Agent folder after the session (fixtures plus whatever the agent made),
                            with outputs/metrics.json (tool calls, errors, files created)
  transcript.jsonl          the raw stream-json session; transcript.md, the readable version for graders
  timing.json               total_tokens, duration_ms, total_duration_seconds, executor times, cost, model,
                            skill_loaded (listed) and skill_invoked (the Skill tool called with it, or its SKILL.md read)
  eval_metadata.json        prompt, assertions and where the fixtures came from (also one level up, per eval)
  agent-folder-before.json  sha256 of every file the session started with (the "unchanged" baselines)
  final-state/              what the app had open when the session ended, captured before the reset closes it:
                            list_documents.json and per tab tab-<index>.json (get_document detail full, get_history,
                            get_layer_bounds and get_text_metrics of each text layer), for the grader agent
  project/                  the session's working folder (settings, the skill copy for with_skill, scratch files)

Each run: the app's documents are all closed without saving; the Agent folder (which must lie inside the sandbox
folder the instance runs in, never a real one) is emptied and given the skill's fixtures; a fresh project in the
sandbox gets .claude/settings.json with guard deny rules (below) and, for with_skill only, the skill (and, for a
workflow skill, the compositor entry skill it builds on, as every install ships them together) as
scripts/package-skills.sh --stage writes it (no evals/, the repository's verification scripts bundled); then, from
that project:
  claude -p <prompt> --mcp-config <sandbox>/mcp-configs/<random>.json --strict-mcp-config
         --output-format stream-json --verbose --setting-sources project,local --no-session-persistence
         --model <model> --allowedTools <allowlist>
where the allowlist (allowed_tools; also written to <run>/allowed-tools.json) is Compositor's tools, Read/Edit/Write
inside the sandbox, sips, shasum, ls, file, mkdir and cp, the repository's psd-verify.py and psd-diff.py and, with the
skill, its own scripts (never photoshop-verify.sh); anything else is denied in -p mode, and never bypassPermissions;
with CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 and without the calling Claude Code session's CLAUDECODE, CLAUDE_EFFORT and
CLAUDE_CODE_* variables. --setting-sources project,local leaves out ~/.claude (user skills, plugins, hooks,
CLAUDE.md and the user's model setting, so the model is passed explicitly: the user's configured one by default).
When the instance requires its access token (instance.sh records its token file), run_eval's own calls send it, and
so does the session: the MCP config carries it as an Authorization header, which is why that file is written
owner-only (0600) in the sandbox rather than in the run folder, and why the token is on no command line.
A baseline that still lists a Compositor skill, or a with_skill run whose skill didn't load, fails as contaminated.
claude runs in a process group of its own, which is stopped (SIGTERM, then SIGKILL) when the session ends, at the
timeout, and when run_eval is interrupted (Ctrl-C, SIGTERM, SIGHUP); so is any process still working in the run's
project folder, which is how a background command the Bash tool left behind is found (that tool starts every
command in a session of its own, out of claude's group). An interrupted run's folder is left without timing.json,
so grading skips it.
Exit status: 0 done, 1 refused or contaminated, 2 bad arguments, 3 the session hit the timeout (results kept); when
interrupted, run_eval ends by the same signal once the session is stopped.
"""

import argparse
import contextlib
import datetime
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.dont_write_bytecode = True  # no __pycache__ for evalkit in the checkout

from evalkit import (REPO, SKILLS, Endpoint, ToolError, default_workspace, endpoint_url, instance_token,  # noqa: E402
                     is_inside, read_events, reset_app, sandbox, session_steps, tool_calls, tree_sha256, write_json)

CONFIGS = ("with_skill", "without_skill")

# The same for both configurations, as a second line behind the allowlist below: keep the session out of macOS's
# protected folders, the user's agent and client configuration, anything that would drive or restart apps, and the
# tools that reach past the session (the network, the owner's devices, other sessions, schedules outliving the run).
GUARD_DENY = [
    *(f"{tool}({path})" for tool in ("Read", "Edit", "Write") for path in (
        "~/Documents/**", "~/Desktop/**", "~/Downloads/**", "~/Library/Mobile Documents/**",
        "~/Library/CloudStorage/**", "//Volumes/**")),
    *(f"{tool}({path})" for tool in ("Edit", "Write") for path in (
        "~/.claude.json", "~/.claude/**", "~/.codex/**", "~/.agents/**", "~/Library/Application Support/Claude/**",
        "~/Library/Application Support/Compositor/**", "~/Library/Preferences/**")),
    "Read(~/.ssh/**)", "Read(~/.config/rhm/**)",
    "Bash(claude mcp:*)", "Bash(codex mcp:*)", "Bash(defaults write:*)", "Bash(defaults delete:*)", "Bash(open:*)",
    "Bash(osascript:*)", "Bash(kill:*)", "Bash(killall:*)", "Bash(pkill:*)", "Bash(launchctl:*)",
    "WebFetch", "WebSearch", "PushNotification", "SendMessage", "RemoteTrigger", "CronCreate", "ScheduleWakeup",
]

# What a session may use; in -p mode Claude Code denies every other permission-checked call (checked with probes on
# 2.1.280: a Write, cp and mkdir outside the sandbox and a Read of /etc/hosts were denied, the same calls inside it
# ran). Never --permission-mode bypassPermissions. The sandbox holds the run's project and the instance's Agent
# folder (which becomes the run's outputs/ afterwards); Bash's own path checks keep cp and mkdir inside it too.
SESSION_COMMANDS = ("sips", "shasum", "ls", "file", "mkdir", "cp")
# Each with the script's path as written and in double quotes: rules match command text, and agents quote paths.
REPO_SCRIPT_RULES = tuple(
    f"Bash({runner}{path}:*)"
    for runner, script in (("uv run --with psd-tools python3 ", "psd-verify.py"), ("python3 ", "psd-diff.py"),
                           ("uv run --with pillow python3 ", "psd-diff.py"))
    for path in (f"{REPO}/scripts/{script}", f'"{REPO}/scripts/{script}"'))
# Bundled with the template skills, but it drives the owner's live Photoshop: only the operator runs it, one check
# at a time machine-wide, never an eval session.
NEVER_RUN = {"photoshop-verify.sh", "photoshop-verify.jsx"}
RUNNERS = {".py": ("", "python3 ", "uv run --with psd-tools python3 ", "uv run --with pillow python3 "),
           ".sh": ("", "bash ")}
PACKAGE_SKILLS = REPO / "scripts" / "package-skills.sh"
# The skill every workflow skill builds on ("Read the compositor skill first"); installs and packages always ship it,
# so a with_skill run of another skill gets it too.
ENTRY_SKILL = "compositor"

STRIPPED_ENV = ("CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT")


class Refusal(Exception):
    pass


def default_model():
    """The model the user's Claude Code settings choose, which --setting-sources project,local would drop."""
    try:
        return json.loads((Path.home() / ".claude" / "settings.json").read_text(encoding="utf-8")).get("model")
    except (OSError, ValueError, AttributeError):
        return None


def find_eval(skill_dir, eval_id):
    evals = json.loads((skill_dir / "evals" / "evals.json").read_text(encoding="utf-8"))["evals"]
    for case in evals:
        if case["id"] == eval_id:
            return case
    raise Refusal(f"{skill_dir.name} has no eval {eval_id} (it has {', '.join(str(c['id']) for c in evals)})")


def fixture_dir(workspace, skill_dir, case):
    """The replayed fixture folder the Agent folder starts from, or None for a skill without fixtures."""
    if not (skill_dir / "evals" / "fixtures.json").is_file():
        return None
    manifest_path = Path(workspace) / "fixtures" / f"{skill_dir.name}.manifest.json"
    if not manifest_path.is_file():
        raise Refusal(f"no replayed fixtures for {skill_dir.name}: run scripts/skills-eval/replay_fixtures.py "
                      f"{skill_dir.name} first")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    outcomes = {outcome["id"]: outcome for outcome in manifest["fixtures"]}
    for name in case.get("fixtures", []):
        if name in outcomes:
            if not outcomes[name]["ok"]:
                raise Refusal(f"eval {case['id']} needs fixture {name}, which failed to replay: {outcomes[name]['error']}")
        elif name not in manifest["files"]:
            raise Refusal(f"eval {case['id']} needs {name}, which the replay manifest {manifest_path} doesn't have")
    return Path(manifest["fixture_dir"])


def empty_folder(folder):
    folder.mkdir(parents=True, exist_ok=True)
    for child in folder.iterdir():
        if child.is_dir() and not child.is_symlink():
            shutil.rmtree(child)
        else:
            child.unlink()


def installed_skills(skill_dir, config):
    """The skill folders a run's project gets: none without the skill; the skill, and the entry skill it builds on
    when that is another one, with it."""
    if config != "with_skill":
        return []
    entry = skill_dir.parent / ENTRY_SKILL
    return [skill_dir] + ([entry] if entry != skill_dir and (entry / "SKILL.md").is_file() else [])


def prepare_project(sandbox_dir, skill_dir, config):
    projects = Path(sandbox_dir) / "projects"
    projects.mkdir(parents=True, exist_ok=True)
    project = Path(tempfile.mkdtemp(prefix="p-", dir=projects))
    write_json(project / ".claude" / "settings.json", {"permissions": {"deny": GUARD_DENY}})
    for folder in installed_skills(skill_dir, config):
        # Each skill as it is packaged: without evals/ (the expectations the run is graded on, which the agent must
        # not read) and with the repository scripts its references run, which a copy can't find in a checkout.
        staged = subprocess.run(["bash", str(PACKAGE_SKILLS), "--stage", str(folder),
                                 str(project / ".claude" / "skills" / folder.name)],
                                capture_output=True, text=True, timeout=120)
        if staged.returncode != 0:
            shutil.rmtree(project)
            raise Refusal(f"could not stage {folder.name}: {staged.stderr.strip()}")
    return project


def spellings(path):
    """A path as a rule must match it: its real path and, for /private/tmp and /private/var, the /tmp and /var form
    macOS (and Compositor's results) usually show."""
    real = os.path.realpath(path)
    forms = [real]
    if real.startswith(("/private/tmp/", "/private/var/")):
        forms.append(real[len("/private"):])
    return forms


def skill_script_rules(skill_copy):
    """Bash rules for running the skill's own scripts by their absolute paths in the project (as the skill's base
    directory shows them to the agent), directly or through python3, bash or uv; never photoshop-verify."""
    folder = skill_copy / "scripts"
    rules = []
    for script in sorted(folder.iterdir()) if folder.is_dir() else []:
        if script.is_file() and script.name not in NEVER_RUN:
            paths = dict.fromkeys([str(script), *spellings(script)])
            forms = [form for path in paths for form in (path, f'"{path}"')]  # as written, and quoted
            rules += [f"Bash({runner}{form}:*)" for form in forms for runner in RUNNERS.get(script.suffix, ())]
    return rules


def allowed_tools(sandbox_dir, skill_copies=(), compositor=True):
    """The session's allowlist: Compositor's tools (unless the eval runs without them), Read/Edit/Write inside the
    sandbox, a few inspection commands, the repository's PSD checks and, with the skills, their own scripts."""
    rules = ["mcp__compositor"] if compositor else []
    rules += [*(f"{tool}(/{folder}/**)" for tool in ("Read", "Edit", "Write") for folder in spellings(sandbox_dir)),
              *(f"Bash({command}:*)" for command in SESSION_COMMANDS), *REPO_SCRIPT_RULES]
    for copy in skill_copies:
        rules += skill_script_rules(copy)
    return rules


def write_mcp_config(sandbox_dir, url, token, with_tools=True):
    """The session's MCP config: the one server, with the access token as a header when there is one, or no server
    for an eval that runs without Compositor's tools. Written owner-only (mkstemp makes it 0600) under the sandbox,
    never in the run folder, so the token stays out of what a run keeps."""
    server = {"type": "http", "url": url}
    if token:
        server["headers"] = {"Authorization": f"Bearer {token}"}
    folder = Path(sandbox_dir) / "mcp-configs"
    folder.mkdir(parents=True, exist_ok=True)
    descriptor, path = tempfile.mkstemp(prefix="mcp-config-", suffix=".json", dir=folder)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump({"mcpServers": {"compositor": server} if with_tools else {}}, handle, indent=2)
        handle.write("\n")
    return Path(path)


def claude_command(claude, prompt, mcp_config, model, allowed):
    command = [claude, "-p", prompt, "--mcp-config", str(mcp_config), "--strict-mcp-config",
               "--output-format", "stream-json", "--verbose", "--setting-sources", "project,local",
               "--no-session-persistence"]
    if model:
        command += ["--model", model]
    return command + ["--allowedTools", *allowed]  # last: the option takes every argument after it


def session_env():
    env = {key: value for key, value in os.environ.items()
           if key not in STRIPPED_ENV and not key.startswith("CLAUDE_CODE_")}
    env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
    return env


STOP_SIGNALS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)


class Stopped(SystemExit):
    """Raised by the SIGTERM and SIGHUP handlers, so a stopped run_eval cleans up the way Ctrl-C does."""

    def __init__(self, signum):
        super().__init__(128 + signum)
        self.signum = signum


def raise_stopped(signum, _frame):
    raise Stopped(signum)


def group_exists(pgid):
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


@contextlib.contextmanager
def signals_held():
    """Holds Ctrl-C, SIGTERM and SIGHUP until the block ends, so a second one can't cut a cleanup short."""
    held = signal.pthread_sigmask(signal.SIG_BLOCK, STOP_SIGNALS)
    try:
        yield
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, held)


def stop_session(process, grace=10.0):
    """Ends claude's whole process group (claude runs in a session of its own): SIGTERM, then SIGKILL for whatever
    is left after `grace` seconds, and reaps claude."""
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            break  # nothing is left in the group
        deadline = time.monotonic() + grace
        while process.poll() is None or group_exists(process.pid):  # poll() reaps claude once it has ended
            if time.monotonic() > deadline:
                break
            time.sleep(0.05)
        else:
            break
    with contextlib.suppress(subprocess.TimeoutExpired):
        process.wait(timeout=grace)


def working_in(folder):
    """{pid: command} of this user's processes whose working folder lies inside `folder` (lsof), run_eval aside."""
    root = os.path.realpath(folder)
    try:
        listing = subprocess.run(["lsof", "-a", "-u", str(os.getuid()), "-d", "cwd", "-Fpn"], capture_output=True,
                                 text=True, timeout=60).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}
    found, pid = {}, None
    for line in listing.splitlines():
        if line.startswith("p"):
            pid = int(line[1:])
        elif line.startswith("n") and pid not in (None, os.getpid()) and (line[1:] == root
                                                                           or line[1:].startswith(root + "/")):
            found[pid] = None
    for pid in found:
        found[pid] = subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True,
                                    text=True).stdout.strip()
    return found


def stop_strays(folder, grace=10.0):
    """Stops what the session left running outside claude's process group: Claude Code's Bash tool starts every
    command in a session of its own, so a background command (`nohup … &`) outlives claude and its group. Such a
    command keeps the working folder it started in, which is the run's new project folder unless the agent changed
    folders first; this finds those processes, sends SIGTERM, then SIGKILL after `grace` seconds. Returns
    [{"pid", "command"}] of what it stopped."""
    strays = working_in(folder)
    for sig in (signal.SIGTERM, signal.SIGKILL):
        left = [pid for pid in strays if alive(pid)]
        for pid in left:
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.kill(pid, sig)
        deadline = time.monotonic() + grace
        while any(alive(pid) for pid in left) and time.monotonic() < deadline:
            time.sleep(0.05)
    return [{"pid": pid, "command": command} for pid, command in strays.items()]


def run_session(command, cwd, transcript, stderr, timeout):
    """Runs claude from `cwd`; returns (exit code, timed out, strays). When the session ends, at the timeout, and
    when run_eval itself is interrupted (Ctrl-C, SIGTERM, SIGHUP, which then go on to end run_eval), claude's process
    group is stopped and so is anything else still working in `cwd` (the strays, see stop_strays): nothing the
    session started goes on calling the shared instance or writing into its Agent folder while the next run resets
    and refills them."""
    with open(transcript, "wb") as out, open(stderr, "wb") as err:
        process = subprocess.Popen(command, cwd=cwd, env=session_env(), stdout=out, stderr=err,
                                   stdin=subprocess.DEVNULL, start_new_session=True)
        timed_out = False
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
        finally:
            with signals_held():
                stop_session(process)
                strays = stop_strays(cwd)
        return process.returncode, timed_out, strays


FINAL_STATE = "final-state"


def capture_final_state(endpoint, folder):
    """Writes what the app has open when the session ends into `folder`, before the reset closes it all:
    list_documents.json and, for each tab with a document, tab-<index>.json holding the tab, get_document (detail
    full: every layer with its settings, text style and content_bounds), get_history, and get_layer_bounds and
    get_text_metrics for each text layer, by id. A call that fails is recorded as {"error": ...} in place of its
    result; after a transport failure nothing more is asked. Returns the errors."""
    errors, unreachable = [], []

    def ask(tool, arguments=None):
        if unreachable:
            return {"error": f"{tool}: not asked, the endpoint stopped answering ({unreachable[0]})"}
        try:
            return endpoint.call(tool, arguments)
        except ToolError as error:
            errors.append(str(error))
            if error.code == "transport":
                unreachable.append(str(error))
            return {"error": str(error)}

    def text_layers(layers):
        for layer in layers or []:
            if isinstance(layer, dict):
                if layer.get("kind") == "text":
                    yield layer
                yield from text_layers(layer.get("children"))

    listing = ask("list_documents")
    write_json(folder / "list_documents.json", listing)
    for index, tab in enumerate(listing.get("tabs") or []):
        if not isinstance(tab, dict) or tab.get("document_id") is None:
            continue
        start = len(errors)
        selector = tab.get("tab_id", index)
        document = ask("get_document", {"document": selector, "detail": "full"})
        captured = {"tab": tab, "get_document": document, "get_history": ask("get_history", {"document": selector}),
                    "text_layers": []}
        for layer in text_layers((document.get("document") or {}).get("layers")):
            target = {"document": selector, "layer": layer.get("id")}
            captured["text_layers"].append({
                "id": layer.get("id"), "path": layer.get("path"), "name": layer.get("name"),
                "get_layer_bounds": ask("get_layer_bounds", target),
                "get_text_metrics": ask("get_text_metrics", target)})
        captured["errors"] = errors[start:]
        write_json(folder / f"tab-{tab.get('index', index)}.json", captured)
    return errors


def clip(text, limit=1500):
    text = text if isinstance(text, str) else json.dumps(text, ensure_ascii=False)
    return text if len(text) <= limit else text[:limit] + f"\n… ({len(text) - limit} more characters)"


def transcript_markdown(title, prompt, init, steps, result, exit_code, timed_out):
    servers = ", ".join(f"{server.get('name')} ({server.get('status')})" for server in init.get("mcp_servers") or [])
    lines = [f"# {title}", "", "## Eval Prompt", "", prompt.strip(), "", "## Session", "",
             f"- Model: {init.get('model', 'unknown')}",
             f"- Skills listed: {', '.join(init.get('skills') or []) or 'none'}",
             f"- MCP servers: {servers or 'none'}",
             f"- Exit code: {exit_code}{' (stopped at the timeout)' if timed_out else ''}", "", "## Steps", ""]
    for number, step in enumerate(steps, start=1):
        if step["kind"] == "text":
            lines += [f"### {number}. Assistant", "", step["text"].strip(), ""]
            continue
        state = {True: "ok", False: "error", None: "no result"}[step["ok"]]
        lines += [f"### {number}. Tool: {step['name']}", "", "```json",
                  clip(json.dumps(step["input"], indent=1, ensure_ascii=False), 3000), "```", "",
                  f"Result ({state}):", "", "```", clip(step["result"]), "```", ""]
    lines += ["## Final Answer", "", (result.get("result") or "(none)").strip(), ""]
    return "\n".join(lines)


def total_tokens(result):
    usage = result.get("modelUsage") or {}
    if usage:
        return sum(int(model.get(key) or 0) for model in usage.values()
                   for key in ("inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens"))
    usage = result.get("usage") or {}
    return sum(int(usage.get(key) or 0) for key in ("input_tokens", "output_tokens", "cache_read_input_tokens",
                                                    "cache_creation_input_tokens"))


def metrics(steps, before, outputs, transcript_md):
    """skill-creator's executor metrics. A run_batch counts as one call (the agent made one); the calls its steps
    made are counted apart, as batched_calls."""
    calls = [step for step in steps if step["kind"] == "tool"]
    counts = {}
    for call in calls:
        counts[call["name"]] = counts.get(call["name"], 0) + 1
    after = tree_sha256(outputs)
    created = sorted(path for path in after if path not in before and path != "metrics.json")
    return {
        "tool_calls": counts,
        "total_tool_calls": len(calls),
        "batched_calls": sum(1 for call in tool_calls(steps) if call["via"] == "run_batch"),
        "total_steps": sum(1 for step in steps if step["kind"] == "text"),
        "files_created": created,
        "files_changed": sorted(path for path in after if path in before and after[path] != before[path]),
        "errors_encountered": sum(1 for call in calls if call["ok"] is False),
        "output_chars": sum((outputs / path).stat().st_size for path in created),
        "transcript_chars": len(transcript_md),
    }


def skills_invoked(steps):
    """The skills the session called the Skill tool with, in order, without plugin prefixes."""
    names = [str(step["input"].get("skill", "")).split(":")[-1] for step in steps
             if step["kind"] == "tool" and step["name"] == "Skill"]
    return list(dict.fromkeys(names))


def skill_invoked(steps, skill):
    """Whether the session used the skill: called the Skill tool with it, or read its SKILL.md. A skill that is only
    listed changes nothing; a with_skill run that never invokes it is a baseline in all but name."""
    for step in steps:
        if step["kind"] != "tool":
            continue
        if step["name"] == "Skill" and str(step["input"].get("skill", "")).split(":")[-1] == skill:
            return True
        if step["name"] == "Read" and str(step["input"].get("file_path", "")).endswith(f"/skills/{skill}/SKILL.md"):
            return True
    return False


def contamination(skills, installed):
    """Compositor skills the session could see that the run didn't install (none for a baseline)."""
    return sorted(name for name in skills if "compositor" in name.lower() and name not in set(installed))


def utc(timestamp):
    return datetime.datetime.fromtimestamp(timestamp, datetime.timezone.utc).isoformat(timespec="seconds")


def run(args):
    workspace = args.workspace or default_workspace()
    skill_dir = (args.skills_root or SKILLS) / args.skill
    if not (skill_dir / "SKILL.md").is_file():
        raise Refusal(f"no skill at {skill_dir}")
    case = find_eval(skill_dir, args.eval)
    fixtures = fixture_dir(workspace, skill_dir, case)
    eval_dir = Path(workspace) / args.skill / f"iteration-{args.iteration}" / f"eval-{args.eval}"
    run_dir = eval_dir / args.config / f"run-{args.run}"
    if run_dir.exists() and not args.force:
        raise Refusal(f"{run_dir} already exists; pass --force to replace it")

    url = endpoint_url(workspace, args.endpoint)
    token = instance_token(workspace)
    endpoint = Endpoint(url, token=token)
    sandbox_dir = sandbox(workspace)
    if is_inside(Path.home(), sandbox_dir):
        raise Refusal(f"the sandbox {sandbox_dir} holds your home folder; set SKILLS_EVAL_SANDBOX to a folder of its own")
    try:
        agent = Path(endpoint.call("get_app_info")["agent_folder"])
    except (ToolError, KeyError) as error:
        raise Refusal(f"could not ask {url} for its Agent folder: {error}")
    if not is_inside(agent, sandbox_dir):
        raise Refusal(f"the instance's Agent folder {agent} is outside the sandbox {sandbox_dir}: run_eval empties "
                      "that folder, so it only works with an instance started by instance.sh")
    try:
        reset_app(endpoint)
    except ToolError as error:
        raise Refusal(f"could not close the instance's documents before the run: {error}")
    project = prepare_project(sandbox_dir, skill_dir, args.config)  # refuses, leaving nothing, if staging fails

    if run_dir.exists():  # --force, and nothing refused the new run: only now is the old one replaced
        shutil.rmtree(run_dir)
    run_dir.mkdir(parents=True)
    words = " ".join(case["prompt"].split()[:8])
    metadata = {"eval_id": case["id"], "eval_name": f"{args.skill} #{case['id']}: {words}…", "skill_name": args.skill,
                "prompt": case["prompt"], "expected_output": case.get("expected_output", ""),
                "assertions": case.get("expectations", []), "fixtures": case.get("fixtures", [])}
    write_json(eval_dir / "eval_metadata.json", metadata)

    empty_folder(agent)
    if fixtures:
        shutil.copytree(fixtures, agent, dirs_exist_ok=True)
    before = tree_sha256(agent)
    write_json(run_dir / "agent-folder-before.json", before)
    # "mcp": false in an eval: a session whose client isn't connected yet (a setup question) gets no server at all.
    with_tools = case.get("mcp", True) is not False
    mcp_config = write_mcp_config(sandbox_dir, url, token, with_tools)
    write_json(run_dir / "eval_metadata.json", {
        **metadata, "configuration": args.config, "iteration": args.iteration, "run_number": args.run,
        "endpoint": url, "agent_folder": str(agent), "fixture_dir": str(fixtures) if fixtures else None,
        "project_dir": str(project), "model_requested": args.model,
        "skills_installed": [folder.name for folder in installed_skills(skill_dir, args.config)]})

    installed = [folder.name for folder in installed_skills(skill_dir, args.config)]
    allowed = allowed_tools(sandbox_dir, [project / ".claude" / "skills" / name for name in installed], with_tools)
    write_json(run_dir / "allowed-tools.json", allowed)
    command = claude_command(args.claude, case["prompt"], mcp_config, args.model, allowed)
    started = time.time()
    try:
        exit_code, timed_out, strays = run_session(command, project, run_dir / "transcript.jsonl",
                                                   run_dir / "claude-stderr.log", args.timeout)
    except BaseException as error:
        stopped = "the claude session was stopped; " if isinstance(error, (KeyboardInterrupt, Stopped)) else ""
        print(f"run_eval: {stopped}{run_dir} is incomplete (it has no timing.json, so grade_scripted.py skips "
              "it): run it again with --force", file=sys.stderr)
        raise
    ended = time.time()

    final_state_errors = capture_final_state(endpoint, run_dir / FINAL_STATE)
    reset_error = None
    try:
        reset_app(endpoint)
    except ToolError as error:
        reset_error = str(error)
    outputs = run_dir / "outputs"
    outputs.mkdir()
    for child in list(agent.iterdir()):
        shutil.move(str(child), str(outputs / child.name))
    shutil.move(str(project), str(run_dir / "project"))

    events = read_events(run_dir / "transcript.jsonl")
    init = next((e for e in events if e.get("type") == "system" and e.get("subtype") == "init"), {})
    result = next((e for e in reversed(events) if e.get("type") == "result"), {})
    steps = session_steps(events)
    title = f"{args.skill} eval {case['id']}, {args.config}, run {args.run}"
    markdown = transcript_markdown(title, case["prompt"], init, steps, result, exit_code, timed_out)
    (run_dir / "transcript.md").write_text(markdown, encoding="utf-8")
    write_json(outputs / "metrics.json", metrics(steps, before, outputs, markdown))

    skills = init.get("skills") or []
    installed = [folder.name for folder in installed_skills(skill_dir, args.config)]
    contaminated = contamination(skills, installed)
    timing = {
        "total_tokens": total_tokens(result),
        "duration_ms": result.get("duration_ms", round((ended - started) * 1000)),
        "total_duration_seconds": round(ended - started, 1),
        "executor_start": utc(started),
        "executor_end": utc(ended),
        "executor_duration_seconds": round(ended - started, 1),
        "executor_model": init.get("model"),
        "total_cost_usd": result.get("total_cost_usd"),
        "num_turns": result.get("num_turns"),
        "is_error": result.get("is_error", True),
        "exit_code": exit_code,
        "timed_out": timed_out,
        "skill_loaded": args.skill in skills,
        "skill_invoked": skill_invoked(steps, args.skill),
        "skills_invoked": skills_invoked(steps),
        "contamination": contaminated,
        "tool_calls": sum(1 for step in steps if step["kind"] == "tool"),  # as metrics.json's total_tool_calls
        "reset_error": reset_error,
        "final_state_errors": final_state_errors,
        "stray_processes": strays,
        # Calls the allowlist refused (Claude Code's result event), to tell a harness limit from a skill problem.
        "permission_denials": [{"tool": denial.get("tool_name"), "input": denial.get("tool_input")}
                               for denial in result.get("permission_denials") or [] if isinstance(denial, dict)],
    }
    write_json(run_dir / "timing.json", timing)

    print(f"{title}: {timing['total_tokens']} tokens, {timing['total_duration_seconds']} s, exit {exit_code}"
          f"{', TIMED OUT' if timed_out else ''} -> {run_dir}")
    if contaminated:
        print(f"contaminated: the session could see {', '.join(contaminated)}", file=sys.stderr)
        return 1
    if args.config == "with_skill" and init and args.skill not in skills:
        print(f"contaminated: the with_skill session did not list {args.skill}", file=sys.stderr)
        return 1
    if args.config == "with_skill" and not timing["skill_invoked"]:
        print(f"note: the with_skill session never invoked {args.skill} (it was listed but not used): look at the "
              "skill's description", file=sys.stderr)
    if strays:
        print("stopped what the session left running in the background: "
              + "; ".join(f"{stray['pid']} {stray['command']}" for stray in strays), file=sys.stderr)
    if final_state_errors:
        print(f"warning: the final state in {run_dir / FINAL_STATE} is incomplete: {'; '.join(final_state_errors)}",
              file=sys.stderr)
    if reset_error:
        print(f"warning: the app did not reset after the session: {reset_error}", file=sys.stderr)
    return 3 if timed_out else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--skill", required=True)
    parser.add_argument("--eval", type=int, required=True, help="the eval's id in the skill's evals/evals.json")
    parser.add_argument("--config", required=True, choices=CONFIGS)
    parser.add_argument("--iteration", type=int, default=1)
    parser.add_argument("--run", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=900, help="seconds (default 900)")
    parser.add_argument("--model", default=None, help="default: the model in ~/.claude/settings.json")
    parser.add_argument("--endpoint", help="MCP URL; default: the instance recorded by instance.sh")
    parser.add_argument("--workspace", type=Path, default=None, help="default: skills-workspace/ in this checkout")
    parser.add_argument("--skills-root", type=Path, default=None, help="default: skills/ in this checkout")
    parser.add_argument("--claude", default="claude", help="the Claude Code executable")
    parser.add_argument("--force", action="store_true", help="replace an existing run folder")
    args = parser.parse_args(argv)
    if args.model is None:
        args.model = default_model()
    for signum in (signal.SIGTERM, signal.SIGHUP):
        if signal.getsignal(signum) is signal.SIG_DFL:  # one ignored on purpose (nohup) stays ignored
            signal.signal(signum, raise_stopped)
    try:
        return run(args)
    except Refusal as refusal:
        print(f"run_eval: {refusal}", file=sys.stderr)
        return 1
    except (KeyboardInterrupt, Stopped) as stop:
        # End by the same signal, after the cleanup, so that a shell loop running evals stops too.
        signum = getattr(stop, "signum", signal.SIGINT)
        print(f"run_eval: stopped by {signal.Signals(signum).name}", file=sys.stderr, flush=True)
        signal.signal(signum, signal.SIG_DFL)
        os.kill(os.getpid(), signum)
        return 128 + signum


if __name__ == "__main__":
    sys.exit(main())
