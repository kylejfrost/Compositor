# Client setup

How to connect each MCP client to Compositor, check that it worked, and undo it. The setup
lines here are exactly what Compositor > Settings… offers for the default port
(`MCPClientSnippets` in the app); Settings regenerates them for whatever port the server is
really on, so copy from there whenever the port isn't 2667.

## The access token

By default every request must carry `Authorization: Bearer <token>`. The token is in
`~/Library/Application Support/Compositor/mcp/token`, a file only the Mac's user can read, so
other accounts on the Mac and sandboxed apps can't use Compositor's access to the user's files.

- Clients that run the **bridge** (Claude Code and Codex as below, Claude Desktop, Hermes,
  any stdio client) need nothing: the bridge reads the token for every request, sends it only
  to the server the running Compositor published, and picks up a regenerated one by itself.
  Set clients up this way unless the owner asks otherwise.
- Clients that connect over **HTTP** (Claude Code with `--transport http`, Codex with `--url`)
  send it themselves, to whatever answers on their port: while Compositor isn't listening
  there, another account's program could be, and would collect it.
  Settings shows `<token>` in their lines and **Copy** puts the real token on the clipboard.
  Don't print the token or paste it into a chat; from a shell, let the shell read the file
  (`$(cat "$HOME/Library/Application Support/Compositor/mcp/token")`).
- **Regenerate token…** in Settings replaces it: HTTP clients then get 401 until they are set
  up again with the new one. **Require access token** turns the requirement off; that is the
  owner's call, never a fix to apply for them.

## Which URL

The server's URL is `http://127.0.0.1:<port>/mcp`. Find the live one, in order of trust:

