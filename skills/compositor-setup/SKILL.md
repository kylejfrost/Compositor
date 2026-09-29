---
name: compositor-setup
description: Connect AI agents to Compositor, the macOS image editor, through its built-in MCP server, and repair that connection when it fails. Use this whenever someone wants Claude Code, Codex, Claude Desktop or any other MCP client to drive Compositor, asks how to turn on, start or configure the Compositor MCP server, the compositor-mcp bridge, the endpoint file or port 2667, or reports Compositor tools missing, "Compositor is not reachable", HTTP 401 or an access token error, HTTP 421, 403 or 405, busy errors, a stale endpoint, or macOS privacy prompts blocking files in Documents, Desktop, Downloads, iCloud Drive or Google Drive, even when they never say "MCP".
---

# Compositor setup

Compositor carries a local [MCP](https://modelcontextprotocol.io) server so an agent can
open, edit, render and export documents through the same document model and undo stack as
the app's own UI. The server is **off until someone turns it on**, listens on
`http://127.0.0.1:2667/mcp` by default, answers only processes on this Mac, and by default
requires an **access token** that only the Mac's user can read (the bundled bridge, which
every client setup here starts with, sends it by itself). This skill
gets a client connected and gets it back when something breaks. Once connected, the
server's own `tools/list` is the authoritative list of what an agent can do.

## 1. Check the current state first

Run the bundled check before changing anything; it tells you which of the steps below you
actually need. It lives in this skill's `scripts/` folder, so call it by its full path from
wherever your shell is: `<skill>` below stands for this skill's base directory, which Claude
Code prints when the skill loads (for Codex, the folder holding this SKILL.md).

```bash
bash <skill>/scripts/check-compositor.sh                                  # the endpoint file's server
bash <skill>/scripts/check-compositor.sh --url http://127.0.0.1:2667/mcp  # the URL a client is set up with
```

It reads the endpoint file, checks it as the bridge does (the user's own file, which no one
else can change, naming loopback and a running Compositor), sends one JSON-RPC `ping` with
the access token from the file the endpoint file names, and prints one status line followed
by `fix:` and `note:` lines. It changes nothing and never prints the token. Exit status 0
means the server answered. With `--url`, it sends the token only if that is the URL the
running Compositor published: any program can listen on a port Compositor isn't using,
another account's included, and would collect a token sent there. Don't add `--token-file`
to get past that.

| Status | Meaning | Go to |
|---|---|---|
| `OK` | The server answered the ping. | Step 3 (connect a client) |
| `NOT RUNNING` | No endpoint file: the server is off, or Compositor isn't open. | Step 2 |
| `STALE` | The file names a process that is gone or is no longer Compositor. | Step 2; relaunching Compositor clears it |
| `BROKEN ENDPOINT FILE` | The file can't be read. | Relaunch Compositor, which deletes it |
| `UNTRUSTED ENDPOINT FILE` | The file is another user's, others can change it, or it names somewhere other than loopback. | The `fix:` lines; tell the owner |
| `TOKEN UNUSABLE` | The access token file is missing, open to other users, or not a token. | The `fix:` lines |
| `REFUSED 401` | The server refused the token sent, or none was sent (with `--url`, to a URL the running Compositor didn't publish). | Step 5 |
| `NOT LISTENING` / `NO ANSWER` | Compositor is up but the URL doesn't answer. | [Troubleshooting](references/troubleshooting.md) |
| `REFUSED <status>` / `STARTING` / `UNEXPECTED` | An HTTP-level refusal. | The `fix:` lines, then [Troubleshooting](references/troubleshooting.md) |

A `note:` about a port other than 2667 means clients set up for 2667 won't reach this
server (see [Endpoint, ports and bridge](references/endpoint-and-bridge.md)).

## 2. Turn the server on

Two independent ways, and either one is enough:

- **Settings switch (persistent).** In Compositor's Settings window (Compositor >
  Settings…, ⌘,), turn on "Allow AI agents to control this document". The window has a
  single pane (no tabs to pick; code comments call it the "AI Agents" pane): the switch,
  the port, "Connect a client" and "Folder access". Written "Compositor > Settings…" in
  this skill. Off by default; stays on across launches.
- **This session only.** Launch with the `--mcp` argument (`open -a Compositor --args --mcp`),
  or post the distributed notification `com.wonderassembly.compositor.mcp.start`, which is
  what the `compositor-mcp` bridge does. Settings then shows "Running for this session only"
  with a **Stop for this session** button, and the server doesn't come back on the next
  launch. `open --args` only reaches a *new* launch; if Compositor is already open, ask the
  bridge instead:

  ```bash
  echo '{"jsonrpc":"2.0","id":1,"method":"ping"}' | /Applications/Compositor.app/Contents/MacOS/compositor-mcp
  ```

  The bridge finds no server, launches Compositor with `--mcp` (in the background) or
  signals the open copy, waits up to 20 s for the server, forwards the ping and prints the
  JSON-RPC answer, a line with `"result"` in it. Its progress goes to stderr.

