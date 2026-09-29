# Diagnostic logs

Compositor keeps a diagnostic log of what the app, its MCP server and the `compositor-mcp` bridge do: launches,
agents' requests and tool calls and how each ended, documents opened, saved and exported, macOS folder-access
checks, and the errors it showed. When something goes wrong while you work (or while an agent works for you), the
log says what happened, so the problem can be found and fixed without reproducing it from memory.

Logging is on by default and never slows the app down. It keeps file paths, but never the MCP access token, image
data or what documents contain.

## Contents

- [Where the logs are](#where-the-logs-are)
- [Turning logs on, off or verbose](#turning-logs-on-off-or-verbose)
- [Format](#format)
- [What is logged](#what-is-logged)
- [Privacy](#privacy)
- [Rotation and retention](#rotation-and-retention)
- [Reading the logs](#reading-the-logs)
- [Collecting logs](#collecting-logs)
- [For developers](#for-developers)

## Where the logs are

| File | Written by |
|---|---|
| `~/Library/Logs/Compositor/compositor-YYYY-MM-DD.jsonl` | Compositor: one file per day (local time), then `compositor-YYYY-MM-DD.1.jsonl`, `.2`… past 20 MB |
| `~/Library/Logs/Compositor/bridge.jsonl` | every `compositor-mcp` bridge a client starts (each line carries the bridge's `pid`); `bridge.1.jsonl` holds the previous 20 MB |
| unified log, subsystem `com.wonderassembly.compositor` | Compositor: each event again, with the event's category (`mcp`, `http`, `document`…) |

The folder is readable by your account only (0700) and each file is 0600. **Compositor › Settings… › Diagnostic
logs › Reveal Logs in Finder** opens it. An agent can find it with `get_app_info`, whose `logs` field is
`{enabled, verbose, directory}` (never the log's contents).

## Turning logs on, off or verbose

Compositor › Settings… › **Diagnostic logs**:

- **Keep diagnostic logs** (`log.enabled`, on by default). Off, Compositor writes no events, to its files or the
  unified log, and a bridge started afterwards writes none either. (A few messages that predate this log, such as
  the MCP endpoint's address, still go to the unified log.)
- **Verbose** (`log.verbose`, off by default) adds `debug` events: the argument values of read-only tool calls
  (otherwise only their names are logged), every successful `tools/call` request's `rpc` event (otherwise only its
  `tool_call` event), and the time each preview an agent asks for took to render. Turn it on while chasing a problem,
  then off again.

Both apply at once. The bridge also takes `--log-file <path>` (log there instead) and `--no-log`.

## Format

JSON Lines: one object per line. Every line starts with the same four members, in this order, then the event's
fields in name order:

| Member | Meaning |
|---|---|
| `ts` | when, in UTC with milliseconds: `2026-09-24T14:03:05.123Z` |
| `level` | `debug` (verbose only), `info`, `notice` (an agent's call refused, a request refused), `warning` (an error shown to you, a file macOS kept Compositor out of), `error` (a bug, a server that couldn't start) |
| `cat` | `app`, `mcp`, `http`, `bridge`, `document`, `folder_access`, `profile`, `update` (`psd` is reserved) |
| `event` | what happened; see below |

Because `ts` always comes first, a plain text comparison filters a file by time (`collect-logs.sh` does).

Sample lines (synthetic):

```json
{"ts":"2026-09-24T14:03:05.123Z","level":"info","cat":"app","event":"launch","build":"42","cpus":12,"document_pixel_budget":800000000,"launched_with_mcp":false,"macos":"Version 26.5 (Build 25F71)","max_canvas_side":30000,"max_pixels":200000000,"mcp_enabled":true,"memory_gb":32.0,"model":"Mac16,11","pid":4242,"verbose":false,"version":"1.4.0"}
{"ts":"2026-09-24T14:03:05.402Z","level":"info","cat":"mcp","event":"server_started","auth":"bearer","endpoint_file":"/Users/me/Library/Application Support/Compositor/mcp/endpoint.json","fell_back":false,"pid":4242,"port":2667,"preferred_port":2667,"reason":"settings"}
{"ts":"2026-09-24T14:05:11.020Z","level":"info","cat":"mcp","event":"rpc","client":{"name":"claude-code","version":"2.1.0"},"conn":3,"duration_ms":2.1,"id":"0","method":"initialize","response_bytes":4180,"status":200}
{"ts":"2026-09-24T14:05:12.874Z","level":"info","cat":"mcp","event":"tool_call","args":{"layer":"Headline","text":"Spring Sale"},"call":"9f2c61d0","client":{"name":"claude-code","version":"2.1.0"},"conn":3,"duration_ms":14.6,"images":0,"outcome":"ok","queued_ms":0.2,"result_bytes":512,"rpc_id":"7","tool":"set_text","undo":{"name":"Edit Text","recorded":true}}
{"ts":"2026-09-24T14:05:12.990Z","level":"info","cat":"mcp","event":"tool_call","args":["document"],"call":"51a7e9c2","client":{"name":"hermes","version":"0.9.0"},"conn":5,"duration_ms":3.2,"images":0,"outcome":"ok","queued_ms":0.1,"result_bytes":1840,"rpc_id":"4","tool":"get_document","via":"bridge"}
{"ts":"2026-09-24T14:05:13.310Z","level":"notice","cat":"mcp","event":"tool_call","args":{"layer":"Logo","opacity":0.5},"call":"4b8e03aa","duration_ms":0.4,"error":{"code":"not_found","message":"No layer named 'Logo'."},"images":0,"outcome":"error","result_bytes":230,"tool":"set_layer_opacity"}
{"ts":"2026-09-24T14:06:40.051Z","level":"info","cat":"document","event":"save","bytes":8123456,"duration_ms":812.4,"format":"psd","kind":"save_as","layer_records":14,"lossy":false,"path":"/Users/me/Library/Application Support/Compositor/Agent/Poster.psd","via":"mcp","warnings":[]}
{"ts":"2026-09-24T14:07:02.990Z","level":"notice","cat":"http","event":"refused","auth_header":"wrong","client":"127.0.0.1:53122","conn":9,"reason":"unauthorized","status":401}
{"ts":"2026-09-24T14:07:03.004Z","level":"info","cat":"bridge","event":"forward","duration_ms":16.2,"id":"12","method":"tools/call","pid":5120,"request_bytes":143,"response_bytes":612,"status":200,"tool":"list_documents"}
```

## What is logged

### App (`app`, `update`)

| Event | Fields |
|---|---|
| `launch` | `version`, `build`, `macos`, `model`, `memory_gb`, `cpus`, `max_canvas_side` and `max_pixels` (one canvas, export or other surface), `document_pixel_budget` (all of a document's layers, which scales with the Mac's memory), `launched_with_mcp` (`--mcp`), `mcp_enabled` (the Settings switch), `verbose`, `pid`, and `migration` (what the one-time carry-over of the sandboxed app's preferences did) |
| `terminate` | `uptime_s` |
| `user_error` (warning) | an error Compositor showed you: `what` (`paint`, `import`, `crop`, or `alert` with its `title`) and `message`. One raised inside an agent's tool call is that call's error instead |
| `log_dropped` (warning) | `count`: events dropped because 10,000 were already waiting to be written |
| `check_started`, `update_found`, `no_update`, `check_failed`, `check_finished` (`update`) | Sparkle's update checks: the check's `kind` (`background`, `user`, `information`), the version found, Sparkle's reason or error code. Nothing about you |

### MCP server (`mcp`, `http`)

| Event | Fields |
|---|---|
| `server_started` | `reason` (`settings` or `session`), `port`, `preferred_port`, `fell_back`, `auth` (`bearer` or `none`), `endpoint_file`, `pid` |
| `server_start_failed` (error) | `error`, `preferred_port` |
| `server_stopped` | `reason` (`settings_switch`, `stopped_for_session`, `port_changed`, `listener_failed`, `start_failed`, `token_unavailable`, `app_terminating`, `requested`), `port` |
| `auth_changed`, `token_regenerated` | the token requirement turned on or off; the token replaced. Never the token |
| `rpc` | each JSON-RPC request: `method`, `id`, `tool` (for `tools/call`), `status` (HTTP), `rpc_error` (the JSON-RPC error code, if any), `duration_ms`, `response_bytes`, `conn`, `client` `{name, version}` (see below) and `via` (`bridge` for a request the bridge forwarded). A successful `tools/call` is `debug`: its `tool_call` event says more |
| `tool_call` | one per call: `call` (an id), `tool`, `args` (see [Privacy](#privacy); a read-only tool lists only its arguments' names unless verbose), `duration_ms`, `outcome` (`ok` or `error`), `error` `{code, message, guard, detail}` (`detail` is `details.code`), `undo` `{name, recorded}`, `result_bytes`, `images`, and for a call over HTTP `client`, `via` (`bridge`), `rpc_id` (the client's own id), `conn` and `queued_ms` (time waiting behind other calls). Errors are `notice`, `internal` errors `error` |
| `batch_step` | each step of a `run_batch`: `batch` (the batch's `call` id), `step`, `tool`, `args`, `duration_ms`, `outcome`, `error` |
| `refused` (`http`, notice) | a request refused before any JSON-RPC ran: `status` (400, 401, 403, 405, 406, 408, 413, 415, 421, 431, 501, 503), `reason` (`unauthorized`, `browser_origin`, `host_not_loopback_with_this_port`, `request_too_large`…), `client` (address and port), `conn`, and for 401 `auth_header` (`missing` or `wrong`). Never a header's value |

The server keeps no sessions, so a client that talks to it directly over HTTP is known by the connection its
`initialize` came on; most keep their connection, so their later calls carry `client` too. The bridge sends each
line as its own request, rarely on the connection its client's `initialize` used, so it names the client itself: it
remembers the `clientInfo` of the `initialize` it forwarded and sends it with every later request as
`X-Compositor-Client: <name>/<version>` (percent-encoded to printable ASCII, at most 100 characters), and marks every
request with `X-Compositor-Transport: bridge`. Its calls (Hermes, Claude Desktop, or Claude Code and Codex set up
with the bridge) are logged with that `client` and `"via":"bridge"`. These headers change nothing but the log; one
that is missing or malformed is ignored, and the connection's client is used instead.

### Documents (`document`)

| Event | Fields |
|---|---|
| `open` | `path`, `format`, `bytes`, `duration_ms`, `conversions` (Photoshop conversions needed) and `conversion_notes` (each distinct note). Reverting reads the file again, so it logs an `open` too |
| `open_failed` (warning) | `path`, `error` |
| `save` | `path`, `format`, `kind` (`save`, `save_as`, or `copy` for a save_document_as with `set_as_current: false`), `via` (`app` or `mcp`), `duration_ms`, `bytes`; for a PSD also `layer_records`, `lossy` and `warnings` (each `{layer, message, lossy}`) |
| `export` | `path`, `format`, `bytes`, `width`, `height`, `via` |
| `revert` | `path`, `discarded_changes` |
| `close` | `path` (null for a document with no file), `title`, `discarded_changes` |
| `render` (debug) | a preview an agent asked for: `width`, `height`, `layers`, `bytes`, `duration_ms` |

A failed save or export shows up as the tool call's error, or as a `user_error` when you saw the alert.

### Folder access and profiles

| Event | Fields |
|---|---|
| `probe` (`folder_access`) | `root` (`documents`, `desktop`, `downloads`, `icloud_drive`, `cloud_storage`, `removable_volumes`), `state`, `denied_folders`, `pending_folders`, `duration_ms` |
| `blocked` (`folder_access`, warning) | a path macOS kept Compositor out of: `path`, `root`, `code` (`folder_access_denied` or `folder_access_pending`) |
| `scan` (`profile`) | the profile library: `profiles`, `usable`, `hidden`, `groups`, `duration_ms` |
| `import` (`profile`) | `imported`, `already_imported`, `skipped`, `skipped_files` (`{path, reason}`) |

### Bridge (`bridge`, in `bridge.jsonl`)

| Event | Fields |
|---|---|
| `start` | `version`, `args` (its command line), `endpoint_source` (`file` or `url`), `endpoint`, `launches`, `launch_timeout` |
| `endpoint_found` | `url`, `launched` (whether Compositor had to be started), `waited_ms` |
| `endpoint_absent`, `endpoint_unusable` | `reason` |
| `launch` | `action` (`notify_running_app` or `open_app`), `app`, `error` |
| `launch_timed_out` | `waited_ms` |
| `forward` | each line forwarded: `method`, `id` (or `ids` for a batch), `tool`, `status`, `rpc_error`, `duration_ms`, `request_bytes`, `response_bytes`. Never the arguments or the answer |
| `retry_401` | a 401 made the bridge read the endpoint file again and resend |
| `connection_failed` | `url`, `error`, `retrying` |
| `unreachable` (warning) | a line that couldn't be delivered: `method`, `id`, `reason` |
| `exit` | `reason` (`stdin_closed` or `stdout_closed`) |

Every bridge line also has `pid`. What the bridge writes to stderr is unchanged.

## Privacy

Every value goes through the same rules before it's written, whoever logged it:

- A field whose name mentions a token, secret, password, authorization, API key, cookie or credential is written as
  `"[redacted]"`.
- `Bearer <anything>` becomes `Bearer [redacted]` anywhere in any text.
- Image and other binary data (a `data:` URL, or 200 or more characters of base64) becomes
  `[binary N chars sha256:<first 12 hex digits>]`, so two logs can still tell whether they saw the same image.
- Outside file paths, a run of 40 or more letters, digits, `_` and `-` that mixes letters with digits or with both
  cases (the shape of an access token or API key) becomes `[redacted]`. Layer ids (UUIDs) and hex digests stay.
- Text is cut to 300 characters, paths to 1,024, lists to 20 items and nesting to 6 levels, each saying how much was
  left out.

File paths are kept: they're what makes the log useful, and they only name files on your own Mac. Document text an
agent passes (a headline, say) appears in `tool_call` arguments, cut to 300 characters; pixels never do.

## Rotation and retention

- Compositor starts a new file each day, and a numbered one (`.1`, `.2`…) when a day's file would pass 20 MB.
- Whenever it starts a file it deletes files more than 14 days old (by the day in their names), then the oldest
  files until the rest fit in 200 MB.
- The bridge rolls `bridge.jsonl` over to `bridge.1.jsonl` at 20 MB, replacing the previous one: at most about 40 MB.
- Bundles made by `collect-logs.sh` under `collected/` are never deleted automatically.
- At most 10,000 events wait to be written; past that they're dropped and counted (`log_dropped`). A write that
  fails is counted and skipped; it never reaches the app or an agent.

## Reading the logs

```bash
# Follow today's log.
tail -f ~/Library/Logs/Compositor/compositor-$(date +%F).jsonl
# Every failed tool call today, with its error (needs jq: brew install jq).
jq -c 'select(.event == "tool_call" and .outcome == "error") | {ts, tool, error}' ~/Library/Logs/Compositor/compositor-$(date +%F).jsonl
# The slowest calls.
jq -s -c 'map(select(.event == "tool_call")) | sort_by(-.duration_ms) | .[:10][] | {ts, tool, duration_ms}' ~/Library/Logs/Compositor/compositor-$(date +%F).jsonl
# The same events in the unified log.
log show --predicate 'subsystem == "com.wonderassembly.compositor"' --last 1h
log stream --predicate 'subsystem == "com.wonderassembly.compositor"'
```

## Collecting logs

[`scripts/collect-logs.sh`](../scripts/collect-logs.sh) gathers everything needed to look into a problem into one
folder and prints its path:

```bash
scripts/collect-logs.sh --since 2h                  # this Mac, the last two hours
scripts/collect-logs.sh --since 2026-09-24T13:00:00Z # since a time (UTC; "2026-09-24 09:00" is local time)
scripts/collect-logs.sh --host mac-mini --since 6h  # another Mac, over SSH
```

| Option | Meaning |
|---|---|
| `--host <ssh-alias>` | Collect on that Mac over SSH and copy the bundle back. The other Mac needs nothing installed (the script runs there through `bash -s`) and keeps no copy. SSH must work without a password prompt. |
| `--since <duration or time>` | `30m`, `6h`, `2d` (default `24h`), or a time. |
| `--out <folder>` | Where the bundle goes; default `~/Library/Logs/Compositor/collected`. |

The bundle, `compositor-logs-<host>-<date>-<time>/`, holds:

- `compositor/`: the lines of `compositor-*.jsonl` and `bridge*.jsonl` from `--since` on;
- `unified-log.ndjson`: `log show --predicate 'subsystem == "com.wonderassembly.compositor"' --style ndjson` for the
  same span;
- `crash-reports/`: Compositor's and the bridge's crash reports since then (`~/Library/Logs/DiagnosticReports`);
- `defaults.txt`: `defaults read com.wonderassembly.compositor`, without any line mentioning a token;
- `app.txt`: the installed app's version and build, and the running copies; `system.txt`: macOS, model, architecture;
- `hermes/`, when Hermes is installed: `~/.hermes/logs/*.log` from `--since` on and `hermes mcp list`, with every
  line that mentions a key, token, secret, password, Authorization or bearer replaced;
- `README.txt`: what was collected, and anything that couldn't be.

It reads only those places, never Documents, Desktop or any other folder of your files.

## For developers

- `CompositorLog` (`Compositor/Support/`) is the log. Log with `CompositorLog.active.info(.document, "event", [...])`
  (`debug`, `notice`, `warning`, `error` likewise); the fields are an autoclosure, evaluated only when the event is
  kept. Values are `LogValue`s; `LogEncoding` applies the privacy rules and writes the line on the log's queue, so a
  call site never blocks on I/O.
- Event shapes live next to their subject: `MCPLogging.swift` (tool calls, requests, refusals, the server),
  `DocumentLog.swift` (documents, folder access, profiles, renders), `AppLog.swift` (launch, quit, alerts, Sparkle),
  and `Tools/compositor-mcp/BridgeLog.swift`, the bridge's own small implementation. Hooks in shared code are one
  call each; add an event's fields there, and to the tables above.
- `CompositorLog.shared` writes nothing until the app starts it at launch (`LaunchTasks.writesLogs`, off in the test
  host), so unit tests never touch `~/Library/Logs/Compositor`. Tests route events to a log of their own in a
  temporary folder with `CompositorLog.$taskLog.withValue(log) { … }` (or `MCPServer.Options.log` for a real server)
  and read the lines back: see `LogHarness` in `CompositorTests/CompositorLogTests.swift`. Bridge tests pass
  `--log-file` in a temporary folder (`BridgeProcess.logFile`).