1. `bash <skill>/scripts/check-compositor.sh` (`<skill>` is this skill's base directory) prints it
   on its `OK` line.
2. The endpoint file, `~/Library/Application Support/Compositor/mcp/endpoint.json` (`url`).
3. Compositor > Settings…, next to "Endpoint", with a Copy button.

Always `127.0.0.1`, never the Mac's name, `0.0.0.0` or a network address: the server binds
loopback only and refuses any other `Host` with HTTP 421. The path is `/mcp`.

## Claude Code

Through the bridge, which finds the server and its token by itself:

```
claude mcp add compositor -- /Applications/Compositor.app/Contents/MacOS/compositor-mcp
```

Or straight to the URL, with the token as a header:

```
claude mcp add --transport http compositor http://127.0.0.1:2667/mcp --header "Authorization: Bearer <token>"
```

- The token (HTTP only): Settings' **Copy** gives this line with the real token. From a shell,
  let the shell read it instead of typing it:

  ```bash
  claude mcp add --scope user --transport http compositor http://127.0.0.1:2667/mcp \
      --header "Authorization: Bearer $(cat "$HOME/Library/Application Support/Compositor/mcp/token")"
  ```

  With **Require access token** off, leave out `--header` and what follows.
- Scope: without `--scope` the server is added for the current project directory only
  (`local`). `--scope user` before `compositor` makes it available in every project.
- Check: `claude mcp get compositor` shows the stored command or URL; `claude mcp list` shows
  whether it connects. Inside a session, `/mcp` lists servers and can reconnect one.
- New servers appear in sessions started afterwards. Tools show up as
  `mcp__compositor__<tool>`, for example `mcp__compositor__render_document`.
- The bridge setup needs no change for a new port or token. Over HTTP, change the URL (a new
  port) or the token (after **Regenerate token…**): `claude mcp remove compositor` (with the
  same `--scope`), then add it again.
- Remove: `claude mcp remove compositor`.

## Codex

Through the bridge, which finds the server and its token by itself:

```
codex mcp add compositor -- /Applications/Compositor.app/Contents/MacOS/compositor-mcp
```

Or straight to the URL. Codex then reads the token from an environment variable, which must
be set wherever Codex runs, so the `export` line belongs in `~/.zshrc` too (it reads the file,
so it holds no token and keeps working after a regenerate):

```bash
export COMPOSITOR_MCP_TOKEN="$(cat "$HOME/Library/Application Support/Compositor/mcp/token")"
codex mcp add compositor --url http://127.0.0.1:2667/mcp --bearer-token-env-var COMPOSITOR_MCP_TOKEN
```

- `codex mcp add` writes `[mcp_servers.compositor]` in `~/.codex/config.toml`. If one already
  exists, `codex mcp remove compositor` first rather than editing in a second table, which
  TOML rejects.
- Check: `codex mcp list` and `codex mcp get compositor`. Start a new Codex session to load
  it.
- Remove: `codex mcp remove compositor`.

## Claude Desktop

Claude Desktop starts local commands only, so it runs the stdio bridge embedded in the app
bundle rather than connecting to the URL itself. Add to
`~/Library/Application Support/Claude/claude_desktop_config.json` (Claude Desktop's
Settings > Developer > Edit Config opens it):

```json
{ "mcpServers": { "compositor": { "command": "/Applications/Compositor.app/Contents/MacOS/compositor-mcp" } } }
```

- Merge, don't overwrite: if the file already has `"mcpServers"`, add the `"compositor"` key
  inside it and keep every other server. Back the file up first, and check the result is
  valid JSON, for example with `python3 -m json.tool <file> >/dev/null`.
- Quit Claude Desktop completely (Cmd-Q) and reopen it; it reads the file only at launch.
- The command must be where the app really is. If Compositor isn't in `/Applications`,
  Compositor > Settings… warns and its copy of this line has the actual path; moving or
  reinstalling the app elsewhere breaks the old path.
- The bridge needs no URL and no token: it reads the endpoint file and the token file it
  names, and if no server answers it launches Compositor with `--mcp` or asks the open copy to
  start its server, waiting up to 20 s.
  Its messages go to Claude Desktop's MCP log for the server, under `~/Library/Logs/Claude/`.
- Remove: delete the `"compositor"` entry and restart Claude Desktop.

## Other clients

- **Hermes** (Nous Research Hermes Agent):
  - Add: `hermes mcp add compositor --command /Applications/Compositor.app/Contents/MacOS/compositor-mcp`
    and answer `Y` to enable all tools. This writes `mcp_servers.compositor` in
    `~/.hermes/config.yaml`. Add `timeout: 600` under it so long PSD opens and saves aren't
    cut off at Hermes's default 300 seconds.
  - Check: `hermes mcp test compositor` lists the tools; `hermes mcp list` shows it enabled.
  - Apply: a running gateway adds a new server by itself within a minute, but a changed
    setting (such as `timeout`) needs `/reload-mcp` sent in a chat while the agent is idle,
    or `hermes gateway restart`.
  - Skills: put the skill folders in `~/.hermes/skills/<name>` (or in `~/.agents/skills` with
    a symlink from `~/.hermes/skills`); `hermes skills list` shows them. Hermes names the
    tools `mcp__compositor__<tool>` and reaches them through `tool_call`.
  - Remove: `hermes mcp remove compositor`.
- **Any other client that launches stdio servers**: the command is the bridge,
  `/Applications/Compositor.app/Contents/MacOS/compositor-mcp`, with no arguments, optionally
  with flags (see [Endpoint, ports and bridge](endpoint-and-bridge.md)). It needs no token
  set up.
- A client that speaks MCP Streamable HTTP: give it the URL and the header
  `Authorization: Bearer <token>`. Every message is a POST; no session header is needed.
  Several clients can use the server at once.
- A browser, a web page or anything that sends an `Origin` header can't connect: the server
  refuses it with HTTP 403 by design.

## Verify end to end

From the client itself, not only from a shell:

1. List tools (`tools/list`, or the client's tool list). Expect about 130 Compositor tools,
   `list_documents`, `get_document`, `render_document` and `export_image` among them.
2. Call `list_documents`. An `ok: true` answer listing the open tabs proves the client, the
   transport, the server and the document workspace all work.
3. If the client can't see the tools but `check-compositor.sh` says `OK`, the problem is in
   the client's config or session: re-check the URL or command it stored, and start a new
   session.
