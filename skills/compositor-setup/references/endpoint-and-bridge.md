# Endpoint, ports and bridge

How a client finds Compositor's server, which port it uses, and what the `compositor-mcp`
bridge does. Read this when a port or the endpoint file surprises you, when two copies of
Compositor are running, or when configuring the bridge by hand.

## Transport

- Stateless MCP Streamable HTTP at `http://127.0.0.1:<port>/mcp`. Every JSON-RPC message is
  its own POST, `initialize` included, so any number of clients can share the server and a
  client that restarts needs no session. GET and DELETE get HTTP 405.
- Tool calls from every client go through one queue and run one at a time in arrival
  order: one agent's edit never interleaves with another's. At most 64 calls may be queued
  or running at once; the next one fails fast with a `busy` error.
- A long call simply holds its POST open until it finishes; there are no progress
  notifications.

## The endpoint file

`~/Library/Application Support/Compositor/mcp/endpoint.json`, written (atomically) when the
server starts and removed when it stops or Compositor quits:

```json
{
  "app_version" : "1.0",
  "auth" : "bearer",
  "pid" : 4312,
  "port" : 2667,
  "protocol" : "2025-11-25",
  "started_at" : "2026-09-23T10:00:00Z",
  "token_file" : "<home>/Library/Application Support/Compositor/mcp/token",
  "transport" : "streamable-http-stateless",
  "url" : "http://127.0.0.1:2667/mcp"
}
```

- `url` and `port`: where the server listens. `pid`: the Compositor process serving it.
  `protocol`: the newest MCP protocol version it speaks. `transport` is always
  `streamable-http-stateless`.
