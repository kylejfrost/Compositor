# MCP server

Compositor embeds a local [MCP](https://modelcontextprotocol.io) server so an AI agent
(Claude Code, Codex, Claude Desktop, or anything else that speaks MCP) can drive the
editor directly: open, create and save documents (including layered Photoshop files),
edit layers, masks, live text and shapes, run filters and adjustments, resize canvases,
render previews, and export — the same document model and undo stack the UI uses.

This document describes the server as built. The [tool reference](#tool-reference) is
generated from the registry the server answers `tools/list` from, so it lists every tool
with the same summary the agent sees; the running server's `tools/list` has each tool's
full description and input schema.

## Transport

Stateless [Streamable HTTP](https://modelcontextprotocol.io/specification), one
endpoint: `http://127.0.0.1:2667/mcp` by default. Any number of clients (Claude Code
and Codex at once, or a client that restarts) can talk to the same server; every POST
is answered on its own, `initialize` included.

- **IPv4 loopback only.** The listener binds `127.0.0.1` itself. `localhost` works only
  where it resolves to `127.0.0.1`; `[::1]` gets no answer.
- **POST only.** GET or DELETE gets `405` (`401` first, without the access token).
- **Port**: 2667 by default, changeable in Compositor › Settings…. If that port is taken
  (another app, or a second Compositor), the server falls back to an ephemeral port —
  Settings shows this and the port to free.
- **Endpoint file**: `~/Library/Application Support/Compositor/mcp/endpoint.json`,
  written while the server runs and removed when it stops. Fields: `url`, `port`,
  `pid`, `app_version`, `protocol` (the newest MCP protocol version served),
  `transport` (always `"streamable-http-stateless"`), `started_at`, `auth` (`"bearer"`
  when requests need the [access token](#security-posture), `"none"` when they don't) and,
  with `"bearer"`, `token_file` (the absolute path of the file holding the token; the file
  never holds the token itself). This is how the
  `compositor-mcp` bridge (and anything else) finds the running server without being
  told the port. Only its owner can read or write it (0600); the bridge ignores a file
  that belongs to another user or that others can change, and one whose `url` isn't
  plain HTTP to `127.0.0.1`, `localhost` or `[::1]`.
- **Access token**: by default every request carries `Authorization: Bearer <token>`;
  see [Security posture](#security-posture).
- **Instructions**: the `initialize` result carries a short operating manual (under
  4 KB): selectors, units, undo and batches, previews, file safety and folder access,
  locks, fonts, Photoshop files and profiles. The sections below say the same at length.

## Security posture

These are deliberate owner decisions, not gaps:

- **Access token (on by default).** Every request must carry
  `Authorization: Bearer <token>`, or the server answers `401` with
  `WWW-Authenticate: Bearer realm="Compositor"` and a JSON-RPC error. Why: loopback keeps
  out other computers, not other programs on this Mac, and that reaches further than the
  apps you run yourself:
  - **other user accounts on this Mac** (another person logged in with fast user
    switching, over SSH or Screen Sharing, or another user's background process) share
    the same loopback address;
  - **sandboxed apps** allowed outgoing network connections
    (`com.apple.security.network.client`, which most apps that talk to the internet
    have) can connect to loopback, although their sandbox keeps them out of your files.

  Without the token such a caller would work with Compositor's access, not its own (a
  confused deputy): open, save, export and list anything Compositor can reach, including
  the folders macOS lets Compositor into under Files & Folders. The token keeps them out as
  long as it reaches only Compositor (see **What it doesn't cover**), because it lives in a
  file only you can read:
  `~/Library/Application Support/Compositor/mcp/token` (0600, in a 0700 folder; the server
  makes it on its first start, keeps it across launches, and tightens both permissions at
  every start). It is 32 random bytes (`SecRandomCopyBytes`) in base64url without padding,
  43 characters.
  - **Checked first.** The server checks the token as soon as a request's head has arrived
    (after only the limits on its size and framing), before it reads the body, runs any
    other check or parses anything: a caller without it gets no further. The comparison
    takes constant time. The Host, Origin, method and content checks below still apply to
    requests that carry it.
  - **The bridge sends it by itself.** `endpoint.json` names the token file (`token_file`,
    with `"auth": "bearer"`), never the token; the bundled `compositor-mcp` bridge reads the
    token from there for every request, so a stdio client (Claude Code and Codex through the
    bridge, Claude Desktop, Hermes, any other) needs no setup beyond the bridge command. The
    bridge refuses a token file that isn't yours or that others can read or change (anything
    wider than 0600), and turns a `401` into a JSON-RPC error saying what to do.
  - **HTTP clients send it themselves.** Claude Code set up over HTTP gets it as a header
    when it is added, Codex over HTTP from an environment variable
    ([Client setup](#client-setup)). They send it to whatever answers on their port (below).
  - **Copy, regenerate, turn off.** Compositor › Settings… has **Copy token**, and
    **Regenerate token…**, which replaces the file at once: HTTP clients set up with the
    old token get `401` until they are given the new one, while the bridge picks up the new
    one by itself. **Require access token** turns the check off (the `mcp.requireToken`
    preference, on by default); the server then takes any request again, and
    `endpoint.json` says `"auth": "none"`.
  - **What it doesn't cover.**
    - Any process running as you can read the token file, as it can read everything else of
      yours; the token keeps out other accounts and sandboxed apps, not your own programs.
    - **An HTTP client sends its stored token to whatever answers on its port.** Claude Code
      or Codex set up over HTTP connects to the port it was given and sends the token there,
      whether or not Compositor is the one listening. The server is off by default, and when
      its port is taken it moves to another, so 2667 is often free: another account's
      program, or a sandboxed app allowed to accept connections
      (`com.apple.security.network.server`), can listen there and collect the token when the
      client starts a session, then find Compositor's real port by trying loopback ports.
      The bridge doesn't have this problem: it sends the token only to the URL the running
      Compositor published in its endpoint file, and only after checking that the file is
      yours, that no one else can change it and that the process it names is alive. So set
      clients up through the bridge, as every setup in [Client setup](#client-setup) does
      first. If an HTTP client may have sent the token somewhere else, use **Regenerate
      token…**.

    `get_app_info` reports `endpoint.auth` (`"bearer"` or `"none"`), never the token.
- **Loopback binding.** The listener binds `127.0.0.1` on the loopback interface only
  (`NWParameters` with `requiredInterfaceType = .loopback`); nothing on the network can
  reach it.
- **Host header check.** Every request's `Host` must name loopback with the bound port
  (`OriginValidator.localhost`), or the server answers `421` — this blocks DNS
  rebinding.
- **No browsers.** Any request carrying an `Origin` header is refused with `403`,
  whatever it says. Browsers always send `Origin` on a non-GET fetch; MCP clients
  (Claude Code, Codex, the bundled bridge) never do, so this closes the door to a web
  page driving the editor while still serving CLI/desktop agents.
- **No App Sandbox.** Compositor ships without the App Sandbox entitlement (hardened
  runtime only) specifically so its tools can read and write any path the signed-in
  user can — the same reach the app already has when you open or save a file
  yourself. Nothing here grants an agent access beyond that.
- **Overwrite is explicit.** No tool call replaces an existing file unless it passes
  `overwrite: true` (`save_document` rewrites the document's own file); otherwise
  writing fails with `io_error` / `details.code: "file_exists"`.
- **Anyone in your login session can start it.** Any process running as you, sandboxed
  apps included, can start the server for the current session by posting the
  distributed notification `com.wonderassembly.compositor.mcp.start` — the same call
  the bundled `compositor-mcp` bridge makes. The notification carries no payload (the
  App Sandbox lets an app post one as long as it has none), and Compositor doesn't
  check who posted it. There is no prompt when this happens, and it works with the
  Settings switch off and again after **Stop for this session**. Settings then shows
  "Running for this session only", but the switch is the only persistent control and
  it doesn't block these starts. With the access token required, starting the server
  gives such a caller nothing: it still needs the token to use it. With the token turned
  off, whatever starts the server (and, once it runs, anything on this Mac, other
  accounts included) can use it.

## Enabling

Two independent ways to run the server, and either can be on:

- **Settings switch** ("Allow AI agents to control this document" in
  Compositor › Settings…). Off by default; persists across launches.
- **Session-only**: launching Compositor with the `--mcp` argument, or another process
  posting the start notification above (this is what happens automatically when a
  bridge-based client, e.g. Claude Desktop, needs the server and Compositor isn't
  already serving it). This does **not** flip the Settings switch — Settings shows
  "Running for this session only" with a **Stop for this session** button, and it
  won't start again on the next launch.

A crashed instance's stale endpoint file is cleared at the next launch, unless it still
names a different, live Compositor process (which may be serving the stable port).

## Client setup

Compositor › Settings… has ready-to-copy versions of these. They come from
`MCPClientSnippets`, generated against whatever port the server is actually using. Where
a line needs the access token, Settings shows `<token>` and its **Copy** button puts the
token itself on the clipboard (nowhere else: it is never logged). With **Require access
token** off, the same lines come without the token.

Every client's first setup is the `compositor-mcp` bridge: it needs no token set up, and it
sends the token only to the server the running Compositor published. The HTTP setups for
Claude Code and Codex are the alternative; such a client sends its token to whatever answers
on its port ([Security posture](#security-posture)).

**Claude Code** (run in Terminal), through the bridge:
```
claude mcp add compositor -- /Applications/Compositor.app/Contents/MacOS/compositor-mcp
```
Add `--scope user` before `compositor` to make it available in every project. Or straight to
the endpoint, with the token as a header:
```
claude mcp add --transport http compositor http://127.0.0.1:2667/mcp --header "Authorization: Bearer <token>"
```
Claude Code stores that header with the server, so after **Regenerate token…** remove the
server (`claude mcp remove compositor`) and add it again with the new token.

**Codex** (run in Terminal), through the bridge:
```
codex mcp add compositor -- /Applications/Compositor.app/Contents/MacOS/compositor-mcp
```
Or straight to the endpoint, with Codex reading the token from an environment variable
that must be set wherever Codex runs (put the `export` line in `~/.zshrc`; it reads the
token file, so the line itself holds no token and keeps working after a regenerate):
```
export COMPOSITOR_MCP_TOKEN="$(cat "$HOME/Library/Application Support/Compositor/mcp/token")"
codex mcp add compositor --url http://127.0.0.1:2667/mcp --bearer-token-env-var COMPOSITOR_MCP_TOKEN
```

**Claude Desktop** (add to `claude_desktop_config.json`):
```json
{ "mcpServers": { "compositor": { "command": "/Applications/Compositor.app/Contents/MacOS/compositor-mcp" } } }
```

**Hermes and any other stdio client**: the command is the bridge,
`/Applications/Compositor.app/Contents/MacOS/compositor-mcp`, with no arguments.

Claude Code and Codex (their first lines above), Claude Desktop and Hermes run `compositor-mcp`, a small stdio↔HTTP bridge
embedded in the app bundle (`Contents/MacOS/compositor-mcp`). It finds the running server
via the endpoint file, sends the access token from the file the endpoint file names, and
launches Compositor with `--mcp` (or asks a running one to start its server) if nothing is
listening yet. Its flags: `--endpoint <url>` or `--endpoint-file <path>` to look elsewhere,
`--token-file <path>` to send the token in another file (needed with `--endpoint`, which
reads no endpoint file), `--no-launch`, `--launch-timeout <seconds>` (default 20), and
`--log-file <path>` or `--no-log` for its [diagnostic log](logging.md) (default
`~/Library/Logs/Compositor/bridge.jsonl`, off when Compositor's Settings turn diagnostic logs off).

**The bridge path moves if the app moves.** The commands above are only correct while
Compositor lives in `/Applications`; Settings warns and shows the actual path when it
doesn't, and the config must be updated to match.

## Agent skills

The repository's [`skills/`](../skills) folder holds agent skills that teach Claude Code,
Codex and other agents to use these tools well: `compositor` (conventions, errors, limits,
and a tool atlas generated from `tools/list`), `compositor-setup`, `compositor-psd-templates`,
`compositor-layout-and-type`, `compositor-image-editing`, `compositor-variants-and-delivery`
and `compositor-development`. Install them with `scripts/install-skills.sh` from the main
checkout (see the README). When a tool changes, regenerate the atlas with
`python3 skills/compositor/scripts/tool-atlas.py` while the server runs; `--check` reports drift.


## Addressing

- **Documents** (`document` argument, optional on document tools, defaults to the
  current tab): omitted, `null`, or `"@current"` — the current tab; an integer — a tab
  index from `list_documents`; a UUID string — a tab id or document id; any other
  string — an exact tab title. Tools that don't act on one document (`list_documents`,
  `get_app_info`, `list_files`, …) ignore a stray `document`.
- **Layers** (`layer` / `layers` arguments): `"@active"` — the active layer; a UUID
  string — a layer id; otherwise a layer name or a folder path such as
  `"Footer/Logo"` (a literal `/` or `\` in a name is escaped as `\/` / `\\`). A path
  matches from the root first, then as a suffix. A selector that matches more than one
  layer fails with `ambiguous` and lists candidates in `details.candidates`
  (`{id, path, kind}`): use the id.
- **Files** (`path`, `save_to`): absolute, `~/…`, or relative to the Agent folder
  (`get_app_info.agent_folder`, listed by `list_files`).

## Coordinates, colors, units

- All positions, sizes and pixel reads are in **document pixels**, origin top-left, y
  down, regardless of zoom or window size. A layer's `transform` is its unrotated box
  (`x`, `y`, `width`, `height`) with `rotation` about its center and flips.
- **Colors**: `{r, g, b}` (0–1 floats; `red`/`green`/`blue` also accepted) or a
  `"#rrggbb"` string; components outside 0–1 are clamped. Text and shape colors also take
  `"foreground"` or `"background"`, the app's palette colors.
- Angles are clockwise degrees (a shadow's light angle is Photoshop's: counterclockwise
  from the right, 90 from above). Opacity, blend amounts and similar fractions are 0–1.
- Enum values are snake_case and match loosely: case, spaces and punctuation are ignored
  (`color_burn`, `Color Burn` and `colorBurn` are one blend mode).

## Undo, batches and pending edits

Every mutating tool funnels its edit through the same undo path the UI uses, so one
agent call is one ⌘Z step (nested settings — e.g. `add_adjustment_layer` with
`settings` — still land as a single step). The result carries
`undo: {name, count, recorded}`: `name`/`count` describe the newest undo entry after
the call, and `recorded` is `true` only when this call itself added it (a no-op edit,
or `undo`/`redo` moving through existing history, records nothing). `get_history` lists
the entries `undo` and `redo` would step through.

- **`run_batch`** runs up to 200 calls, in order, as one undo step (named by `name`,
  default `"Batch (n)"`). A step is `{tool, arguments}` and acts on the batch's
  document; it can't be `undo`, `redo`, `run_batch`, `settle_pending_edits`,
  `new_document`, `open_document`, `close_document`, `select_document`,
  `duplicate_document` or `revert_document`. The batch stops at the first failing step
  and returns its error with `details.step`, `details.tool`, `completed` and the earlier
  steps' `results`; those steps stay applied (still one undo step) unless
  `rollback_on_error` is true. Files steps wrote stay written. It refuses to start
  (guard `can_use_history`) while the app holds the history or an edit open. While it
  runs, the app's own edits, undo, saves and opens wait (their commands are disabled),
  so none lands inside the batch's step. If one gets in anyway while a step awaits (a
  save, an export, reading a file), the batch stops after that step (guard
  `history_busy`) and does not roll back, since that would undo the app's edit too.
- **Pending app edits.** While the app has something open that holds the document — a
  free transform, text being typed, a crop, gradient, lasso or shape, a filter, Levels or
  Hue/Saturation dialog, an adjustment layer's settings panel, moved pixels — editing
  tools refuse with guard `can_edit_layers` (whole-document tools such as `resize_image`
  and `crop` too). `settle_pending_edits` with `mode: commit` or `cancel` finishes or
  drops them (and dismisses a rename, the color picker, dialogs and the app's error
  alerts). It returns `settled`, `failed` (`{edit, message}`; no alert is shown),
  `can_edit_layers` and `blocking_reason`. Each committed edit is its own undo step, so
  one call may record several. Text or a crop that fails to commit stays open (settle
  again with `cancel`); a gradient or pixel move that fails is discarded, as in the app.
  Imports and long operations are left to finish: wait and retry.
- **`undo` / `redo`** refuse (guard `can_use_history`) while something in the app holds
  the history, such as text being typed or a layer being renamed, and (guard
  `history_busy`) while the app holds an edit open, such as an adjustment's settings.

Tool calls are serialized on one queue: at most `MCPSettings.maxQueuedCalls` (64) may
be queued or running across every connected client at once, run strictly in arrival
order, one at a time, so one document mutation is never interleaved with another —
whichever client sent it. A call beyond that limit fails fast with a `busy` error
rather than piling up. A call cancelled before it finishes also fails with `busy`.

## Previews and export

`render_document`, `render_region`, `render_layer`, `get_layer_bounds`,
`get_pixel_color` and `sample_colors` are **read-only** — calling them changes nothing —
and the three render tools return an **image content block first**, then the usual
JSON block (`width`, `height`, `scale`, `scale_x`, `scale_y`, `document_width`,
`document_height`, `format`, `bytes`). They render in memory only.

- `max_size` (all render tools, 16–4096, default 1024) is the longest side of the
  *returned* image; a larger render is scaled down to fit (never up).
- `get_layer_pixels` returns a layer's own raster (or its mask as gray) the same way;
  with `save_to` it also writes the full-size PNG, which makes it the one inspection tool
  that can write a file.
- Files are written by `export_image` (PNG/JPEG, `max_size` up to 30,000, `scale`
  0.05–4, a `region`), `save_document` and `save_document_as`,
  `export_smart_object_contents` and `get_layer_pixels`' `save_to`. None of them replaces
  an existing file (other than a document's own, when it is saved) unless the call passes
  `overwrite: true`; otherwise it fails with `io_error` / `details.code: "file_exists"`.
- Call `render_document` after compositing changes to see the result — there are no
  progress notifications for a long tool call in this stateless transport; the POST
  just stays open until the call finishes.

## Locks and Photoshop placeholders

`set_layer_locks` sets Photoshop's four locks; tools honor them as Photoshop does:

- **position** blocks moving and transforming the layer (not its place in the stack);
- **pixels** blocks changing its pixels: painting, filters, rasterizing, merging,
  distorting, applying a mask, replacing a smart object's contents;
- **all** (Lock All) blocks every change but showing, hiding and selecting it; effects,
  adjustment settings, text and shape styles, and masks (except `apply_layer_mask`)
  refuse only Lock All;
- **transparency** is kept and written back to Photoshop files.

A folder's locks hold everything inside it: `get_layer`/`get_document` report a layer's
own `locks` and its `effective_locks` (with its folders'), and a refusal (guard
`layer_locked`) names the holder in `details.locked_by_id`. New layers land above the
outermost Lock-All folder instead of inside it, and a layer inside one can't change its
own locks (guard `locked_by_folder`).

Layers of kind `placeholder` are Photoshop layers Compositor can't show (an adjustment or
fill it doesn't model, say), kept hidden and without pixels only so they are written back;
pixel and settings tools refuse them (guard `placeholder`).

## Text and fonts

Text layers stay live: `set_text`, `set_text_style` and `fit_text` redraw them. Point text
keeps its anchor through an edit, as in Photoshop — the left end, middle or right end of
its first baseline, as it is aligned — so a centered line that gets longer grows both
ways; changing the alignment re-aligns the text about that point. Paragraph text keeps its
box's top-left corner. Imported Photoshop text is placed where Photoshop anchored it the
first time it is edited.

Letters colored on their own in the app keep their colors through a change of font, size,
spacing or box. New text from `set_text` (or `content` in `set_text_style`), or a new
`color` for the whole text, colors all of it, as the app's color swatch does. A Photoshop
save writes those letters as style runs in their colors.

A project open in Compositor follows its `.comp` package on disk: when another app or a
script rewrites it, the document reloads in place (asking first if it has unsaved changes).
Saves made through these tools don't count as such a change and keep the undo history.

A font that isn't installed is drawn with a substitute: call `check_fonts` (or read
`document_missing`) before editing imported text, and `list_fonts` for PostScript names.

## Photoshop files

`open_document` opens an 8-bit RGB `.psd` or Large Document `.psb` without dialogs (a
file holding only a background opens from its merged image, as one layer); `conversions` lists what
Compositor converted (per layer). The file itself is never changed by opening or editing:
a document opened from a PSD has no file of its own, so `save_document` refuses (guard
`project_file`) until it is saved with `save_document_as`. Treat a client's PSD as a
template: save work under a new name. Replacing the file the document came from takes
`overwrite: true`, like any existing file.

`save_document_as` writes a `.comp` project, which keeps everything, or a layered `.psd`
(`get_app_info.features.photoshop_save`), chosen by `format` or the path's extension; a
document opened from a `.psb` is saved as a `.psd` (version 1), and a `.psb` path is
refused (`invalid_argument`). A
`.psd` saved with `set_as_current` becomes the document's working file, as in Photoshop:
`save_document` writes it again, as a `.psd`. Layers Compositor hasn't changed go back as
Photoshop stored them; edited text, shapes, smart objects, effects and adjustment layers
are rewritten from Compositor's settings ([psd-export.md](psd-export.md) has the rules). A
Photoshop save returns `warnings`, one `{layer, message, lossy}` for each thing the file
holds differently from the document. A lossy one (an adjustment Photoshop has no layer
for, such as Grain, a blur or Profile, written as pixels; a clipping applied to pixels or
left out; a curve resampled to Photoshop's 16 points; a shape saved as pixels or as a
plain path; the file's alpha channels or an adjustment's vector mask left out) refuses the
save with guard `lossy`, the items in `details.warnings` and nothing written, unless the
call passes `allow_lossy: true`. Other warnings are notes and never stop a save. A
document past what a `.psd` holds (30,000 px a side; Compositor writes canvases up to its
200-megapixel surface limit, 32,767 layers, 4 GB of layer data) is refused with guard
`photoshop_limits`; save a `.comp` instead.

## Error codes

Every failure comes back as a normal (non-JSON-RPC-level) tool result with
`isError: true` and body `{"ok": false, "error": {code, message, guard?, hint?,
details?}}`, so an agent can read and react to it without special-casing transport
errors. `hint` says what to do next; `details.field` names a bad argument.

| `code` | Meaning | Recovery |
|---|---|---|
| `invalid_argument` | An argument is missing, the wrong type, or out of range; `details.field` names it (and `min`/`max` for a range). | Fix the argument. |
| `not_found` | The tool, document, layer, profile or file named does not exist. | `list_documents`, `get_document`, `list_files` or `list_profiles` show what does. |
| `ambiguous` | A selector matched more than one thing; `details.candidates` lists them. | Use a candidate's id. |
| `precondition_failed` | The document isn't in a state that allows the call; `guard` names the check (see below). | Follow the hint. |
| `busy` | Something else is running (an import, a long operation, a full call queue), a macOS prompt is waiting, or the call was cancelled. | Wait, then retry. |
| `io_error` | Reading or writing a file failed, a file already exists, or macOS denied access. | See `details.code`. |
| `unsupported` | The request is understood but not supported by this version (a PSB smart object's contents, an EPS smart object, a profile made for raw files). | Use another format or profile. |
| `internal` | An unexpected failure inside Compositor. | Report it; retrying rarely helps. |

`details.code` narrows a failure:

| `details.code` | With | Meaning and recovery |
|---|---|---|
| `file_exists` | `io_error` | Something is already at the path. Pass `overwrite: true` to replace it, or choose another path. |
| `folder_access_denied` | `io_error` | macOS denied Compositor access to the protected location the path is in (`details.root`, e.g. `documents`; `details.path`, spelled as a successful call would report it). The owner turns Compositor on in System Settings > Privacy & Security > Files and Folders (or grants Full Disk Access), or the file is copied to the Agent folder. Retrying without that fails the same way. |
| `folder_access_pending` | `busy` | A macOS permission prompt for that location is waiting on this Mac (or the location, such as a network volume, isn't answering), so the call stopped after about two seconds instead of waiting. The owner approves the prompt; then retry. |
| `folder_access_unchecked` | `list_files` `skipped` | The listing's two seconds for asking macOS ran out before it reached that folder. List the folder on its own. |
| `not_a_profile`, `raw_only`, `camera_specific`, `unsupported`, `too_large`, `malformed`, `unreadable`, `changed`, `not_loaded`, `write_failed` | profile tools | Why a profile file can't be imported or used; see [Profiles](#profiles). |

Common guards (`precondition_failed` unless noted):

| `guard` | Meaning | Recovery |
|---|---|---|
| `document` | The tab has no document. | `new_document` or `open_document`. |
| `can_edit_layers` | Something open in the app holds the document (`message` says what). | `settle_pending_edits`, or finish it in the app. With `busy`: an import or long operation; wait. |
| `can_start_project_operation`, `can_switch` | A save, open, import or edit in the app blocks the save, export or tab switch. | Settle or wait, then retry. |
| `max_tabs` | 32 documents are open. | Save and `close_document` one. |
| `max_layers` | The call would pass 10,000 layers (folders count). | Delete, merge or flatten layers. |
| `pixel_budget` | Past 30,000 px a side, 200 megapixels in one surface (a canvas, export, filter target, text box or shape), or, for layers brought in, the document's pixel budget (`get_app_info` `limits`). | Use a smaller canvas, image, region or scale. |
| `layer_locked` | A lock (the layer's or a folder's, `details.locked_by_id`) blocks the edit. | Unlock the holder with `set_layer_locks`. |
| `locked_by_folder` | The layer is in a Lock-All folder, so its own locks can't change. | Unlock the folder first. |
| `placeholder` | A Photoshop layer kept only to write back. | Leave it; add a layer of your own for the effect. |
| `history_busy`, `can_use_history` | The app holds the history or an edit open. | `settle_pending_edits`, then retry. |
| `unsaved_changes` | Closing or reverting would lose changes. | Save first, or pass `discard_changes: true`. |
| `project_file` | The document has no file to save or revert to (new, duplicated, or opened from a PSD or image). | `save_document_as`; replacing the file it came from takes `overwrite: true`. |
| `lossy` | Saving as `.psd` would change layers Photoshop can't hold; `details.warnings` lists them. Nothing was written. | Pass `allow_lossy: true` to save with those changes, or save a `.comp`. |
| `photoshop_limits` | The document is past what a Photoshop file holds. | Save a `.comp` project. |
| `has_pixels`, `has_mask`, `selection`, `is_text`, `is_shape`, `is_smart_object`, … | The layer or document lacks what the tool works on. | The hint names the tool that makes it. |
| `not_smart_object` | Painting, filters or new pixels on a smart object would drop its embedded file. | `rasterize_layer` first, or change the contents with `export_smart_object_contents` and `replace_smart_object_contents`. |

A handful of failures happen before any JSON-RPC body is read, at the HTTP layer, and
come back as plain HTTP status codes instead: `401` (the access token is missing or not
the current one, checked before everything below except the head's size and framing; it
comes with `WWW-Authenticate: Bearer realm="Compositor"` — set the client up through the
bridge, which sends the current token by itself, or again with the line Compositor ›
Settings… copies after **Regenerate token…**; see [Troubleshooting](#troubleshooting)),
`403` (an `Origin` header is present),
`421` (`Host` isn't loopback on the bound port), `406` (`Accept` doesn't allow JSON),
`415` (wrong `Content-Type`), `400` (unsupported `MCP-Protocol-Version`, unparsable
JSON-RPC, a request id that's neither a string nor a number, a `Content-Length` that
isn't one plain number, or a request that isn't HTTP), `501` (a `Transfer-Encoding`
body: send `Content-Length`), `405` (GET/DELETE), `413` (request over 32 MB), `431`
(a request head over 64 KB), `408` (a request not received whole within 30 seconds of
its first byte), `503` (32 connections are already open, or the listener is up but the
transport isn't wired yet — momentary, at startup only).

## Tool reference

One line per tool, grouped by domain: its name, the first sentence of its description,
then its arguments (required first; every document tool also takes `document`).
[Tool notes](#tool-notes) has the detail that descriptions leave out.

<!-- tools:begin -->
<!-- Generated from MCPToolRegistry by MCPToolDocsTests; don't edit by hand. To update, run:
     TEST_RUNNER_COMPOSITOR_WRITE_DOCS=1 xcodebuild test … -only-testing:CompositorTests/MCPToolDocsTests -->

**Documents**

- `list_documents` — Lists the open document tabs: index, tab and document ids, title, whether it is current, canvas size, and unsaved changes.
- `get_document` — Describes a document: canvas, format and files, the layer tree, selection, guides, undo state, palette, and capabilities (which edits can run now, and what blocks them). — optional `detail`
- `get_app_info` — Reports Compositor's version, MCP endpoint, limits, Agent folder, formats and features, and whether macOS lets it into each protected location (folder_access).
- `select_document` — Switches the visible document tab. — `document`
- `new_document` — Creates a document in a new tab and makes it current, with one layer, 'Layer 1', transparent or filled with 'fill'. — optional `fill`, `height`, `name`, `resolution`, `width`
- `open_document` — Opens a .comp project, a Photoshop .psd or .psb (8-bit RGB) or an image (PNG, JPEG, HEIC, TIFF, camera raw, SVG as pixels) in a new tab, without dialogs. — `path`; optional `select`
- `save_document` — Saves the document to its own file (the .comp it was opened from, or the .comp/.psd it was last saved as) in that file's format, and marks it saved. — optional `allow_lossy`
- `save_document_as` — Saves the document to a file: a Compositor project (.comp), which keeps everything, or a layered Photoshop file (.psd). — `path`; optional `allow_lossy`, `format`, `overwrite`, `set_as_current`
- `export_image` — Renders the composite, or a region of it, to a PNG or JPEG file, resized by 'scale' and scaled down to fit 'max_size'. — `path`; optional `background`, `format`, `max_size`, `overwrite`, `quality`, `region`, `scale`
- `close_document` — Closes a document's tab; one with unsaved changes is refused (guard unsaved_changes) unless discard_changes is true. — optional `discard_changes`
- `duplicate_document` — Copies the document into a new tab and makes it current: the same canvas, layers, guides and selection under new ids, with no file and no undo history (it counts as unsaved). — optional `name`
- `revert_document` — Reloads the document from its file in the same tab, dropping every change and the undo history. — optional `discard_changes`
- `settle_pending_edits` — Commits (mode commit) or cancels an edit in progress in the app that blocks tools: a transform, typed text, a crop, gradient, lasso or shape, a filter or adjustment dialog, moved pixels. — `mode`

**Render and inspect**

- `render_document` — Renders the document's composite as export draws it and returns it as an image, then JSON: width, height, scale, document size, format and bytes. — optional `background`, `format`, `max_size`, `quality`
- `render_region` — Renders part of the composite at full detail, a rectangle or the selection's bounds, and returns it as an image, then JSON with the region rendered. — `region`; optional `background`, `format`, `max_size`, `padding`, `quality`
- `render_layer` — Renders one layer, or a folder's contents, by itself, even when hidden, with nothing below it and no clipping base, and returns it as an image. — `layer`; optional `background`, `crop`, `format`, `include_effects`, `include_mask`, `max_size`, `quality`
- `get_layer_bounds` — Reports where a layer sits in document pixels: transform, corners, upright bounds, effects_bounds, content_bounds around its visible pixels, mask placement, and text metrics. — `layer`; optional `content`
- `get_pixel_color` — Reads one document pixel's color as {r, g, b, a} in 0–1 and hex, from the composite or (source layer) from the layer's own pixels. — `x`, `y`; optional `layer`, `source`
- `sample_colors` — Reads up to 256 document pixels' colors at once, as get_pixel_color reports them, in the order given. — `points`; optional `layer`, `source`

**Files**

- `list_files` — Lists a folder's files and folders (default the Agent folder) in name order with name, path, size and is_directory; recursive walks subfolders. — optional `extensions`, `limit`, `path`, `recursive`
- `get_file_info` — Describes a file or folder without opening it: exists (a missing path is no error), is_directory, size, uti, and for an image the image_size it imports at. — `path`
- `reveal_in_finder` — Shows a file or folder selected in Finder (default the Agent folder), so the user can see what you made. — optional `path`

**Layers**

- `get_layer` — Describes one layer as get_document does: id, name, path, kind, visibility, opacity, blending, clipping, transform, locks and effective_locks, and a folder's children. — `layer`; optional `detail`
- `add_blank_layer` — Adds an empty transparent layer above the active layer (at the top of it when it is a folder), at the top of 'parent' (null: the top level), or directly above 'above'. — optional `above`, `name`, `parent`
- `add_image_layer` — Imports an image file (PNG, JPEG, HEIC, TIFF, camera raw, or SVG drawn into pixels) as a new layer above the active layer, centered on 'center' (default the canvas center). — `path`; optional `center`, `fit`, `name`
- `add_group` — Adds an empty folder above the active layer (inside it when it is a folder). — optional `name`
- `rename_layer` — Renames a layer or folder. — `layer`, `name`
- `set_layer_visibility` — Shows or hides a layer or folder, even a locked one. — `layer`, `visible`
- `set_layer_opacity` — Sets a layer's or folder's opacity from 0 to 1, its effects included. — `layer`, `opacity`
- `set_layer_fill_opacity` — Sets a layer's fill opacity (Photoshop's Fill) from 0 to 1: its own pixels' opacity, apart from its effects. — `layer`, `fill_opacity`
- `set_layer_blend_mode` — Sets a layer's blend mode; names match loosely (color_burn, Color Burn). — `layer`, `mode`
- `set_layer_locks` — Turns layer locks on or off: position (moving, transforming), pixels (painting, rasterizing, merging), all (every change but showing, hiding and selecting) and transparency (kept for PSD). — `layer`; optional `all`, `pixels`, `position`, `transparency`
- `delete_layers` — Deletes layers, a folder with its contents. — `layers`
- `duplicate_layer` — Duplicates a layer, a folder with its contents, directly above it and selects the copy. — `layer`; optional `name`
- `layer_via_copy` — Copies a pixel layer's pixels inside the selection to a new layer, in place above it (Layer via Copy); without a selection the whole layer is duplicated. — `layer`
- `reorder_layer` — Moves a layer to a sibling index inside its folder, 0 being the bottom. — `layer`, `index`
- `place_layer` — Moves a layer or folder into a folder or out of one. — `layer`; optional `above`, `bottom`, `parent`
- `group_layers` — Collects layers into a new folder, placed where the topmost of them was. — `layers`; optional `name`
- `ungroup_layer` — Removes a folder, moving its contents into its parent at its place in the stack, in order, and selects them. — `layer`
- `set_clipping_mask` — Clips a layer to the layer below it, or unclips it (Photoshop's clipping mask). — `layer`, `enabled`
- `select_layers` — Sets the active layer and multi-selection (what merge_layers and the app act on), and whether edits in the app target the active layer's pixels or its mask. — `layers`; optional `active`, `target`
- `merge_layers` — Merges layers into one pixel layer, baking blending, masks, clipping and adjustments: one layer merges down, several merge together, and a folder merges its contents. — optional `layers`
- `flatten_image` — Flattens the document into one full-canvas pixel layer, 'Background', as export_image renders it. — optional `discard_hidden`
- `rasterize_layer` — Turns a text or shape layer into the plain pixels it shows now, keeping its effects and mask. — `layer`

**Transforms**

- `move_layer` — Moves a layer, or a folder with its contents, by dx, dy document pixels; a linked mask moves with it and an unlinked one stays put. — `layer`, `dx`, `dy`
- `set_layer_transform` — Sets a layer's position, size, rotation and flips; omitted fields keep their values. — `layer`; optional `anchor`, `flip_x`, `flip_y`, `height`, `rotation`, `width`, `x`, `y`
- `set_layer_scale` — Scales a layer to a percentage of its own pixels (100 is 1:1), keeping its angle and flips. — `layer`, `percent`; optional `keep_center`
- `scale_layer_to_fit` — Scales and moves a layer so its upright box fits a rectangle: contain fits inside and cover fills it, keeping the aspect ratio, and stretch fills it exactly. — `layer`, `rect`, `mode`; optional `anchor`
- `rotate_layer` — Turns a layer clockwise by 'degrees' (relative, the default) or to that angle, about its middle or 'around'. — `layer`, `degrees`; optional `around`, `relative`
- `flip_layer` — Mirrors layers horizontally or vertically: one about its own middle, several (or a folder's contents) about the middle of their box. — `layers`, `axis`
- `distort_layer` — Moves a layer's four corners (top-left, top-right, bottom-right, bottom-left) and resamples its pixels and linked mask into that shape. — `layer`, `corners`
- `align_layers` — Lines up the same edge or middle of layers with the canvas, the selection or their combined box. — `layers`, `edge`, `to`; optional `use_content_bounds`
- `distribute_layers` — Spaces three or more layers along an axis, in order of their middles: equal gaps with the first and last fixed, or gaps of 'spacing' pixels from the first. — `layers`, `axis`; optional `spacing`

**Canvas and guides**

- `resize_canvas` — Changes the canvas size without scaling anything (Canvas Size): layers and guides move with the anchor. — `width`, `height`; optional `anchor`, `fill`, `relative`
- `resize_image` — Scales the whole image, every layer and mask (Image Size), to width and height, one of them (keeping the aspect ratio) or percent. — optional `height`, `percent`, `resolution`, `sampling`, `width`
- `set_resolution` — Sets the pixels per inch stored with the document, changing no pixels. — `resolution`
- `crop` — Crops the canvas to a rectangle, rounded to whole pixels, as the Crop tool does: layers keep all their pixels, and a rectangle past the canvas extends it with transparency. — `rect`
- `trim_canvas` — Crops the canvas to the box around pixels that aren't transparent, plus 'padding', measuring every shown layer or only 'layers'. — optional `layers`, `padding`
- `flip_canvas` — Mirrors the whole document horizontally or vertically: every layer and mask, the selection and the guides. — `axis`
- `add_guide` — Adds a horizontal guide at a document y, or a vertical one at an x, and returns its id. — `axis`, `position`
- `remove_guide` — Removes one guide by its id; refused while guides are locked in the app. — `guide_id`
- `clear_guides` — Removes every guide, even while guides are locked.
- `list_guides` — Lists the guides as {id, axis, position}, and whether guides are shown and locked in the app.

**Adjustment layers**

- `add_adjustment_layer` — Adds an adjustment layer of 'kind' above the active layer, optionally named, clipped to the layer below (clip_to_below) and configured with 'settings' as set_adjustment takes them, as one step. — `kind`; optional `clip_to_below`, `name`, `settings`
- `set_adjustment` — Changes an adjustment layer's settings; only what is given changes. — `layer`, `settings`

**History and batches**

- `undo` — Undoes the last 'steps' edits (default 1) as ⌘Z does, stopping when nothing is left, and returns undone and the undo state. — optional `steps`
- `redo` — Redoes the last 'steps' undone edits (default 1) as ⇧⌘Z does, and returns redone and the undo state; refused when undo is. — optional `steps`
- `get_history` — Lists undo_names (what undo steps back through, next first) and redo_names, their counts, whether undo and redo can run now, and whether there are unsaved changes.
- `run_batch` — Runs up to 200 tool calls in order as one undo step named 'name' (default "Batch (n)"), each {tool, arguments} on this batch's document. — `steps`; optional `name`, `rollback_on_error`

**View, tools and palette**

- `zoom_to_fit` — Zooms and centers the canvas to fit the window, as ⌘0 does, and returns the zoom (1 is 100%).
- `set_zoom` — Sets the canvas zoom (1 is 100%, 2 is 200%), clamped to 0.001–32 (clamped says so), keeping 'anchor', a document pixel, where it is on screen. — `zoom`; optional `anchor`
- `select_tool` — Selects a tool in the tool rail, ready for the user's clicks; crop starts a whole-canvas crop that holds other edits. — `tool`
- `bring_app_to_front` — Brings Compositor's window to the front so the user sees your work; macOS may keep an app the user is typing in in front.
- `set_palette_colors` — Sets the foreground and/or background color, the app's swatches that brushes, type, shapes and fills use. — optional `background`, `foreground`

**Layer effects**

- `set_layer_effects` — Sets a layer's effects: stroke, shadow, color_overlay, inner_shadow, outer_glow and inner_glow. — `layer`, `effects`; optional `merge`
- `add_layer_effect` — Adds one effect at the app's defaults (a new stroke or color overlay takes the background color), then applies 'settings'; on an effect the layer has, only the settings change. — `layer`, `kind`; optional `settings`
- `remove_layer_effect` — Removes one effect from a layer; not_found when it has none of that kind. — `layer`, `kind`
- `set_layer_effect_enabled` — Shows or hides one of a layer's effects, keeping its settings. — `layer`, `kind`, `enabled`

**Selection**

- `select_rect` — Selects a rectangle (Rectangular Marquee), combined with the current selection by mode and clipped to the canvas. — `rect`; optional `antialiased`, `mode`
- `select_ellipse` — Selects the ellipse filling a rectangle (Elliptical Marquee), combined with the current selection by mode and clipped to the canvas. — `rect`; optional `antialiased`, `mode`
- `select_polygon` — Selects the polygon through 3 or more points (Polygonal Lasso), combined with the current selection by mode and clipped to the canvas. — `points`; optional `antialiased`, `mode`
- `select_all` — Selects the whole canvas.
- `select_none` — Removes the selection, so edits apply to whole layers again.
- `invert_selection` — Selects everything on the canvas outside the current selection; needs a selection.
- `select_by_color` — Selects pixels similar in color to the one at (x, y) (Magic Wand), read from the active layer or with sample_all_layers from the composite. — `x`, `y`; optional `contiguous`, `mode`, `sample_all_layers`, `sample_size`, `tolerance`
- `select_object` — Selects the object Vision finds under (x, y) (Object Selection); nothing found leaves no selection in replace mode. — `x`, `y`; optional `edge_offset`, `mode`, `sample_all_layers`
- `select_subject` — Selects the main subject Vision finds in the composite; when none is found the selection stays and found is false. — optional `mode`
- `load_layer_selection` — Selects a layer's pixels that are at least 50% opaque, ignoring its mask, or with source mask the white (revealed) areas of its mask. — `layer`; optional `mode`, `source`
- `modify_selection` — Expands, contracts or feathers the selection by 'amount' pixels (feather up to 250). — `operation`, `amount`
- `transform_selection` — Scales the selection outline about 'around' (default its center) and moves it by dx, dy; pixels stay put. — optional `around`, `dx`, `dy`, `scale_x`, `scale_y`
- `move_selected_pixels` — Moves a layer's selected pixels by whole pixels, leaving transparency behind (or with duplicate a copy), and moves the outline with them. — `layer`, `dx`, `dy`; optional `duplicate`
- `get_selection` — Reports the selection: whether it exists or is empty, bounds, feather, antialiasing, and with include_path its outline as SVG path data (up to 256 KiB, then path_truncated). — optional `include_path`

**Painting and pixels**

- `fill_selection` — Fills the selection (the whole layer without one) on a layer's pixels, or its mask with target mask, with a color, the foreground or the background. — `layer`; optional `color`, `target`, `with`
- `clear_selection` — Clears a layer's selected pixels to transparency; on its mask (target mask) the selection fills with the app's mask background, white unless swapped. — `layer`; optional `target`
- `invert_pixels` — Inverts a layer's colors, keeping transparency, or its mask with target mask, inside the selection when there is one. — `layer`; optional `target`
- `stroke_path` — Paints one brush stroke through 'points' on a layer's pixels, or its mask with target mask, with this call's brush and no smoothing, inside the selection when there is one. — `layer`, `points`; optional `brush`, `clone`, `heal_mode`, `mode`, `target`
- `draw_gradient` — Draws a linear or radial gradient from start to end on a layer's pixels, or its mask with target mask, inside the selection when there is one. — `layer`, `start`, `end`; optional `colors`, `opacity`, `reversed`, `shape`, `style`, `target`
- `get_layer_pixels` — Returns a layer's own pixels (before opacity, mask, effects and blending), or with target mask its mask as gray, as a PNG image scaled down to max_size, then JSON with the sizes and transform. — `layer`; optional `max_size`, `overwrite`, `save_to`, `target`
- `set_layer_pixels` — Replaces a layer's pixels with an image file, placed by 'placement'. — `layer`, `path`; optional `placement`
- `paste_image_into_layer` — Draws an image file into a layer's pixels with its top-left at (x, y), one image pixel per document pixel, inside the canvas and the selection: over draws it on top, replace swaps in its pixels. — `layer`, `path`, `x`, `y`; optional `mode`
- `copy_pixels` — Copies a layer's selected pixels (all of them without a selection), or with merged the visible composite (the canvas without a selection), to Compositor's clipboard and the system pasteboard. — optional `layer`, `merged`
- `paste_pixels` — Pastes the clipboard as a new layer above the active layer: pixels copied in Compositor go back where they came from, other images are centered, or x and y place the top-left. — optional `x`, `y`

**Filters**

- `apply_filter` — Runs a filter on a layer's pixels, inside the selection when there is one, without a panel. — `layer`, `kind`; optional `settings`
- `apply_levels` — Applies Levels to a layer's pixels, inside the selection when there is one: one channel's black, gamma, white, output_black and output_white, or 'ranges' for all four (rgb, red, green, blue). — `layer`; optional `auto`, `settings`
- `apply_hue_saturation` — Applies Hue/Saturation to a layer's pixels, inside the selection when there is one. — `layer`, `settings`
- `content_aware_fill` — Fills the selection on a layer's pixels with texture from the pixels around it (Content-Aware Fill); needs a selection that leaves enough of the layer to copy from. — `layer`
- `remove_background` — Masks out a layer's background, keeping the subject Vision finds, with a layer mask that is black over the background; nothing is erased, and a mask already there is combined. — `layer`; optional `matte_contrast`, `quality`, `refine_edges`, `shift_edge`

**Masks**

- `add_layer_mask` — Adds a mask to a layer or folder: reveal_all (white), hide_all (black), from_selection or hide_selection. — `layer`; optional `kind`
- `set_mask_enabled` — Turns a layer's mask on or off, keeping its pixels. — `layer`, `enabled`
- `set_mask_linked` — Links a layer's mask to it, so they move and transform together, or unlinks it, so the mask stays put on the document. — `layer`, `linked`
- `delete_layer_mask` — Deletes a layer's mask, showing the whole layer again. — `layer`
- `apply_layer_mask` — Applies a layer's mask to its pixels, making what it hides transparent, and removes it. — `layer`
- `copy_layer_mask` — Copies one layer's mask to another, replacing any mask it has, where the mask sits on the document. — `from`, `to`

**Profiles**

- `list_profiles` — Lists the Lightroom and Camera Raw profiles Compositor can apply as a Profile adjustment layer, installed and imported, with id, group, fidelity and hidden counts. — optional `group`, `include_unusable`, `limit`, `offset`, `query`, `refresh`
- `import_profile` — Imports Lightroom or Camera Raw profiles (.xmp files with PresetType Look), a file or a folder searched recursively (up to 1,000 files), into Compositor's profile library. — `path`

**Text and fonts**

- `add_text_layer` — Adds a live text layer: point text as big as its text, or paragraph text wrapping in style.box_size, with its box's 'anchor' point at (x, y). — `text`, `x`, `y`; optional `anchor`, `max_width`, `name`, `style`
- `set_text` — Replaces a text layer's text, keeping its style. — `layer`, `text`
- `set_text_style` — Changes a text layer's style fields, in the form get_layer reports under text: font_name, font_size, color, alignment, tracking, leading, box_size (null makes point text), horizontal_scale, content. — `layer`, `style`
- `fit_text` — Shrinks a point-text layer's type (never grows it) to the largest size, in 0.1 px steps, whose text is at most max_width document pixels wide. — `layer`, `max_width`
- `get_text_metrics` — Measures a text layer, or 'text' in a 'style', as Compositor lays it out. — optional `layer`, `style`, `text`
- `list_fonts` — Lists installed fonts by family: postscript_name (what font_name takes), family, style, weight and italic, filtered by query; total and truncated say what limit left out. — optional `limit`, `query`
- `check_fonts` — Checks PostScript font names: whether each is available, or the substitute drawn instead (family_match when from the same family), and lists the document's text layers whose font is missing. — optional `names`

**Shapes**

- `add_shape` — Adds a live shape layer: a rectangle or ellipse filling rect, or a line from start to end, in color (default the foreground). — `kind`; optional `color`, `corner_radius`, `end`, `line_width`, `name`, `rect`, `start`, `stroke`
- `set_shape_style` — Changes a live shape layer's color, corner_radius, line_width or stroke (patched; null removes it). — `layer`; optional `color`, `corner_radius`, `line_width`, `stroke`

**Smart objects**

- `place_smart_object` — Places a file as a new smart object, which keeps the file whole so it can be replaced later: PNG, JPEG, TIFF, GIF, SVG, PDF or PSD (not PSB or EPS), up to 512 MiB. — `path`; optional `center`, `fit`, `fit_rect`, `name`
- `replace_smart_object_contents` — Replaces a smart object's contents with a file and draws them in the object's placement (its quad) as fit says. — `layer`, `path`; optional `fit`
- `get_smart_object_info` — Describes a smart object's contents: file_type, file_name, bytes (null when not held), natural_size, quad (where they are placed, in document pixels), embedded and contents_revision. — `layer`
- `export_smart_object_contents` — Writes a smart object's contents to a file exactly as the document holds them (the placed PNG, PDF or PSD), to edit elsewhere and bring back with replace_smart_object_contents. — `layer`, `path`; optional `overwrite`
<!-- tools:end -->

## Tool notes

What the descriptions leave out, by domain. Each tool's input schema, from `tools/list`,
has the ranges its arguments take.

**Documents.** `get_document` reports each layer's kind, visibility, opacity, fill,
blend mode, clipping, transform, `locks` and `effective_locks`, and `capabilities`
(`can_edit_layers`, `can_edit_pixels`, `blocking_reason`); `detail: "full"` adds each
layer's drawn box, content bounds, effects, text, shape and adjustment settings, smart
object and mask details. `get_app_info` reports `limits` (open documents, canvas side,
pixels in one surface, the document pixel budget, layers, undo steps, render and
export sizes), `agent_folder`, `features`
(formats opened, saved and exported), `folder_access` / `folder_access_detail` (see
[Granting folder access](#granting-folder-access)), and `logs` (`{enabled, verbose, directory}`
of the [diagnostic log](logging.md), never its contents). `open_document` returns `document_id`,
`tab_index`, `already_open` (a file already open, as a project or as the PSD or image a
document came from, selects that tab) and `conversions`; a path without an extension that
names nothing is tried with `.comp`. `revert_document` gives a PSD or image document a new
`document_id`. New and duplicated documents count as unsaved.

**Render and inspect.** `render_region` takes a rectangle or `"selection"`, plus
`padding`; `render_layer` draws one layer (a folder's contents) alone, even hidden, with
`crop: layer` (its drawn box, effects included, even past the canvas) or `canvas`.
`get_pixel_color` floors fractional coordinates; with `source: layer` it reads the
layer's own pixel (before opacity, mask, effects and blending) and says whether the point
is `inside` the layer. `get_layer_bounds` reports `bounds`, `effects_bounds`,
`content_bounds` and `pixel_content_bounds`; `content: false` skips the pixel scan.

**Files.** `list_files` lists in name order; hidden and `.tmp` files are skipped, `.comp`
projects and symbolic links are files (a link reports its target's size and is never
entered), and a `.comp` can't be listed itself. With `recursive`, folders macOS hasn't let
Compositor into are listed but not entered and named in `skipped` with `code`
(`folder_access_denied`, `folder_access_pending`, or `folder_access_unchecked` when the
listing's shared two seconds ran out before it got there). At most `limit` (1–10,000)
entries come back, and at most 100,000 items are looked at; `truncated` says more were
left out. `get_file_info` reports `exists`, `is_directory`, `size`, `uti` and an image's
`image_size` with its EXIF orientation applied.

**Layers.** Tools that add layers (`add_blank_layer`, `add_image_layer`, `add_group`,
`duplicate_layer`, `layer_via_copy`, `paste_pixels`, and the text, shape, adjustment and
smart-object creators) never put one inside a Lock-All folder: it goes above the
outermost such folder instead. `add_image_layer`'s `fit` changes only the
layer's size, never its pixels. `set_layer_fill_opacity` is written to PSD; Compositor
draws it on layers without effects (a layer with effects is drawn at full fill for now).
`set_layer_locks`: see [Locks](#locks-and-photoshop-placeholders). `delete_layers` refuses
a Lock-All layer or a folder holding one, and bakes layers clipped to a deleted one (their
pixels must be unlocked). `merge_layers` merges one layer down onto the pixel layer below,
several together, or a folder's contents, refusing pixel-locked layers; it reports
`action`. `flatten_image` keeps guides and the selection. `rasterize_layer` keeps effects,
mask and settings.

**Transforms.** `set_layer_transform` with `anchor` places that of nine points (as
Photoshop's reference point) and keeps it through a resize or turn. A folder can only be
moved: `x`, `y` (and `anchor`) place the box around the layers shown in it — as
`align_layers` and `get_layer_bounds` measure it, not the folder's own canvas-sized
transform — and the result adds that box as `bounds`. Live shapes redraw at their new size
(so repeated `set_layer_scale` percentages start from the new pixels). `scale_layer_to_fit`
with `stretch` at an angle that isn't a multiple of 90° solves the width and height whose
upright box is the rectangle; one too far from square for the angle (near 45°) is refused.
`flip_layer` leaves the layer selection alone and flips only shown layers with pixels.
`distort_layer` refuses position- or pixel-locked layers. Every transform refuses a
position lock, the layer's or a folder's.

**Canvas and guides.** `resize_canvas`'s `anchor` is 0–8 (top-left to bottom-right in
rows, 4 the center) or a name such as `"top_left"`; with `relative`, negative values
shrink. `resize_image` keeps live text and shapes editable (a turned one scaled unevenly
becomes pixels) and resamples other pixels with `sampling` (`nearest`, `smooth`, `high`);
the same size and resolution record nothing. `crop` and `trim_canvas` never delete
pixels: layers keep what falls outside. `trim_canvas` counts a named layer even when
hidden and only what lies on the canvas. Guides: at most 1000; `add_guide` and
`remove_guide` refuse while guides are locked in the app (View > Lock Guides), and
`clear_guides` works regardless. While the Crop tool holds a crop, whole-document tools
refuse; `settle_pending_edits` commits or cancels it.

**Adjustment layers.** `set_adjustment`'s shorthand keys and ranges, by kind:
Hue/Saturation — `hue` (−180…180; 0–360 with `colorize`), `saturation`, `lightness`
(−100…100) for the Master range, `colorize`; Levels — `channel` (`rgb`, `red`, `green`,
`blue`), `black` (0–254), `gamma` (0.1–9.99), `white` (above black, up to 255),
`output_black`, `output_white` (0–255); Curves — `channel`, `points` `[[x, y], …]` in
0–255, 2–32 of them from x 0 to x 255 with x increasing; Exposure — `exposure` (−20…20),
`offset` (−0.5…0.5), `gamma` (0.01–9.99); Gradient Map — `shadows`, `highlights`
(colors), `reversed`; Grain — `amount` (0–100), `size` (0.5–20), `roughness` (0–100);
Gaussian Blur — `radius` (0.1–250); Motion Blur — `angle` (−90…90), `distance`
(1–2000); Add Noise — `amount` (0.1–400), `gaussian`, `monochromatic`; Black & White —
`reds`, `yellows`, `greens`, `cyans`, `blues`, `magentas` (−200…300), `tint`,
`tint_hue` (0–360), `tint_saturation` (0–100); Color Balance — `shadow_`, `mid_` and
`highlight_` `cyan_red`, `magenta_green`, `yellow_blue` (−100…100),
`preserve_luminosity`; Profile — see [Profiles](#profiles). Invert has no settings. The
full settings the tool returns patch the same way: objects merge field by field, arrays
replace, and `null` removes an optional member — `{"hsv_settings": {"adjustments":
{"reds": {"hue": 20}}}}` shifts only the reds; `levels.ranges` and `curves.channels` list
the rgb, red, green and blue channels in that order. `get_layer` reports settings in the
same form, so reading and sending them back changes nothing. Photoshop adjustment and
fill layers Compositor can't apply (kind `placeholder`) can't be changed.

**History and batches.** See [Undo, batches and pending edits](#undo-batches-and-pending-edits).

**View, tools and palette.** These change only the app: `set_zoom` (clamped to
0.001–32, reporting `clamped`), `zoom_to_fit`, `select_tool` (the app's own spellings,
such as `"spotHealing"`, work too; selecting `crop` starts a whole-canvas crop, which an
untouched switch away drops), `bring_app_to_front`, and `set_palette_colors`, which
records no undo step. While a mask is targeted, the app paints it with its own black and
white, which the owner can swap; `set_palette_colors` doesn't change them.

**Layer effects.** Fields — `stroke`: `size`, `color`, `opacity`, `inside`; `shadow`
(`drop_shadow` in `add_layer_effect`) and `inner_shadow`: `angle`, `distance`, `blur`,
`color`, `opacity`; `color_overlay`: `color`, `opacity`; `outer_glow` and `inner_glow`:
`size`, `color`, `opacity`; each also takes `enabled`. A new effect starts from the app's
defaults (a new stroke or color overlay takes the background color). Unknown fields, even set to `null`,
fail, as do values out of range, naming the field. Effects refuse only Lock All.

**Selection.** `mode` is `replace`, `add` or `subtract`; outlines are clipped to the
canvas. `select_by_color` (`tolerance` 0–255, `contiguous`, `sample_size`) and
`select_object` leave the app's own tool settings alone; `select_subject` reports
`found: false`, keeping the selection, when Vision finds nothing. `load_layer_selection`
with `source: mask` selects the mask's white (revealed) areas, as Cmd-clicking a mask
thumbnail does in Photoshop. `transform_selection` never moves pixels, and the outline may
extend past the canvas. `move_selected_pixels` refuses Lock Pixels and Lock All only (the
pixels stay in the layer). `get_selection`'s path stops after the last whole outline past
256 KiB (`path_truncated`).

**Painting and pixels.** Painting, filling and filters refuse hidden layers and an empty
selection, and make their layer active (its mask targeted with `target: mask`); a call
that fails leaves the layer selection as it was. On a mask, colors paint as gray (black
hides, white reveals), and the foreground and background (and `stroke_path`'s default
color) are the app's mask colors: black and white, unless the owner swapped them.
`stroke_path` modes: `paint` lays down `brush.color`; `erase` clears; `heal` is Spot
Healing (`heal_mode`); `clone` copies from `clone.source`, where the first point copies
from, keeping that offset for the whole stroke; `blur`, `smudge` and `liquify` push what
they pass over. Masks take `paint` and `blur`. `brush` takes `diameter` (1–2000),
`hardness` and `opacity`. `draw_gradient` without `colors` or `style` runs from the
foreground to transparent; past the ends, the end colors continue. `set_layer_pixels`
keeps a mask where it is on the document. `copy_pixels` makes its layer active and fills
Compositor's clipboard and the system pasteboard (as PNG).

**Filters.** `apply_filter` takes `set_adjustment`'s keys for the same kind, and a filter
without an adjustment layer takes its panel's sliders: Lens Correction `distortion`
(−100…100; positive straightens barrel distortion); Vignette `amount`, `midpoint`,
`feather`, `highlights` (0–100), `roundness` (−100…100) and `color`; Bloom / Glow
(`bloom_glow`) `amount` (0–100) and `radius` (1–150); Tonal Contrast `amount` (0–100),
`radius` (1–100) and `shadows`, `midtones`, `highlights` (−100…100); the Camera Raw Filter
(`camera_raw_filter`) its Basic and Presence sliders, `temperature`, `tint`, `contrast`,
`highlights`, `shadows`, `whites`, `blacks`, `texture`, `clarity`, `dehaze`, `vibrance` and
`saturation` (−100…100) and `exposure` (−5…5; its curves, color mixer, grading, detail,
optics and geometry are only in the app's panel). Vignette on an empty layer frames the
whole canvas, as in the app. Unset settings are the filter's own defaults —
`gradient_map` runs from the foreground to the background color — never the app's
last-used values. A blur can spread a layer past its
edges. Lens Correction without distortion, Exposure at its defaults and Grain with amount
0 change nothing and record nothing. `apply_levels`' `auto` is the panel's Auto buttons:
`contrast` stretches all channels together, `color` each on its own, `neutral` also evens
out the midtones. `content_aware_fill` grows a layer to cover any of the selection past
its edge. `remove_background` keeps a mask already there (hiding what either hides) and,
with a selection, changes only the selected part of the mask; `advanced` refines the
edge: `refine_edges` (0–40, 0 off) pulls it onto the image's detail, `matte_contrast`
(0–100) pushes grays toward black and white, `shift_edge` (−10…10) contracts or expands.

**Masks.** `from_selection` and `hide_selection` use the selection up, as Photoshop does.
`apply_layer_mask` keeps the layer's effects and refuses a disabled mask. A linked mask
moves and transforms with its layer; `copy_layer_mask` puts the copy where the mask sits
on the document and targets it. Mask edits refuse only Lock All; `apply_layer_mask`, which
rewrites the layer's pixels, also refuses Lock Pixels.

**Text and fonts.** Style fields and ranges: `font_name` (a PostScript name), `font_size`
(1–2000), `color`, `alignment` (`left`, `center`, `right`), `tracking` (−100–1000),
`leading` (0–5000; 0 is auto, 120% of the size), `box_size` (`{width, height}`, 16–30,000
px, its 12-pixel padding included; `null` makes point text), `horizontal_scale` (0.1–10,
`null` is 1) and `content`. `add_text_layer`'s `anchor` is one of nine points of the
text's box (the text plus 12 pixels of padding each side, or the paragraph's box).
`fit_text` measures in document pixels, the layer's own scale counted, and scales set
leading and tracking along; paragraph text is refused (guard `point_text`: set `box_size`
to `null` first). `get_text_metrics` sizes are in the text's own pixels, lines' baselines
measured down from the box's top. `list_fonts`' `weight` is 0–15 (5 regular, 9 bold).

**Shapes.** A rectangle's `corner_radius` over half its shorter side makes a pill. A line
is drawn `line_width` thick with round ends on a layer that is the ends' box with room for
that thickness; Photoshop draws lines with flat ends. `stroke` (`enabled`, `width`
0–500, `color`, `alignment` `center`/`inside`/`outside`) outlines a rectangle or
ellipse as Photoshop's shape stroke does: the shape keeps filling its box, and the layer's
box grows by as far as the stroke reaches past it. Lines take no stroke. A new stroke
starts enabled, 1 pixel wide, black, inside the edge.

**Smart objects.** Contents can be PNG, JPEG, TIFF, GIF, SVG, PDF (its first page) or a
Photoshop `.psd`; PSB and EPS can't be drawn, and files over 512 MiB are refused. A placed
file takes its own size at the document's resolution (72 ppi when the file doesn't say),
shrunk to fit the canvas. `fit` is `fit` or `fill` (keeping proportions, centered) or
`stretch`. `fill` crops the contents to the box's proportions, keeping the middle, and the
crop becomes the contents: a PNG, or a TIFF from a TIFF (other files become PNGs and their
name takes `.png`; contents already of the box's proportions are kept as they are, in their
own format; vector contents are drawn at a pixel a point, or finer to cover the box).
So the layer covers the box exactly and nothing spills past it. On replace, `fill` and
`stretch` keep the quad, which covers the whole layer unless Photoshop trimmed the layer's
pixels. Replacing refuses a pixel lock, and a position lock when the new contents would move
the layer. `get_smart_object_info`'s `file_type` is a four-character type (`png`, `JPEG`,
`PDF`, `8BPS` for Photoshop), `bytes` is null when the document doesn't hold the contents
(Photoshop linked them), `natural_size` is pixels or, for vector contents, points, and
`contents_revision` counts replacements.

## Profiles

A Profile adjustment layer applies a Lightroom or Camera Raw creative profile — Adobe's
Artistic, B&W, Modern, Vintage and Film-Inspired looks, or one you import — to what is
below it (or, clipped, to one layer). Compositor applies output-referred creative
profiles, the kind made for rendered images. Camera-matching profiles (made for one
camera's raw files) and RAW-only profiles can't be applied to an image, so
`list_profiles` hides them and counts them in `hidden`; `include_unusable: true` lists
them with a `reason`.

Choose one with `profile`: an entry's `id` (its file's SHA-256), its Adobe UUID,
`"Group/Name"`, or its name, ignoring case. `null` means none, and the layer passes its
input through. `amount` runs from 0 to 200 in whole numbers (100 is the profile as
designed); a profile without an Amount (`supports_amount: false`) stays at 100, which
choosing one sets when you give no amount. A Profile layer `add_adjustment_layer` adds is
named after its profile unless the call names it.

`fidelity` is `"exact"` when Compositor ignores none of the profile (it applies every
table and curve the profile has), and `"approximate"` when the profile also carries Adobe
develop settings Compositor doesn't reproduce; `ignored_settings` names them (for example
`Clarity2012`). An approximate profile looks close to, not the same as, Lightroom. "Exact"
isn't yet a verified match with Lightroom either: a look table with a fixed amount (the
base look many creative profiles share) is applied in full, and whether Lightroom applies
it that way to a rendered image hasn't been checked. Report an exact profile as applying
everything it contains, not as identical to Lightroom.

A `.comp` project embeds each profile its layers use, byte for byte, as
`profiles/<digest>.xmp`, so it renders the same on a Mac without the profile installed.
Photoshop has no Profile layer: saving as PSD writes a Profile layer as a pixel layer of
its result only with `allow_lossy: true`, and otherwise refuses the save (guard `lossy`).

```json
{"name": "list_profiles", "arguments": {"query": "vintage"}}
{"name": "add_adjustment_layer", "arguments": {"kind": "profile", "name": "Vintage 03", "settings": {"profile": "Vintage/Vintage 03", "amount": 80}, "clip_to_below": true}}
{"name": "set_adjustment", "arguments": {"layer": "Vintage 03", "settings": {"amount": 120}}}
```

Errors: `not_found` (no profile matches), `ambiguous` (several do; pass an id from
`details.candidates`), `unsupported` (a profile Compositor can't apply;
`details.reason` is `raw_only`, `camera_specific` or `unsupported`), and
`invalid_argument` (`details.code` names why a file can't be imported or loaded, such as
`not_a_profile`; `details.field` names a bad setting, such as `amount` for a profile
without an Amount). A file that can't be read or copied fails with `io_error` instead, as
does a listed profile whose file changed or vanished since: call `list_profiles` with
`refresh: true`.

`import_profile` returns `imported`, `already_imported` and `skipped` (`{path, code,
message}` for each file it rejected). Given a folder, it searches the folder and its
subfolders for `.xmp` files, without following symbolic links or entering packages. One
call reads at most 1,000 of them: `truncated: true` means the folder held more, so import
its subfolders one at a time. `skipped` lists the first 100 rejected files and
`skipped_count` counts them all; a photo folder's Camera Raw sidecars, for example, all
land there as `not_a_profile`. Before searching, it checks each macOS-protected folder
inside the one named (`~` holds Documents, Desktop and Downloads; `/`, `/System` and
`/System/Volumes` hold every one). If macOS is still asking about one, the call fails at
once with `busy` and `details.code: "folder_access_pending"` instead of waiting; a folder
macOS refused is left out.

Limits: `import_profile` takes at most 4 MB per profile file, and reads at most 1,000
`.xmp` files per call.

## Limits

- 30,000 px per side (`get_app_info` `limits.max_canvas_side`).
- 200 megapixels in any one surface Compositor makes: a canvas, an export, a filter's
  target, a text box or a shape (`limits.max_pixels`).
- An imported layer (an image, SVG or Photoshop file's layers, or layers pasted or copied
  in) isn't held to 200 megapixels: it is checked against the document's pixel budget,
  which all of a document's layers share (its masks get as much again on their own), and
  which scales with the Mac's memory: a quarter of it at 4 bytes a pixel, between 200 and
  800 megapixels (`limits.document_pixel_budget`; `DocumentLimits`). Import, paste, resize
  and loading a project enforce it. A Photoshop file whose layers wouldn't fit opens with
  every layer and mask cropped to the canvas, and a note on each one cropped.
- 10,000 layers per document.
- 32 open document tabs (`MCPSettings.maxTabs`).
- 64 tool calls queued or running at once, across every connected client
  (`MCPSettings.maxQueuedCalls`); beyond that, a call fails fast with `busy`.
- 256 points per `sample_colors` call; 10,000 points per `stroke_path` or
  `select_polygon` call.
- 200 steps per `run_batch` call.
- 1000 guides per document.
- Render tools: `max_size` 16–4096 px. `export_image`: `max_size` up to 30,000 px,
  `scale` 0.05–4.
- `tools/list` stays under 120 KB and the `initialize` instructions under 4 KB
  (`MCPToolListBudgetTests`).
- Request bodies over 32 MB are rejected (`413`).


## Troubleshooting

- **Diagnostic logs**: Compositor logs every request, tool call (with its duration, outcome and
  error), refusal, server start and stop, and every open, save and export to
  `~/Library/Logs/Compositor/compositor-YYYY-MM-DD.jsonl`, and the bridge logs what it forwarded
  to `bridge.jsonl` beside it; neither holds the access token or image data.
  `scripts/collect-logs.sh --since 2h` (or `--host <ssh-alias>` for another Mac) gathers them with
  the unified log and crash reports. See [Diagnostic logs](logging.md).
- **Port fallback**: if 2667 (or your chosen port) is taken, the server binds an
  ephemeral port instead — Settings shows the live port and a warning, and the
  ready-to-copy snippets there always match what's actually running. If a *second*
  Compositor process is the one holding 2667, the endpoint file keeps pointing at that
  first instance rather than the fallback, so already-configured clients keep working.
- **Stale endpoint file**: a crash can leave
  `~/Library/Application Support/Compositor/mcp/endpoint.json` behind. The next launch
  removes it automatically unless it still names a different Compositor process that's
  actually alive. The `compositor-mcp` bridge treats the file as a hint only — it
  probes the URL with a `ping` before trusting it, and re-launches or re-signals
  Compositor if nothing answers.
- **"The document can't be edited right now" / `busy` / `precondition_failed`**: the
  app has something open that blocks agent edits — an import, a save, a crop, a brush
  stroke, a modal dialog (Levels, Hue/Saturation, New Document, an error alert), and so
  on; `message` says which, and `guard` names the check. `settle_pending_edits` commits
  or cancels what the app holds open; imports, saves and other long operations finish on
  their own, so retry the call after a short delay (or ask the user to finish what's open
  in the app).
- **A save or export fails with `can_start_project_operation` after a pause**: the call
  waited on macOS for folder access, and the owner started an edit in the app meanwhile.
  Nothing was written; settle the edit and retry.
- **Claude Desktop can't reach Compositor**: check that
  `Contents/MacOS/compositor-mcp` still exists at the path in
  `claude_desktop_config.json` — it moves if you move or reinstall the app — and that
  Compositor › Settings… shows the server running (or let the bridge launch it: it passes
  `--mcp` automatically unless started with `--no-launch`).
- **Nothing answers on `localhost`**: the server listens on IPv4 `127.0.0.1` only; use
  that address rather than a name that resolves to `::1`.
- **`401 Unauthorized`** (or a client saying authentication is required): the request
  didn't carry the current access token. A client added with a token before
  **Regenerate token…** has the old one: add it again with the new one from Settings
  (Claude Code: `claude mcp remove compositor`, then the copied line; Codex over HTTP: a
  new shell, so `COMPOSITOR_MCP_TOKEN` is read from the token file again, then a new Codex
  session). A client added without one needs it. Better, set the client up through the bridge, which
  always sends the current token, and only to Compositor. Through the bridge, the error
  says `Compositor's access token changed or is missing; restart the client or re-copy the
  setup snippet`, or names a token file it refuses (another user's, or readable by others:
  `chmod 600` it, or restart the server, which tightens it).

## Granting folder access

Leaving out the App Sandbox doesn't lift macOS's own privacy controls (TCC, System
Settings → Privacy & Security → Files and Folders). macOS guards these locations for
every app, Compositor included:

- `~/Documents`, `~/Desktop` and `~/Downloads`;
- iCloud Drive (`~/Library/Mobile Documents`);
- cloud storage providers such as Google Drive or Dropbox (`~/Library/CloudStorage`),
  each asked about separately ("files managed by Google Drive");
- removable and network volumes (`/Volumes`), each volume asked about separately.

A path counts as being in one of these however it is spelled: through symlinks, through
the startup disk's own entry in `/Volumes` (`/Volumes/Macintosh HD/Users/…`), or through
the Data volume (`/System/Volumes/Data/Users/…`).

The first time Compositor reads one, macOS asks — "Compositor would like to access
files in your Documents folder" — and the read waits until someone answers. An agent
working while you're away would wait on that prompt, so answer the prompts while you're
at the Mac:

- **Folder access** in Compositor › Settings… lists each of these locations that exists on
  this Mac with what the last check found: Granted, Denied, Waiting for approval,
  Nothing to check (no provider or volume inside), or Not checked. A location is checked
  when you ask, and states aren't remembered across launches. **Request access** reads
  the location right away so macOS shows its prompt now; for iCloud Drive, cloud storage
  and volumes it goes through each folder, provider or volume in turn, past any already
  denied, and stops at a prompt you haven't answered yet. The row is Denied when any of
  them is, and names the ones denied or still waiting underneath. The read runs off the
  main thread, so Settings stays responsive while a prompt is up.
- **Denied** is final: macOS doesn't ask again. Turn Compositor on under
  Files and Folders instead (a denied row's **Open Privacy Settings** goes there), or grant
  Full Disk Access.
- **Full Disk Access** (Privacy & Security → Full Disk Access → add Compositor) is the
  blanket option: one switch instead of a prompt per location. macOS may still ask
  separately about some cloud storage providers.
- A development build signed differently from the one you approved counts as a new app
  to macOS, which asks again.

### Agents never wait on a prompt

Every tool that opens, lists, reads or writes a file — `open_document`, `save_document`
and `revert_document` (on the document's own file), `save_document_as`, `export_image`,
`get_layer_pixels`' `save_to`, `add_image_layer`, `set_layer_pixels`,
`paste_image_into_layer`, `place_smart_object`, `replace_smart_object_contents`,
`export_smart_object_contents`, `list_files`, `get_file_info`, `reveal_in_finder`,
`import_profile` — checks access to the location first, before anything on disk is touched
(`MCPPaths.resolveReachable`). It lists the location on a background thread and waits two
seconds at most, and asks about each location once per call, however many of the call's
paths lie there:

- **Denied**: the call fails with `io_error`, `details.code: "folder_access_denied"`,
  `details.path` and `details.root`, and a hint to grant access or copy the file to the
  Agent folder.
- **A prompt waiting** (or a location not answering): the call fails with `busy`,
  `details.code: "folder_access_pending"`, after about two seconds. Approving the prompt and
  retrying works; later calls meanwhile join the same check instead of starting another.
- **Granted**, or a path outside these locations: the tool runs normally. Paths elsewhere
  are never probed.

`details.path` spells the path as a successful call would report it (`..` and `.` worked
out). `save_document`, `save_document_as` and `export_image` check again, once access is
settled, that nothing the owner started in the app meanwhile holds the document; if
something does, they fail with guard `can_start_project_operation` and write nothing.
`revert_document` checks its file — access first, then that it still exists — before
anything else, so an unreachable or missing file is what it reports even while the
document couldn't be reverted anyway.

A tool's check updates the states Settings and `get_app_info` show; one that ran out of time before it could ask macOS anything (a recursive `list_files` whose two seconds are used up, say) leaves them as they were. `get_app_info` reports
`folder_access` for every location, probing those not checked yet this session, so an agent
can see up front which locations it can use.

Google Drive, iCloud Drive and other cloud storage are File Provider locations: being
allowed in doesn't mean a file is on this Mac. Opening a file that is only in the cloud
downloads it first, which can take a while (or fail offline) even with access granted.
The file is read off the main thread, so the window and the agent's other calls go on
meanwhile; the call that opens it waits. Mark the folders an agent works in as available
offline to avoid that wait.

Only the locations above are checked. macOS also guards other apps' data
(`~/Library/Containers/<another app>` and Group Containers, macOS 14 and later), Photos
and Mail; a tool pointed there can still wait on a prompt, so keep an agent's files in the
Agent folder or the locations above.
