# Architecture

Where the code lives and how a document moves through it. Paths are relative to the
repository root; types are named so you can jump to them.

## Contents

- [Targets](#targets)
- [The document model](#the-document-model)
- [Editing, guards and undo](#editing-guards-and-undo)
- [Tabs and files](#tabs-and-files)
- [Rendering and export](#rendering-and-export)
- [Photoshop import](#photoshop-import)
- [The MCP server](#the-mcp-server)
- [The compositor-mcp bridge](#the-compositor-mcp-bridge)

## Targets

| Target | Folder | Notes |
|---|---|---|
| `Compositor` (app) | `Compositor/` | Swift 5 mode, default actor isolation `MainActor`, approachable concurrency. Packages: Sparkle (updates) and the MCP Swift SDK (`modelcontextprotocol/swift-sdk`, pinned up to the next minor). C pixel kernels (`Compositor/Rendering/*.c`) come in through `Compositor-Bridging-Header.h`. |
| `CompositorTests` | `CompositorTests/` | Swift Testing unit tests, hosted by the app (`TEST_HOST` is `Compositor.app`). Not main-actor by default. |
| `CompositorUITests` | `CompositorUITests/` | UI automation; not part of routine runs. |
| `compositor-mcp` | `Tools/compositor-mcp/` | The stdio bridge, a command-line tool embedded in the app bundle at `Contents/MacOS/compositor-mcp` by the "Embed Helpers" phase. Complete strict concurrency; Foundation and AppKit only. |

`Compositor/` is split by role: `Document/` (the model and every editing operation),
`IO/` (files: projects, images, PSD, export, resizing), `Rendering/` (canvas drawing,
effects, pixel kernels), `UI/` (SwiftUI and AppKit views, sheets, panels) and `MCP/` (the
agent server). `CompositorApp.swift` declares the editor window and the Settings scene,
whose one pane (the "AI Agents" pane in code comments) is `MCPSettingsView`; `CompositorApplicationDelegate` owns the
`ProjectWorkspace`, the `MCPServer` and Sparkle, and runs launch-time work.

## The document model

All in `Compositor/Document/`, mostly `EditorSession.swift`.

- **`CanvasDocument`** (value type): `id`, pixel `width`/`height`, `resolution` (ppi),
  `layers` **bottom to top**, `guides`, the current `selection` (in the document so undo
  covers it; never saved), and `psdExtras` (what a Photoshop source held beyond the
  layers).
- **`ImageLayer`** (value type): `id`, `asset` (an `ImportedImage`: immutable `CGImage` plus
  thumbnail; nil for blank layers, folders and adjustment layers), `transform`
  (`LayerTransform`: origin, size, clockwise rotation, flips, sampling), `name`,
  `isVisible`, `parentID`/`isGroup` (folders are flat records linked by parent; array order
  is sibling order), `opacity`, `blendMode`, `mask` (`LayerMask`), `maskSourceID` (a
  clipping mask: the layer below whose alpha clips this one), `adjustment`
  (`LayerAdjustment`), `shape` (live shape source), `text` (`LayerText`, live editable
  text), `effects` (`LayerEffects`: stroke, drop and inner shadow, colour overlay, outer
  glow), `locks` (Photoshop `lspf` bits, kept and written back), `fillOpacity`, and
  `psdExtras` (`PSDLayerExtras`).
- A layer's `text` or `shape` is "live" only while its pixels are still the raster that
  source produces; destructive pixel edits drop the source and keep the pixels.
- **`EditorSession`** (`@Observable`, main actor): one open document and everything around
  it: `document`, `activeLayerID` and `selectedLayerIDs`, tool state, dialogs in progress
  (`levels`, `hueSaturation`, `filterEdit`, `textDraft`, `transformEdit`, `cropRect`, …),
  `history` (`DocumentHistory`), `projectURL`/`sourceURL`, and busy flags
  (`isProjectBusy`, `isImporting`). Features extend it in `EditorSession+<Feature>.swift`
  or `<Feature>.swift` files.

## Editing, guards and undo

- **Guards.** `canEditLayers`, `canStartProjectOperation`, `canUseHistory`, `canPaint`,
  `canTransform`, `canEditMask`, `canEditEffects`, … are computed from that state; each is
  false while something modal holds the document. UI commands disable themselves with
  them, and MCP tools turn them into structured errors (`MCPGuards`).
- **Undo.** `beginEdit(name)` / `endEdit()` wrap a mutation. `DocumentHistory` snapshots
  the whole `CanvasDocument` value before and after; snapshots share the immutable images,
  so a layer edit copies no pixels. Nesting is allowed: only the outermost pair records,
  and a pair that leaves the document unchanged records nothing (so no-ops keep the redo
  stack). History holds up to 100 entries and trims beyond 256 MB of retained images;
  `revisionID` changes whenever the document moves to another history point.
- **Mutations** replace `document` (or its layers) with a new value inside the edit pair.
  Heavy pixel work (filters, fills) runs in a detached task and commits back on the main
  actor.

## Tabs and files

- **`ProjectWorkspace`** (`Document/ProjectWorkspace.swift`): the open tabs
  (`ProjectTab`: a `session` plus a `ProjectController`), `current`, `addTab`, `close`,
  and `openDocument(at:select:)`, the headless open used by agents: `.comp`, `.psd` or a
  raster image into a new tab, with no sheets or alerts, Photoshop conversion notes
  returned instead of shown. A Photoshop or image source sets `sourceURL` and leaves
  `projectURL` nil, so a later plain Save asks where to write instead of replacing the
  original.
- **`ProjectController`** (`IO/ProjectController.swift`): the UI's open/save/close flows
  with panels and confirmation.
- **`ProjectStore`** (`IO/ProjectStore.swift`): reads and writes the `.comp` package
  (`manifest.json`, `images/`, and for Photoshop documents `psd/` sidecars) atomically,
  validating everything before replacing the live document. `ProjectManifest`
  (`current = 11`) and `ProjectLayerRecord` are the saved form;
  `IO/ProjectPSDRecords.swift` stores the Photoshop data (format 10).
- **`ProjectSnapshot`**: the saved form of a document in memory (manifest, images, masks),
  built by `session.projectSnapshot()`. Saving, Image Size, Canvas Size, Crop, adjustment
  previews, export and MCP previews all work from it.
- **Layer ↔ record mapping**: only `ProjectLayerRecord(layer:)` and
  `ImageLayer(record:snapshot:)` in `Document/ImageLayer+Record.swift`, plus the record's
  `translated(by:)` (Canvas Size, Crop) and `scaled(x:y:transform:maskPlacement:)` (Image
  Size). Because export and previews render from the snapshot, a layer property missing
  here disappears from saved files, resized documents, exports and agent previews alike.
- Other IO: `ImageImporter` (decode PNG/JPEG/HEIC/TIFF into `ImportedImage`, enforcing the
  pixel limits), `RawImporter`, `ImageExporter` (PNG/JPEG from a snapshot),
  `CanvasResizer`/`ImageResizer` (Canvas Size, Image Size), `PreferencesMigration` (the
  one-time move out of the old sandbox container; skipped when hosting tests).

## Rendering and export

- `Rendering/EditorCanvas.swift`: `EditorCanvas`, a SwiftUI wrapper around `CanvasView`, the
  AppKit view that draws the document and handles tools and overlays.
- `LayerRenderer` (CoreGraphics, top-left coordinates) draws layers for both the canvas
  and export; `TiledLayerRenderer` draws painted layers held as base image plus tiles;
  `SeparableBlend` composites the blend modes Core Graphics can't draw correctly (through
  Core Image).
- Effects: `LayerEffectsSurface`, `MetalLayerEffects` (GPU, separable passes, CPU
  fallback) and `EffectsPreviewCache` (canvas previews on a background worker; exports
  render full resolution).
- Pixel kernels in C (`AdjustPixels`, `BrushPixels`, `ContentFill`, `HealPixels`,
  `LevelsPixels`, `LensPixels`, `NoisePixels`, `WandPixels`) with Swift callers in
  `Document/`.
- `ImageExporter.shared` (an actor) composites a `ProjectSnapshot` with `render(_:)`;
  `pngData`/`exportPNG` and the JPEG path encode it. `MCP/MCPRender.swift` calls the same
  `render(_:)` for previews, region renders and single-layer renders, so an agent's preview
  is exactly what Export writes.

## Photoshop import

`Compositor/IO/PSD/`, 8-bit RGB PSD version 1 and Large Document PSB version 2 (no CMYK or
16/32-bit; a PSB's 8-byte lengths are read, and `PSDBlockFile.largeDocumentKeys` names the
blocks that have them). The writer writes version 1 only, so a PSB-opened document saves as
a `.psd`:

1. `PSDReader.read(from:)` / `read(_:)` parses the file into a `PSDDocument` of
   `PSDRecord`s (`PSDTypes.swift`), keeping every tagged block and record field in
   `PSDLayerExtras` / `PSDDocumentExtras` (`Document/PSDExtras.swift`). Helpers:
   `PSDChannelCoder` (raw and PackBits channels), `PSDResources` (image resources such as guides,
   ICC name, light angle), `PSDDescriptor` (action descriptors), `EngineData` and
   `PSDText` (type layers), `PSDVector` (vector masks, live rectangles and ellipses),
   `PSDBlockFile` (the sidecar wire format).
2. `PSDDocumentBuilder.makeImport(_:)` turns it into a `PSDImport`: `ImageLayer`s, guides,
   resolution, document extras, and `PSDConversion` notes describing anything converted or
   kept only for writing back.
3. `EditorSession.insertPhotoshop(_:named:)` installs it (the UI shows the conversion sheet
   first; `ProjectWorkspace.openDocument` accepts the conversions headlessly).

`FontResolver` (`Document/FontResolver.swift`) maps Photoshop PostScript font names to
installed fonts for editing imported text, reporting substitutes. `IO/PSD/Writer/` writes a
document back as a layered PSD (`PSDWriter.write(_:to:options:)` from
`EditorSession.psdWriteRequest()`, off the main actor through `PSDExporter`), keeping what
import preserved for untouched layers and returning a report of warnings. Save As offers it
as a format in the app (`ProjectController`) and over MCP (`save_document_as`), and the
`.psd` becomes the document's file (`EditorSession.documentFormat`). See
[PSD features and the .comp format](psd-and-projects.md).

## The MCP server

`Compositor/MCP/`:

| File | Role |
|---|---|
| `MCPServer.swift` | Lifecycle: start reasons (Settings switch or session), binding the preferred port with ephemeral fallback, the endpoint file, the SDK `Server` with custom `initialize` so many clients can connect, and `invokeTool`. |
| `MCPHTTP.swift` | The loopback HTTP listener (127.0.0.1 only, 32 MB request cap); its `MCPAccessGate` check answers 401 from a request's head (after only its size and framing limits), before the body is read or any other check runs. |
| `MCPRequestRouter.swift` | Per-request JSON-RPC id isolation for the stateless transport, and the validation pipeline (no `Origin` → 403, loopback `Host` → 421, Accept, Content-Type, protocol version). |
| `MCPToolQueue.swift` | Runs tool calls one at a time in arrival order, at most `MCPSettings.maxQueuedCalls` (64) waiting. |
| `MCPTools.swift` | `MCPToolRegistry`: `entries` from the per-domain arrays, the `tool(...)` builder, dispatch, server `instructions`; `MCPCallContext` (tab, session, args, selectors, `mutated`). |
| `MCPTools+<Domain>.swift` | The tools: Documents, Render, Files, Layers, Transforms, Canvas, Adjustments, History, View, Effects, Selection, Paint, Filters, Masks. |
| `MCPSchema.swift` | JSON Schema builders (`str`, `num`, `int`, `bool`, `enumString`, `color`, `point`, `rect`, `layerSelector`, `documentSelector`, …). |
| `MCPSelectors.swift` | Resolving `document` and `layer`/`layers` arguments; `ambiguous` with candidates. |
| `MCPGuards.swift` | Preconditions as errors with a `guard` name and a human `blockingReason`. |
| `MCPResult.swift` | `MCPErrorCode`, `MCPToolError`, result builders (`ok`, `failure`), and `Args`, the typed argument reader. |
| `MCPValues.swift` | The JSON shapes tools return (tabs, documents, layers, transforms, undo). |
| `MCPRender.swift` | Headless composites, previews, pixel reads. |
| `MCPPaths.swift` | Path resolution (absolute, `~`, relative to the Agent folder) and overwrite protection. |
| `MCPSettings.swift` | Preference keys (`mcp.requireToken` among them), default port 2667, limits, the endpoint and token file paths, `agentRootOverride` (test seam). |
| `MCPAccessToken.swift` | The access token: made with `SecRandomCopyBytes` (43 base64url characters), kept in `mcp/token` (0600, in a 0700 folder), regenerated from Settings, compared in constant time; `MCPAccessGate` holds the current one for the listener. |
| `MCPEndpointFile.swift`, `MCPClientSnippets.swift`, `MCPSettingsView.swift` | Discovery file (with `auth` and `token_file`, never the token), client setup lines (the bridge first; HTTP with the token as the alternative), the Settings pane (Require access token, Copy, Regenerate). |

## The compositor-mcp bridge

`Tools/compositor-mcp/`: `main.swift` (flags), `EndpointDiscovery.swift` (endpoint file →
owner, mode and loopback checks → live pid → `ping`), `AccessToken.swift` (reads the token
file the endpoint file or `--token-file` names, refusing one that isn't the user's or is
wider than 0600), `AppLauncher.swift` (launch with `--mcp` or post the start
notification), `Bridge.swift` (stdin lines → POSTs with the token read again for each one,
a 401 retried once after rediscovery, `tools/call` serialized in order, errors on the
request's id). It shares no code with the app: constants such as the bundle identifier,
`--mcp`, the notification name and the token's format are duplicated on purpose, so keep
them in step with `MCPSettings`, `MCPEndpointFile` and `MCPAccessToken`. `MCPBridgeTests`
runs the embedded binary as a child process.