- `auth`: `"bearer"` when every request needs `Authorization: Bearer <token>` (the default),
  `"none"` when **Require access token** is off. With `"bearer"`, `token_file` is where the
  token is kept (an absolute path; `<home>` above is the user's home folder), readable only by
  the Mac's user. The endpoint file never holds the token.
- It is a hint, not proof. A crash or forced quit leaves the file behind, and the pid may
  since belong to another program. Trust it only when the pid is a live Compositor **and**
  the URL answers a `ping`, which is exactly what `scripts/check-compositor.sh` and the
  bridge check.
- At launch, Compositor deletes a leftover file unless it names *another* Compositor that is
  still running (which may be serving the stable port right now).
- If the file goes missing while the server runs, any start request (the bridge, or the
  notification below) makes the running server write it again.

## Ports

- **2667** by default ("COMP" on a phone keypad), so client configs stay valid across
  launches.
- **Custom port**: Compositor > Settings… > Port (1024–65535) > Apply; **Default** goes back to
  2667. Changing it restarts a running server on the new port at once, so every configured
  client must switch to the new URL. The value is stored in Compositor's preferences as
  `mcp.port`: `defaults read com.wonderassembly.compositor mcp.port` prints an override, and
  reports that the key doesn't exist when the default is in use.
- **Fallback**: if the port is taken (another app, or a second Compositor), the server
  binds a random free port instead of not starting. Settings shows a warning with both
  numbers, and its setup lines switch to the fallback port, which changes on every start.
  Fix it by freeing the port (`lsof -nP -iTCP:2667 -sTCP:LISTEN` shows who holds it) and
  turning the server off and on, or by choosing a fixed port of your own.
- **Two copies of Compositor** (say, an installed app and a development build) share the
  same preferences, the same default port and the same endpoint file. The first one to start
  its server gets 2667 and the endpoint file; a later one falls back to a random port and
  leaves the file pointing at the first, so already-configured clients keep reaching the
  first copy. Quit the copy you don't want an agent to drive.

## Starting the server from outside

- **`--mcp`**: `open -a Compositor --args --mcp` (a new launch only) starts the server for
  that session without turning the Settings switch on.
- **Start notification**: any process running as the logged-in user can post the
  distributed notification `com.wonderassembly.compositor.mcp.start`. A running Compositor
  whose server is off starts it for the session (or, when the Settings switch is on, as the
  switch's server); one whose server is already running rewrites the endpoint file. There is
  no prompt; the Settings switch is the only persistent, visible control, and Settings shows
  "Running for this session only" with **Stop for this session** whenever the server wasn't
  started by the switch.

## The compositor-mcp bridge

A small stdio server embedded in the app at `Compositor.app/Contents/MacOS/compositor-mcp`:
the setup every client starts with (Claude Code and Codex too), and the only one for clients
that can only launch local commands (Claude Desktop). It relays newline-delimited JSON-RPC
between stdin/stdout and the HTTP endpoint, one POST per line, with the access token.

```
compositor-mcp [--endpoint <url> | --endpoint-file <path>] [--token-file <path>] [--no-launch]
               [--launch-timeout <seconds>] [--log-file <path> | --no-log]
compositor-mcp --version | --help
```

| Flag | Effect |
|---|---|
| `--endpoint <url>` | Use this URL; ignore the endpoint file. |
| `--endpoint-file <path>` | Read this endpoint file instead of the default one. |
| `--token-file <path>` | Send the access token in this file (default: the file the endpoint file names). Needed with `--endpoint`, which reads no endpoint file. |
| `--no-launch` | Never launch Compositor or post the start notification; fail instead. |
| `--launch-timeout <s>` | How long to wait for the server to appear (default 20). |
| `--log-file <path>` | Write the bridge's diagnostic log here (default `~/Library/Logs/Compositor/bridge.jsonl`, unless Compositor's Settings turned diagnostic logs off). |
| `--no-log` | Write no diagnostic log. stderr is the same either way. |

- **Discovery**: the endpoint file counts only when its pid is alive and its URL answers a
  JSON-RPC `ping` within 2 s.
- **Access token**: every POST (the discovery ping too) carries the token from the token
  file, read again each time, so a regenerated token is used at once. The bridge refuses a
  token file that isn't this user's or that others can read or change (wider than 0600), and
  sends nothing then. A 401 makes it read the endpoint file again and retry once; if that is
  refused too, the client gets `Compositor's access token changed or is missing; restart the
  client or re-copy the setup snippet`.
- **Starting**: when nothing answers (and without `--no-launch`), it launches the
  `Compositor.app` it lives in with `--mcp`, in the background, or, when Compositor is
  already running, posts the start notification, repeating it every 2 s while it polls for
  the server.
- **Ordering**: `tools/call` lines are forwarded one at a time in stdin order, so dependent
  calls sent without waiting (create a document, then add a layer) still run in order;
  `ping`, `tools/list` and notifications go straight through.
- **Failures**: a request that can't be delivered gets a JSON-RPC error on its own id, code
  `-32000`, message `Compositor is not reachable: <reason>`. Diagnostics (lines starting
  `compositor-mcp:`) go to stderr only; stdout carries JSON-RPC and nothing else.
- It never routes through a system proxy and sends no `Origin` header.

## Security posture

These are deliberate owner decisions; describe them accurately and don't try to work
around them:

- An access token, required by default: other accounts on the Mac and sandboxed apps can
  reach loopback too, and the token, in a file only the Mac's user can read, keeps them from
  using Compositor's access to that user's files. The server checks it before reading a
  request's body. A client set up over HTTP sends the token to whatever answers on its port,
  which may not be Compositor (2667 is free while the server is off), so set clients up
  through the bridge: it sends the token only to the server the running Compositor
  published. **Regenerate token…** replaces it (bridge clients carry on; HTTP clients get
  401 until set up again). Turning it off (Compositor > Settings…, **Require access token**)
  is the owner's decision. The listener is bound to loopback, so nothing on the network can
  connect.
- `Host` must name loopback with the bound port (else 421), which blocks DNS rebinding.
- Any request with an `Origin` header is refused (403), so no web page can drive the app.
- No App Sandbox: tools read and write any path the logged-in user can, subject to macOS
  privacy prompts (see the skill's "Folder access" section).
- No tool replaces an existing file without `overwrite: true`; relative paths resolve inside
  the Agent folder, `~/Library/Application Support/Compositor/Agent`.
