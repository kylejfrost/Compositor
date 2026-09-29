# Skill evals against a live Compositor

These scripts run the evals in `skills/<skill>/evals/evals.json` the skill-creator way (with the skill and without
it, graded, then aggregated and reviewed), headless, against a dedicated Compositor instance built from this
checkout. Everything is standard-library Python 3.9+ and Bash on macOS; `psd-verify.py` checks use `uv` with
psd-tools.

| Script | What it does |
|---|---|
| `instance.sh start \| status \| stop` | Builds and launches the eval instance, checks it, quits it and cleans up |
| `replay_fixtures.py <skill>… \| --all` | Builds each skill's fixtures from `evals/fixtures.json` and records their sha256 |
| `fixture_images.py` | The PNG writer the recipes' `images` use (solid, linear/radial gradient, checker, disc) |
| `run_eval.py` | Runs one eval, `with_skill` or `without_skill`, through `claude -p` and files the results |
| `grade_scripted.py` | Grades the expectations a script can check; writes each run's `grading.json` |
| `grade_agent.py` | Has a headless grader agent (skill-creator's `agents/grader.md`) grade the rest, and merges its verdicts |
| `view_outputs.py` | Builds the flattened copy of an iteration that skill-creator's review viewer shows |
| `checks/<skill>.json` | Which expectations are scripted, and how |
| `evalkit.py` | Shared code: the JSON-RPC client, the app reset, hashing, transcript parsing |

## Running an iteration

From the checkout's root:

```sh
export SKILLS_EVAL_DD=/path/to/DerivedData        # where instance.sh builds; default skills-workspace/DerivedData
export SKILLS_EVAL_SANDBOX=/path/outside/checkout # default $TMPDIR/compositor-skills-eval

scripts/skills-eval/instance.sh start             # build, claim a port, launch, health-check
python3 scripts/skills-eval/replay_fixtures.py --all
python3 scripts/skills-eval/run_eval.py --skill compositor --eval 1 --config with_skill --iteration 1
python3 scripts/skills-eval/run_eval.py --skill compositor --eval 1 --config without_skill --iteration 1
python3 scripts/skills-eval/grade_scripted.py skills-workspace/compositor/iteration-1
python3 scripts/skills-eval/grade_agent.py skills-workspace/compositor/iteration-1   # the "needs_grader" rest
# then, from the skill-creator folder: python -m scripts.aggregate_benchmark <workspace>/iteration-1 --skill-name compositor
scripts/skills-eval/instance.sh stop               # quit the app, release the port, check the defaults
```

Run evals one at a time: every run empties and refills the instance's one Agent folder and closes all its
documents. `run_eval.py` does that only when the Agent folder `get_app_info` reports lies inside the sandbox, and
the sandbox doesn't hold your home folder, so it can never empty a real Agent folder. A run takes the eval's
fixtures from `skills-workspace/fixtures/<skill>/`, so replay again after changing a recipe. `run_eval.py` refuses
an eval whose fixture failed to replay, naming the fixture and the error.

## The dedicated instance

`instance.sh start` builds Debug with `CODE_SIGNING_ALLOWED=NO`, claims a port with
`portclaim acquire --service compositor-mcp-eval --project Compositor --lease persistent` (the pool never hands out
2667, and the script refuses it anyway) and launches the binary directly:

```sh
cd $SKILLS_EVAL_SANDBOX && CFFIXED_USER_HOME=$SKILLS_EVAL_SANDBOX/home \
  <DerivedData>/Build/Products/Debug/Compositor.app/Contents/MacOS/Compositor --mcp -mcp.port <port> \
  -ApplePersistenceIgnoreState YES -migration.sandboxPreferences.v1 YES -migration.sandboxAgentFolder.v1 YES \
  -SUEnableAutomaticChecks NO -SUAutomaticallyUpdate NO
```

It runs from the sandbox because a Debug build instrumented for coverage (as `xcodebuild test` leaves it) writes
`default.profraw` into its working folder, which would otherwise be the checkout.

- `CFFIXED_USER_HOME` moves Foundation's home: the Agent folder, `mcp/endpoint.json`, imported profiles and `~` in
  tool paths all live under the sandbox, so the owner's Agent folder, endpoint file and profile library are never
  touched, and a tool path under `~/Documents` names an empty sandbox folder instead of a protected one.
  Compositor still probes `/Volumes` for `get_app_info`'s folder access (a listing of `/Volumes` itself, which
  macOS doesn't guard).
- UserDefaults isn't moved: the app reads the owner's `com.wonderassembly.compositor` domain. The launch arguments
  go into the volatile argument domain, which is never saved: the port, the two migration markers (without them a
  first launch of this build runs the one-time sandbox migration and records it in the owner's domain) and
  Sparkle's automatic checks and updates (the owner's domain turns both on). `start` exports the domain and `stop`
  compares it key by key; `mcp.port` is checked before and after, and removed if it appeared.
- The instance is ready when its endpoint file names its pid and the claimed port (a taken port would make the app
  fall back to another one, which fails the start) and `check-compositor.sh --url` gets a ping answer.
- `stop` sends `kill -TERM` (the app quits at once, with no unsaved-changes dialog, and leaves its endpoint file,
  which `stop` then removes because it names a dead pid), releases the port and deletes `instance/state.json`.
  Never quit it with AppleScript: that targets the bundle id and would reach the owner's Compositor too.

## What `claude -p` loads, and the exact command line

By default a headless session loads everything the owner's interactive sessions do. A probe on this Mac
(Claude Code 2.1.280) listed in its `init` event: the 29 user skills in `~/.claude/skills` (including agent-browser,
design, brand, ui-styling), claude.ai's synced skills (`anthropic-skills:*`, among them skill-creator), 16 plugins
from `~/.claude/settings.json` (superpowers, feature-dev, code-review, frontend-design, …), the user hooks, the
owner's `~/.claude/CLAUDE.md` and the user's model. None of those is a Compositor skill today (checked:
`~/.claude/skills` and `~/.agents/skills` have none), but any of them changes what the baseline does, and an
installed Compositor skill would make the baseline a with-skill run.

`--setting-sources project,local` leaves out the user source: the same probe then listed only Claude Code's
built-in skills (debug, verify, simplify, claude-api, …), no plugins and no hooks, and the session didn't know
`~/.claude/CLAUDE.md`. It also drops the user's `model`, so `run_eval.py` passes `--model` itself, by default the
one in `~/.claude/settings.json`. Every run records the session's `init` event: a run that lists a skill with "compositor" in its name that it
didn't install (any, for `without_skill`), or a `with_skill` run that doesn't list its skill, fails as contaminated.

`run_eval.py` runs, from a new project folder in the sandbox:

```sh
claude -p "<eval prompt>" --mcp-config <run>/mcp-config.json --strict-mcp-config \
  --output-format stream-json --verbose --setting-sources project,local --no-session-persistence \
  --model <model> --allowedTools <allowlist>
```

Never `--permission-mode bypassPermissions`: in `-p` mode Claude Code denies every permission-checked call that no
rule allows, so the session gets exactly this allowlist (`run_eval.allowed_tools`, also written to each run's
`allowed-tools.json`), the same for both configurations except the skill's own scripts:

| Rule | Why |
|---|---|
| `mcp__compositor` | every Compositor tool (left out, with the MCP server, for an eval marked `"mcp": false`: a setup question from someone whose clients aren't connected yet, where the instance's own port would leak into the answer) |
| `Read(/<sandbox>/**)`, `Edit(/<sandbox>/**)`, `Write(/<sandbox>/**)` | the run's project and the instance's Agent folder (the run's `outputs/` afterwards); a sandbox under `/private/tmp` or `/private/var` is also allowed as `/tmp/…` or `/var/…`, the spelling Compositor's results use |
| `Bash(sips:*)`, `Bash(shasum:*)`, `Bash(ls:*)`, `Bash(file:*)`, `Bash(mkdir:*)`, `Bash(cp:*)` | checking sizes and fingerprints, listing and copying; Bash's own path checks keep `cp` and `mkdir` inside the sandbox |
| `Bash(uv run --with psd-tools python3 <repo>/scripts/psd-verify.py:*)`, `Bash(python3 <repo>/scripts/psd-diff.py:*)`, `Bash(uv run --with pillow python3 <repo>/scripts/psd-diff.py:*)` | the repository's PSD checks |
| with the skill: `Bash(<script>:*)`, `Bash(bash <script>:*)` for its `.sh` files and `python3`, `uv run --with psd-tools python3` and `uv run --with pillow python3` for its `.py` files, by their absolute paths in the project | the skill's own scripts, including the verification scripts `package-skills.sh --stage` bundles |
| every script rule also with the script's path in double quotes | rules match command text, and agents quote paths |

`photoshop-verify.sh` is never allowed, although the template skills bundle it: it drives the owner's live Photoshop,
which only the operator runs, one check at a time machine-wide. Probes on 2.1.280 with these exact rules: a Write
and a `cp` outside the sandbox, `photoshop-verify.sh`, `python3 -c` and a Read of `~/.zshrc` were all denied
(`permission_denials` in the result event) and nothing appeared outside; a Write inside the sandbox, `sips`,
`psd-verify.py` and Compositor's tools ran. The `Skill` tool isn't permission-checked, and this version has no
separate Glob or Grep tools (an agent lists files with `ls`).

- `mcp-config.json` is `{"mcpServers": {"compositor": {"type": "http", "url": "http://127.0.0.1:<port>/mcp"}}}`;
  `--strict-mcp-config` ignores every other MCP server (the user's, and claude.ai connectors).
- The environment drops the calling session's `CLAUDECODE`, `CLAUDE_PID`, `CLAUDE_EFFORT` and `CLAUDE_CODE_*`
  (a run started from inside Claude Code would otherwise inherit its effort level and session links) and sets
  `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`, so no run writes memory another run could read.
- The project folder is new for every run, under `$SKILLS_EVAL_SANDBOX/projects/p-<random>`: outside any git
  checkout, so the session gets no repository status and can't reach `skills/` from its working folder, and named
  the same way for both configurations. `with_skill` gets the skill in `.claude/skills/<skill>/`, and for a
  workflow skill also the `compositor` entry skill it builds on ("Read the compositor skill first"; every install
  and package ships them together; `eval_metadata.json` lists them as `skills_installed`, `timing.json` the ones
  the session called as `skills_invoked`), each as `scripts/package-skills.sh --stage` writes it, the way a
  packaged `.skill` has it: without its `evals/` (the
  expectations it is graded on) and, for the template and delivery skills, with the repository's `psd-verify.py`,
  `psd-diff.py` and `photoshop-verify.sh` copied into its `scripts/`.
- Both configurations get the same `.claude/settings.json`: deny rules, a second line behind the allowlist. They
  keep the session out of the protected folders (`~/Documents`, `~/Desktop`, `~/Downloads`, iCloud Drive,
  `~/Library/CloudStorage`, `/Volumes`), away from the owner's client configuration (`~/.claude.json`, `~/.claude`,
  `~/.codex`, `~/.agents`, Claude Desktop's folder, preferences, `claude mcp …`, `codex mcp …`,
  `defaults write`), from starting or stopping apps (`open`, `osascript`, `kill`, `launchctl`) and from tools that
  reach past the session (`WebFetch`, `WebSearch`, `PushNotification`, `SendMessage`, `RemoteTrigger`,
  `CronCreate`, `ScheduleWakeup`). An allowed command is still a command (`sips --out` can write anywhere): the
  rules are a guard, not a sandbox.
- Nothing the session started outlives its run: an orphaned session, or a command it left in the background,
  would go on calling the instance and writing into the Agent folder while the next run resets and refills them.
  - `claude` runs in a process group of its own. When the session ends (and at the timeout) `run_eval.py` sends
    the whole group SIGTERM, then SIGKILL after 10 s.
  - Claude Code's Bash tool starts every command in a session of its own (it calls `setsid`; checked with a probe
    on 2.1.280: a `nohup sleep … &` ran on in its own group and session after `claude` and its group had gone,
    while a `run_in_background` command was ended by Claude Code itself). Such a command keeps its working folder,
    which is the run's new project folder unless the agent changed folders first. So `run_eval.py` then stops any
    of your processes still working inside the project folder (found with `lsof`; SIGTERM, then SIGKILL) and
    lists them in `timing.json`'s `stray_processes`. A background command started after a `cd` elsewhere isn't
    found; the Agent folder isn't swept, because a shell of yours open there would be stopped too.
  - Ctrl-C, SIGTERM or SIGHUP to `run_eval.py` stops the session the same way (a second Ctrl-C waits for that),
    then `run_eval.py` ends by that signal, so a shell loop running evals stops too. The interrupted run's folder
    has no `timing.json`; `grade_scripted.py` skips it, and `--force` runs it again. A SIGHUP or SIGTERM that the
    shell already ignores (`nohup`) stays ignored.
- After the session, and before the reset that closes every document without saving, `run_eval.py` records what
  the app has open in `final-state/` (see Results).

## Results

`skills-workspace/<skill>/iteration-N/eval-<id>/` (git-ignored) holds `eval_metadata.json` and, per configuration,
`run-K/`:

| File | Contents |
|---|---|
| `outputs/` | the Agent folder after the session: fixtures plus everything the agent wrote there |
| `outputs/metrics.json` | tool calls by name (a `run_batch` is one call; `batched_calls` counts its steps), errors, files created and changed (skill-creator's executor metrics) |
| `transcript.jsonl`, `transcript.md` | the raw stream-json session, and a readable one with the prompt, calls and answer |
| `timing.json` | `total_tokens` (all input, output and cache tokens), `duration_ms`, `total_duration_seconds`, cost, model, exit code, `timed_out`, `skill_loaded` (listed in the session) and `skill_invoked` (the Skill tool called with it, or its `SKILL.md` read; a with_skill run that never invokes it is noted on stderr, a description problem), `tool_calls` (a `run_batch` is one), `permission_denials` (calls the allowlist refused), `contamination`, `stray_processes`, `final_state_errors` |
| `agent-folder-before.json` | sha256 of every file the session started with: the baselines for "unchanged" |
| `final-state/` | what the app had open when the session ended, captured before the reset: `list_documents.json` and, per tab with a document, `tab-<index>.json` with `get_document` (detail full: every layer's settings, text style and `content_bounds`), `get_history`, and `get_layer_bounds` and `get_text_metrics` for each text layer; a call that failed is recorded as `{"error": …}` (and listed in `timing.json`'s `final_state_errors`) |
| `grading.json` | `expectations` (`text`, `passed`, `evidence`), `summary`, `needs_grader`, `stale_checks`, `grader_inputs` |
| `project/`, `mcp-config.json`, `claude-stderr.log` | the session's folder and configuration |

`run_eval.py` exits 0 when the session ended, 1 when it refused to run or the run was contaminated, and 3 when the
session hit `--timeout` (default 900 s; the results are still filed).

## Grading

`grade_scripted.py` grades the expectations listed in `checks/<skill>.json` (files and folders, image sizes and
formats with `sips`, `psd-verify.py --raw` reports, `.comp` manifests, sha256 against the session's start, and the
order and arguments of tool calls; its docstring lists the check types) and leaves the rest, under
`needs_grader`, to a grader agent that follows skill-creator's `agents/grader.md` and adds its verdicts to the same
file, then recomputes `summary`. Only expectations a script can decide completely are scripted; one with an
alternative a script can't see ("… or the agent stopped to ask") is left to the grader.
`scripts/tests/test_skills_eval_grading.py` fails when a spec no longer matches exactly one expectation of its eval.

`grade_agent.py` has a grader agent grade them: `claude -p` from the run folder with skill-creator's
`agents/grader.md` (found through `SKILL_CREATOR` or under `~/.claude/skills`, or `--instructions`), the task, the
expected output, the expectations left open and where the evidence is. It may only read the run folder and run
`ls`, `sips`, `shasum`, `file` and `psd-verify.py` (`--allowedTools`, never `bypassPermissions`), has no MCP
server, and answers with a JSON block; a verdict counts only for an open expectation, quoted exactly, so the
scripted verdicts stay the script's. Its claims and eval feedback go into `grading.json` too, and `grader_agent`
records its model, tokens and time. Grading again with `grade_scripted.py` recomputes the scripted verdicts and
keeps the agent's. The agent gets the run's `transcript.md` as the transcript, `outputs/` as the outputs folder and
`final-state/` (`grading.json`'s `grader_inputs` names all three, with a note). Several expectations may
be checked "on the open document": text `content_bounds` and font sizes (compositor-layout-and-type eval 2, whose
prompt never saves a `.comp`), a layer's opacity or bounds, and `get_history`'s undo entries (compositor eval 3).
The reset after the session closes those documents, so `final-state/` is the only record of them when the agent
didn't measure its own work. It is the harness's record, made after the session: an expectation about what the
agent itself did or checked ("the transcript shows …") still needs the transcript.

Keep `timing` out of `grading.json`: skill-creator's `aggregate_benchmark` reads time and tokens from the run's
`timing.json` only when `grading.json` has no `timing.total_duration_seconds`, and otherwise reports output
characters as tokens.

## Known limits

- Saving PSD files over MCP isn't on this branch yet, so `compositor-psd-templates`' fixture fails to replay
  (`save_document_as` answers `unsupported`) and its evals are refused until it lands.
- `compositor-setup` eval 1 asks the agent to register Compositor with Claude Code, Codex and Claude Desktop; the
  guard rules deny those edits, so grade what it says it would do. `compositor-development`'s evals need a
  Compositor checkout as their project, which `run_eval.py` doesn't set up.
- skill-creator's viewer lists only files at the top of `outputs/`, while the Agent folder keeps the eval's own
  layout (`out/`, `exports/`, `templates/`). So point the viewer at a view built beside the iteration:
  `view_outputs.py <skill>/iteration-N <skill>/view-iteration-N` copies every image the agent made to the top of
  each run's `outputs/` (as `out__card.png`, scaled to 1024 px when larger), with `final-answer.md` and a
  `files.txt` of everything it made; then `generate_review.py <skill>/view-iteration-N --skill-name <skill>
  --benchmark <skill>/iteration-N/benchmark.json --static <html>` (with `--previous-workspace
  <skill>/view-iteration-<N-1>` from the second iteration). `view_outputs.py` replaces only a view it built (it
  leaves a `.view_outputs` marker) or an empty folder, and refuses a view inside or containing the iteration
  before deleting anything, so a mistyped view path can't delete runs.
