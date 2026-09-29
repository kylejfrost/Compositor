# Troubleshooting

Start every diagnosis with `bash <skill>/scripts/check-compositor.sh` (`<skill>` is this skill's
base directory, which Claude Code prints when the skill loads): it
separates "the server isn't there" from "the client is set up wrong" in one step. Then find
the symptom below.

## Contents

- [The server isn't running or can't be found](#the-server-isnt-running-or-cant-be-found)
- [HTTP status codes](#http-status-codes)
- [Bridge messages (Claude Desktop)](#bridge-messages-claude-desktop)
- [After Regenerate token…](#after-regenerate-token)
- [Tool errors after connecting](#tool-errors-after-connecting)
- [Files that won't open](#files-that-wont-open)
- [Logs](#logs)

## The server isn't running or can't be found

| Symptom | Cause | Fix |
|---|---|---|
| `NOT RUNNING`, no endpoint file | Compositor is closed, or open with its server off. | Turn the server on (the skill's step 2). |
| `STALE`: pid not running | Compositor crashed or was force-quit and left its endpoint file. | Open Compositor; at launch it deletes the stale file, and a started server writes a new one. |
| `STALE`: pid is another program | Same, and the pid has since been reused. | Same. |
| `BROKEN ENDPOINT FILE` | The file is truncated or was edited by hand. | Quit and reopen Compositor, or delete the file. |
| `UNTRUSTED ENDPOINT FILE` | The file belongs to another user, others can change it, or it names a URL off this Mac's loopback. The bridge ignores such a file too: it could send the token anywhere. | Delete it and turn the server off and on (Compositor writes it owner-only). If it comes back that way, tell the owner. |
| `NOT LISTENING` with a live pid | The server stopped (switch turned off, **Stop for this session**, or it failed to bind and Settings shows the error). | Open Compositor > Settings…: read the error, turn the switch off and on. |
| Client configured for 2667 can't connect, check shows `OK` with a `note:` about another port | 2667 was taken, so the server fell back to a random port; or a custom port is set. | Free 2667 (`lsof -nP -iTCP:2667 -sTCP:LISTEN`), then turn the server off and on; or re-add the client with the live URL. |
| The agent drives the wrong copy of Compositor | An installed app and a development build are both open; the first to start its server owns 2667 and the endpoint file. | Quit the copy you don't want; restart the server in the one you do. |
| `NO ANSWER` | The server is up but didn't reply to a ping within 3 s. | Bring Compositor to the front: a dialog, an alert or a macOS privacy prompt may be waiting. |
| `TOKEN UNUSABLE`: missing or can't be read | The access token file (`~/Library/Application Support/Compositor/mcp/token`) was deleted or moved. | Turn the server off and on in Compositor > Settings… (or relaunch Compositor): a start makes the file again, with a new token. |
| `TOKEN UNUSABLE`: open to other users | The token file's permissions were widened; the bridge won't use a token others could read. | `chmod 600` the file, or restart the server, which makes it owner-only again. |
| `REFUSED 401` | The server refused the token the check sent: it was just regenerated, or a second Compositor answers on this port with its own token. | Run the check again; if it persists, quit the copy of Compositor you don't want (see the wrong-copy row above). |
| `REFUSED 401 (the server at … sent none …)` after `--url` | That URL isn't the one the running Compositor published, so the check sent no token: whatever answers there may not be Compositor. | Use the URL the `fix:` line names (or run the check without `--url`), or set the client up through the bridge. Don't add `--token-file` to send the token there. |

## HTTP status codes

These come back before any MCP message is read, so the client usually reports them as a
connection or transport error.

| Status | Why the server refused | Fix |
|---|---|---|
| 401 | No `Authorization: Bearer <token>`, or an old token: the owner regenerated it, or the client was set up before the token was required. | Set the client up through the bridge, which sends the current token by itself, or again with the line Compositor > Settings… copies (Claude Code: `claude mcp remove compositor`, then add it again; Codex over HTTP: open a new shell so `COMPOSITOR_MCP_TOKEN` is read from the token file again, then start a new Codex session). Leave **Require access token** on: turning it off is the owner's decision. |
| 421 | The `Host` header wasn't `127.0.0.1` (or `localhost`) with the server's port. Typical causes: a URL using the Mac's name or network address, a port mismatch, or a proxy in between. | Use exactly `http://127.0.0.1:<port>/mcp`; exclude loopback from any proxy (`NO_PROXY=127.0.0.1,localhost`). |
| 403 | The request carried an `Origin` header, as every browser request does. | Connect from an MCP client or the bridge. Browser-based tools can't drive Compositor, by design. |
| 405 | A GET or DELETE: the client tried an SSE stream or a session delete. | Configure the client for Streamable HTTP (`claude mcp add --transport http …`, `codex mcp add … --url …`). The server answers every POST on its own and needs no stream. |
| 406 | `Accept` doesn't allow JSON. | The server answers in JSON only, so `Accept` must allow `application/json` (MCP clients send `application/json, text/event-stream`, which is fine). A client that asks only for `text/event-stream` gets 406. |
| 415 | `Content-Type` isn't `application/json`. | Fix the client, or use one that speaks MCP over HTTP. |
| 400 | An unsupported `MCP-Protocol-Version`, a body that isn't JSON-RPC, or a request id that is neither a string nor a number. | Update the client; the endpoint file's `protocol` is the newest version the server speaks. |
| 413 | The request body is over 32 MB. | Pass large images as file paths, never inline data. |
| 503 | The listener is up but the server is still starting. | Retry after a moment. |

## Bridge messages (Claude Desktop)

The bridge answers a request it couldn't deliver with a JSON-RPC error `-32000`,
`Compositor is not reachable: <reason>`. Its stderr (Claude Desktop's MCP log for the
server, under `~/Library/Logs/Claude/`) shows each step as `compositor-mcp: …`.

| Reason | Fix |
|---|---|
| `Compositor did not start its MCP server within 20 s` | The bridge launched or signalled Compositor, but no server appeared. Open Compositor, deal with any dialog or error in Compositor > Settings…, or raise `--launch-timeout` for a slow first launch. |
| `Compositor.app could not be found` / `Compositor could not be launched: …` | The bridge runs from outside an app bundle macOS knows, or the launch failed. Install Compositor in `/Applications`, open it once, and use the `command` line from Compositor > Settings…. |
| `… (--no-launch)` | The config passes `--no-launch`, so the bridge won't start Compositor. The text before it says why no server was found: `no Compositor MCP server is running (no endpoint file at …)`, `Compositor (pid N) is no longer running` (a stale file), `nothing answers at http://…`, or `the endpoint file at … is unreadable`. Start the server yourself or drop the flag. |
| `http://… did not answer`, or a connection error | The server went away mid-session and didn't come back on a second attempt: check Compositor > Settings…, and run `check-compositor.sh`. |

Access token problems come with the same code, `-32000`, and a message of their own; launching
Compositor wouldn't help, so the bridge reports them at once:

| Message | Fix |
|---|---|
| `Compositor refused the request (HTTP 401): Compositor's access token changed or is missing; restart the client or re-copy the setup snippet` | The bridge already read the endpoint and token files again and retried once. A bridge started with `--endpoint` sends a token only with `--token-file`: add it, or use the endpoint file (drop `--endpoint`). Otherwise a second Compositor may be answering: quit the one you don't want. |
| `Compositor's access token file at … is open to other users (mode …), so it isn't used` | `chmod 600` the file, or restart Compositor's server, which makes it owner-only again. |
| `… belongs to another user, so it isn't used` | The file isn't this account's: restart Compositor's server as this user, which makes a new one. |
| `Compositor's access token can't be read from …` / `… doesn't hold a token` | Turn the server off and on in Compositor > Settings… (or regenerate the token): it makes the file again. |
| `the endpoint file at … asks for an access token but doesn't say where it is` | Restart Compositor's server, which rewrites the endpoint file. |

The log shows the same reasons as it goes (`compositor-mcp: Compositor (pid N) is no longer
running; asking Compositor to start its MCP server`), which tells you where discovery
stopped.

If Claude Desktop shows no Compositor tools at all, check that the `command` path exists
(`ls -l` it): moving or reinstalling Compositor outside `/Applications` breaks it.

## After Regenerate token…

**Regenerate token…** in Compositor > Settings… replaces the token file at once; it is the
owner's button, the answer to a token that may have leaked (an HTTP client that sent it to a
port Compositor wasn't on, a pasted config).

- Clients on the bridge (Claude Desktop, Hermes, and Claude Code or Codex set up with the
  bridge command) need nothing: the bridge reads the token file for every request.
- Claude Code over HTTP stored the old token in its header: `claude mcp remove compositor`
  (with the same `--scope`), then add it again with the line Settings copies now, or better,
  through the bridge.
- Codex over HTTP reads `COMPOSITOR_MCP_TOKEN`, set when the shell started: open a new shell
  (the `export` line reads the file again), then start a new Codex session.
- Never paste the new token into a chat, a log or a file other than the client's own config.

## Tool errors after connecting

Every tool failure is an ordinary result with `isError: true` and
`{"ok": false, "error": {code, message, guard?, hint?, details?}}`. The `hint` says what
to do; `guard` names the check that failed.

| `code` | Meaning and what to do |
|---|---|
| `busy` | The queue already holds 64 calls from all clients, or the document is importing, saving or running another long operation. Wait and retry; don't fire more calls in parallel. |
| `precondition_failed` | The document isn't in a state that allows the call. `guard: "document"`: the tab has no document, so create or open one. `guard: "can_edit_layers"` or `"can_start_project_operation"`: something open in the app blocks edits (a text edit, transform, crop, gradient, a Levels or Hue/Saturation dialog, an alert); the `message` names it. Ask the user to finish or cancel it. `guard: "max_tabs"`: 32 documents are open; close one. |
| `not_found` | The tool, document, layer or file named doesn't exist. Re-list (`list_documents`, `get_document`) before retrying. |
| `ambiguous` | A layer or document selector matched several; `details.candidates` lists them with ids. Retry with an id. |
| `invalid_argument` | A missing, wrong-type or out-of-range argument, or one the tool doesn't take (a misspelled name is refused, not ignored); `tools/list` has each tool's schema. |
| `io_error` | Reading or writing a file failed. `details.code: "file_exists"` means the target exists and the call didn't pass `overwrite: true`. |
| `unsupported` / `internal` | Not supported by this version, or a bug; report the message. |

A tool that the documentation mentions but `tools/list` lacks means this Compositor is an
older build: the endpoint file's `app_version` says which.

## Files that won't open

- A call on a file in Documents, Desktop, Downloads, iCloud Drive or `~/Library/CloudStorage/`
  that hangs or fails with `io_error`: macOS privacy is holding it. Someone at the Mac must
  click Allow on the prompt, or grant access in System Settings > Privacy & Security >
  Files & Folders (or Full Disk Access). An agent can't answer the prompt.
- A cloud file that is only a placeholder may download slowly or not at all when opened;
  make it available offline first.
- Relative paths resolve inside the Agent folder
  (`~/Library/Application Support/Compositor/Agent`); an unexpected `not_found` is often a
  relative path that was meant to be absolute. Use `~/…` or a full path.

## Logs

Compositor records each request, tool call (duration, outcome, error code and message), HTTP
refusal, server start and stop, and each open, save and export in
`~/Library/Logs/Compositor/compositor-YYYY-MM-DD.jsonl`, one JSON object per line; the bridge
records each line it forwarded, 401 retries and connection failures in `bridge.jsonl` beside it.
Neither holds the access token or image data. `get_app_info.logs` says whether logging is on and
where. When a problem needs more than the error in front of you, gather the logs from the
Compositor repository with `scripts/collect-logs.sh --since 2h` (add `--host <ssh-alias>` for
another Mac); it prints the folder it wrote. Settings › Diagnostic logs turns logging off or
verbose. The format and every event are in the repository's `docs/logging.md`.