Prefer a session start when you are the one asking. The Settings switch is the owner's
persistent, visible control over who may drive the app, so leave it to them unless they ask
you to keep the server on. Every process running as the logged-in user can post the start
notification, and no prompt appears when it does; that is a deliberate owner decision, not a
gap to work around or to hide.

## 3. Connect a client

Compositor > Settings… shows these lines ready to copy, generated for the port the server is
actually using. The versions below are for the default port; if `check-compositor.sh`
printed another port, use Settings' copies or swap in that URL. Where Settings shows
`<token>`, its **Copy** button copies the real access token; with **Require access token**
turned off, the lines come without it.

**Claude Code** (run in Terminal), through the bridge, which needs no URL and no token:
```
claude mcp add compositor -- /Applications/Compositor.app/Contents/MacOS/compositor-mcp
```
That adds it for the current project; add `--scope user` before `compositor` to make it
available everywhere. Check with `claude mcp get compositor`. A running session picks up a
new server only when it starts (or reconnects through `/mcp`). Claude Code can also connect
straight to the URL with the token as a header ([Client setup](references/clients.md#claude-code)),
but prefer the bridge: it sends the token only to the server the running Compositor
published, while an HTTP client sends it to whatever answers on its port.

**Codex** (run in Terminal), through the bridge, which needs no URL and no token:
```
codex mcp add compositor -- /Applications/Compositor.app/Contents/MacOS/compositor-mcp
```
Check with `codex mcp list`, then start a new Codex session. Codex can also connect straight
to the URL, reading the token from an environment variable
([Client setup](references/clients.md#codex)).

**Claude Desktop** (add to `claude_desktop_config.json`):
```json
{ "mcpServers": { "compositor": { "command": "/Applications/Compositor.app/Contents/MacOS/compositor-mcp" } } }
```
The file is `~/Library/Application Support/Claude/claude_desktop_config.json`. Merge the
`compositor` entry into its existing `mcpServers` object instead of replacing the file, then
quit and reopen Claude Desktop. Claude Desktop only launches local commands, so it runs
`compositor-mcp`, a stdio-to-HTTP bridge inside the app bundle, which finds the server
through the endpoint file and starts it when needed. The path is right only while Compositor
lives in `/Applications`; if the app is elsewhere, Settings warns and shows the real path.

**Hermes, or any other stdio client**: the command is the bridge,
`/Applications/Compositor.app/Contents/MacOS/compositor-mcp`, with no arguments; it finds the
server and its token by itself. In Hermes: `hermes mcp add compositor --command
/Applications/Compositor.app/Contents/MacOS/compositor-mcp`, answer `Y` to enable all tools,
then `hermes mcp test compositor`; a running gateway picks the new server up within a
minute. A Streamable HTTP client needs the URL and the
`Authorization: Bearer <token>` header. Step-by-step details, safe config edits and removal
are in [Client setup](references/clients.md).

**Verify from each client you set up**, not just from the shell. A `list_documents` answer
from the client proves the whole path: its config, the transport, the server and the
document workspace. Give the user the check for every client, since some need them:

- **Claude Code**: `claude mcp list` shows `compositor` connected; in a new session, the
  tools appear as `mcp__compositor__…` and a request to list the open Compositor
  documents calls `list_documents`.
- **Codex**: `codex mcp list` shows the entry; in a new Codex session, ask it to list the
  open Compositor documents.
- **Claude Desktop**: after quitting and reopening it, Compositor's tools appear among its
  tools; ask it to list the open Compositor documents. If they don't appear, its MCP log
  for the server under `~/Library/Logs/Claude/` says why.

## 4. Folder access (macOS privacy)

Compositor has no App Sandbox, so its tools can reach any path the logged-in user can. macOS
Files & Folders privacy still applies on top of that: the first time Compositor reads from
**Documents, Desktop, Downloads, iCloud Drive, a cloud provider such as Google Drive**
(under `~/Library/CloudStorage/`) **or another volume**, macOS asks the person at the Mac to
allow it, and an agent can't click Allow for them. Tools check first instead of waiting on
that prompt: within about two seconds a call fails with `busy` and `details.code:
"folder_access_pending"` (a prompt is waiting on the Mac's screen) or `io_error` with
`"folder_access_denied"` (macOS said no). `get_app_info` reports `folder_access` for each
location: `granted`, `denied`, `not_determined` (a prompt is waiting) or `absent`.

- Ask the owner to grant access ahead of time: the **Folder access** group in Compositor >
  Settings… has a **Request access** button per location (the owner answers the prompt),
  or **System Settings > Privacy & Security > Files & Folders** (turn on the entries under
  Compositor), or **Full Disk Access** in the same place. macOS asks only once; a denied
  location is turned on in System Settings, not re-asked.
- A development build is a different app to macOS privacy: grants given to the installed
  Compositor may not cover it, or survive a rebuild.
- Cloud files may be online-only placeholders; make sure the file is downloaded ("Keep
  Downloaded" / available offline) before asking Compositor to open it.
- Relative tool paths resolve inside the Agent folder
  (`~/Library/Application Support/Compositor/Agent`), which privacy prompts don't guard.
  When you can read a file yourself (your terminal or app has its own grants), copying it
  there spares Compositor a prompt that nobody may be present to answer.

## 5. When something fails after connecting

HTTP refusals arrive before any MCP message is read, so clients usually show them as
transport errors:

- **401**: the request didn't carry the current access token. A client set up over HTTP
  before the token was regenerated has the old one: set it up again through the bridge, or
  with Settings' current line (Claude Code: `claude mcp remove compositor`, then add it
  again; Codex over HTTP: a new shell, so `COMPOSITOR_MCP_TOKEN` is read from the token file
  again, then a new Codex session). Through the bridge this arrives as `Compositor's access
  token changed or is missing; restart the client or re-copy the setup snippet`, or as a
  message naming a token file the bridge won't use ([Troubleshooting](references/troubleshooting.md#bridge-messages-claude-desktop)).
  Don't turn **Require access token** off to get past it: that is the owner's decision.
- **After Regenerate token…** (Compositor > Settings…, the owner's button, for a token that
  may have leaked): clients on the bridge carry on, since it reads the token file for every
  request; every HTTP client gets 401 until it is set up again as above
  ([Troubleshooting](references/troubleshooting.md#after-regenerate-token)). Suggest it when
  an HTTP client may have sent its token to something other than Compositor.
- **421**: the `Host` wasn't `127.0.0.1` (or `localhost`) with the server's port. Use exactly
  `http://127.0.0.1:<port>/mcp`. The server answers only this Mac, by design: another
  computer, the Mac's network address or a proxy in between gets 421 (or no connection).
  There is no supported remote access: its tools read and write files as the Mac's user,
  and the access token keeps out other accounts and apps on this Mac, not other computers;
  the loopback-only design is the protection.
  Run the agent on the Mac itself; don't suggest SSH tunnels, port forwarding, proxies
  or running the bridge over SSH to get around it.
- **403**: the request carried an `Origin` header, as every browser request does. Web pages
  and browser tools are refused on purpose; use an MCP client or the bridge.
- **405**: a GET or DELETE, from a client set up for SSE. Use Streamable HTTP, which POSTs
  every message (`claude mcp add --transport http …`, `codex mcp add … --url …`).

Tool failures come back as a normal result with `isError: true` and
`{"ok": false, "error": {code, message, guard?, hint?, details?}}`: read `hint` first.

- `busy`: 64 calls are already queued or running across every client, or the document is
  in the middle of an import, save or other long operation. Wait briefly and retry, and
  don't fire calls in parallel to go faster; they run one at a time anyway.
- `precondition_failed` with a `guard` such as `can_edit_layers`: something open in the app
  (a dialog, a text edit, a crop, a transform) blocks agent edits; the `message` says which.
  Ask the user to finish or cancel it, then retry.
- `precondition_failed` with `guard: "document"`: that tab has no document; create or open
  one first.
- A call that never returns: tool calls run one at a time, so a long export ahead of it
  holds it up; a privacy prompt (section 4) can also be waiting on the Mac's screen.

The other HTTP codes (`406`, `415`, `400`, `413`, `503`), every bridge message
("Compositor is not reachable: …"), fallback ports, a second copy of Compositor and stale
endpoint files are covered in [Troubleshooting](references/troubleshooting.md).

## Reference files

- [Client setup](references/clients.md): per-client steps, non-default ports, verifying,
  removing a server, config file locations.
- [Endpoint, ports and bridge](references/endpoint-and-bridge.md): the endpoint file's
  fields and lifecycle, port 2667 and the fallback, a second Compositor, the bridge's flags
  and discovery rules, and the security posture behind them.
- [Troubleshooting](references/troubleshooting.md): symptom by symptom, with the cause and
  the fix.
