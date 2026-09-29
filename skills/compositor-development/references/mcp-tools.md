# Adding an MCP tool

Every agent-facing capability is a tool in `MCPToolRegistry`. A tool is only as good as
what an agent can learn from `tools/list` and what it gets back, so the schema text, the
error envelope and the undo behavior matter as much as the handler. Work through the
steps in order; the checklist at the end is what review looks for.

## Contents

- [1. Decide the shape](#1-decide-the-shape)
- [2. Declare it](#2-declare-it)
- [3. Write the handler](#3-write-the-handler)
- [4. Errors](#4-errors)
- [5. Tests](#5-tests)
- [6. Documentation](#6-documentation)
- [Changing an existing tool](#changing-an-existing-tool)
- [Checklist](#checklist)

## 1. Decide the shape

- Look at `tools/list` (or `MCPToolRegistry.entries`) first: extend a tool when the new
  behavior is an option of an existing one, add a tool when it is a new action.
- Names are lower snake case, verb first (`set_layer_opacity`, `render_region`);
  `MCPRegistryTests` enforces the pattern and uniqueness.
- Pick the domain file, `Compositor/MCP/MCPTools+<Domain>.swift`: Documents, Render, Files,
  Layers, Transforms, Canvas, Adjustments or History. A new domain gets a new file with a
  `static let <domain>Tools: [MCPToolEntry]` array, added to `MCPToolRegistry.entries` in
  `MCPTools.swift`.
- Reuse the UI's operation. A tool calls the same `EditorSession` method a menu command
  calls, so the agent's result, undo name and edge cases match what a person gets. If the
  operation only exists inside a view, move it into the session first.
- Arguments follow the server's conventions: `document` (added for you), `layer`/`layers`
  selectors, document pixels with the origin top left, colours as `{r, g, b}` in 0–1 or
  `"#rrggbb"`, clockwise degrees, fractions 0–1, file paths absolute, `~/…` or relative to
  the Agent folder, and `overwrite: true` required to replace a file.

## 2. Declare it

```swift
tool("set_layer_opacity", title: "Set layer opacity",
     description: "Sets a layer's opacity from 0 (transparent) to 1 (opaque). Applies to folders too (dimming contents).",
     properties: ["layer": MCPSchema.layerSelector(), "opacity": MCPSchema.num("Opacity.", min: 0, max: 1)],
     required: ["layer", "opacity"], effect: .additive(idempotent: true), handler: setLayerOpacity),
```

- **Description**: what it does, the defaults, what it returns and any limit, in plain
  sentences. It is the only documentation an agent sees at call time.
- **Properties** come from `MCPSchema` so every tool describes things the same way:
  `str`, `num(min:max:default:)`, `int`, `bool`, `enumString`, `arr`, `color`, `point`,
  `rect`, `layerSelector`, `layerSelectors`, `nullable`, `oneOf`/`anyOf`. Put defaults and
  ranges in the schema, not only in prose.
- **`targetsDocument`** (default `true`) adds the optional `document` selector. Pass `false`
  for tools that don't act on a document (`list_files`, `open_document`, `new_document`).
- **`effect`** becomes the MCP annotations clients use to decide what needs confirmation:
  - `.readOnly`: changes nothing (`get_document`, `render_*`, `sample_colors`).
  - `.additive(idempotent:)`: changes the document or app, undoably, losing nothing. Setters
    that land in the same state when repeated are idempotent (`set_layer_opacity`);
    creators are not (`add_blank_layer`).
  - `.destructive(idempotent:)`: may discard data or write files (`delete_layers`,
    `merge_layers`, `close_document`, `save_document`, `export_image`, `undo`, `redo`).

## 3. Write the handler

```swift
static func setLayerOpacity(_ ctx: MCPCallContext) throws -> CallTool.Result {
    let document = try ctx.editableDocument()                  // no document, or edits blocked
    let layer = try ctx.layer(in: document)                    // "layer" selector: not_found, ambiguous
    let opacity = min(1, max(0, try ctx.args.double("opacity")))
    try edit(layer.id, ctx: ctx, name: "Layer Opacity") { layer in
        guard layer.opacity != opacity else { return false }   // a no-op records no undo step
        layer.opacity = opacity
        return true
    }
    return ctx.mutated(["opacity": .double(opacity)])          // adds undo {name, count, recorded}
}
```

`edit(_:ctx:name:_:)` in `MCPTools+Layers.swift` wraps a one-layer change in
`beginEdit`/`endEdit`; larger operations call the session method the UI uses between their
own pair.

- **Signature**: `static func name(_ ctx: MCPCallContext) (async) throws -> CallTool.Result`.
  Handlers run on the main actor, one at a time, behind `MCPToolQueue`.
- **Arguments**: read through `ctx.args` (`string`, `optionalString`, `double`, `int`,
  `bool(_:default:)`, `object`, `color`). A present argument of the wrong type throws
  `invalid_argument`; never fall back to a default silently. The registry refuses an
  argument the tool's schema doesn't declare before the handler runs
  (`MCPToolRegistry.unknownArgument`, also for `run_batch` steps), so every argument a
  handler reads must be in its `properties`.
- **Document and layers**: `ctx.document()` for reads, `ctx.editableDocument()` before an
  edit (it checks `canEditLayers`), `ctx.layer(_:in:)`, `ctx.optionalLayer(_:in:)`,
  `ctx.layers(_:in:)`.
- **Guards**: `MCPGuards.requireProjectOperation` (save, export, resize),
  `requirePixels` (not a folder or adjustment layer), `requireTabCapacity` (32 tabs),
  `captureBrushError` (turns the app's "Couldn't paint" alert into an error), and
  `withProjectBusy` around long async work so no other edit starts meanwhile.
- **Paths**: `MCPPaths.resolve(raw, mustExist: true)` to read;
  `MCPPaths.prepareForWriting(url, overwrite:)` before writing, which refuses an existing
  file unless `overwrite` is true.
- **The edit**: one `beginEdit("Name")` / `endEdit()` pair around the whole change, so the
  call is exactly one ⌘Z step, nested settings included. Use the undo name the menu command
  uses.
- **Results**: `ctx.mutated([...])` for anything that may change the document (it reports
  `undo: {name, count, recorded}`, with `recorded` false for a no-op);
  `MCPToolRegistry.ok([...])` for reads. Build layer, document, rect and transform JSON
  with `MCPValues` so every tool returns the same shapes. Image results put the image
  content block first (`imageResult` in `MCPTools+Render.swift`).
- **Headless**: never present an alert, sheet, panel or Finder window from a tool (except
  `reveal_in_finder`, whose job it is). An agent call has nobody to click anything.
- **Long work**: the POST stays open and every other client waits behind it. Do pixel work
  in a detached task inside `withProjectBusy`, and respect the shared limits (`DocumentLimits`:
  30,000 px per side, 200 megapixels a surface, the document pixel budget; 10,000 layers).

## 4. Errors

Throw `MCPToolError(code, message, hint:, guard:, details:)`; the registry turns it into
`isError: true` with `{"ok": false, "error": {...}}`. Unknown errors pass through
`MCPToolError.from`: Cocoa and POSIX file errors become `io_error`, anything else
`internal`.

| Code | Use when |
|---|---|
| `invalid_argument` | A value is missing, mistyped or out of range. Say the allowed range. |
| `not_found` | The named tool, document, layer or file doesn't exist. |
| `ambiguous` | A selector matched several; put `candidates` (`{id, path, kind}`) in `details`. |
| `precondition_failed` | The document's state forbids the call; set `guard` (`document`, `can_edit_layers`, `has_pixels`, `max_tabs`, `pixel_budget`, …). |
| `busy` | Something transient is running; the agent should wait and retry. |
| `io_error` | File trouble; `details.code: "file_exists"` for a refused overwrite. |
| `unsupported` | Understood but not supported by this build (an adjustment kind a renderer lacks). |
| `internal` | A bug. |

Messages name the thing ("'Logo' is a folder; it has no pixels of its own."); hints say
what to do next, preferably which tool to call.

## 5. Tests

Add `CompositorTests/MCP<Domain>ToolTests.swift` (or extend the domain's suite), a
`@MainActor` struct using `MCPTestSupport` (see [Testing](testing.md)). Cover:

- the success path, checking the document afterwards, not just `ok`;
- one undo step (`undo.recorded == true`, then `undo` restores the state) and a no-op that
  records nothing;
- each error the handler can throw, by code (`expectError: "not_found"`), and `guard` where
  set;
- selectors by id, name and path, and an ambiguous name;
- files only under `MCPTestSupport.tempFile` or the Agent folder override, including the
  refused overwrite.

`MCPRegistryTests` then covers the new tool's name and dispatch automatically. Run it with
your suite.

## 6. Documentation

- `docs/mcp.md`: one line in "Tool reference" under the domain, plus any new error code,
  guard, limit or convention in its section. The document is written from the registry, so
  keep its wording close to the tool description.
- `MCPToolRegistry.instructions` (sent on `initialize`): change it only when a
  server-wide convention changes.
- `README.md` "MCP server" section: only for a new capability area.

## Changing an existing tool

`tools/list` is a contract: agents, their prompts and the skills that teach them depend on
argument names and result fields. Add optional arguments rather than renaming; when a name
must change, keep reading the old one or answer it with a pointed hint (as
`MCPCallContext` does for the old `id`/`ids` arguments), and update `docs/mcp.md` in the
same commit.

## Checklist

1. Named, placed and described so an agent can use it from `tools/list` alone.
2. Correct `effect`; `document` selector unless it truly has no document.
3. Guards before the edit; one `beginEdit`/`endEdit`; `ctx.mutated` or `ok`.
4. Every failure is an `MCPToolError` with the right code, a clear message and a hint.
5. No UI, no real-user-state side effects in tests; overwrite needs `overwrite: true`.
6. Tests for success, undo, errors and selectors; `MCPRegistryTests` passes.
7. `docs/mcp.md` updated.
