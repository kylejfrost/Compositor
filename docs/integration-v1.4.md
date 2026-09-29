# MCP and Photoshop parity implementation guide

## Delivery status

The worktree is based on upstream Compositor 1.4.1 at `3b50e5d`. The integration commit `b9a56e9` carries the existing MCP and Photoshop work onto that base. The active branch is `feat/compositor-mcp-photoshop-v1.4.1`; the original checkout and prior feature worktree are preserved.

The follow-up implementation corrects MCP clone/blur sampling and selection-mask semantics, adds mixed-size live text, and makes standalone Solid Color Fill layers editable. These close gaps found during the recent PSD review and MCP contract verification. The full MCP server, bridge, project workflow and PSD import/export work are in the integration commit. The staged review sequence keeps each addition separate from that baseline.

Automated tests and code review establish implementation behavior. They do not establish full Photoshop parity. Photoshop's native open and re-typeset comparison is still pending: the UXP harness could not pass System Events preflight in this environment. Treat each Photoshop-specific claim below as either an automated guarantee or a remaining native-app check, as labeled.

## Evidence from recent PSDs

The local metadata review found 201 PSD paths modified during the preceding month. Eight anonymized copies were inspected to span repeated workflows; the sample is observational, not a statistical measure of the full set. No layer names, document names, text, typeface names, images or source files are included here.

- One sampled PSD had 26 Solid Color Fill (`SoCo`) layers.
- Another had about 13 smart objects, 19 type layers, five vector shapes and layer effects.
- A third used multiple text colors within a single type layer.
- The imported type samples also exposed mixed font-size runs that Compositor previously flattened to the dominant size when editing.

These findings drive the implementation order: MCP should make the same document model available through stable, documented tools; day-to-day Photoshop work should preserve editable layers and type runs instead of silently flattening them.

## Feature sets and codebase map

| Set | Implementation | Contract and evidence |
|---|---|---|
| MCP transport and lifecycle | The stateless loopback server, bearer-token check, endpoint file and stdio bridge are wired through `Compositor/MCP/` and `Compositor/IO/`. | [`MCPTransportTests`](../CompositorTests/MCPTransportTests.swift), [`MCPAccessTokenTests`](../CompositorTests/MCPAccessTokenTests.swift), [`MCPBridgeTests`](../CompositorTests/MCPBridgeTests.swift), [`docs/mcp.md`](mcp.md), and the [MCP tools specification](https://modelcontextprotocol.io/specification/2025-11-25/server/tools). |
| MCP document editing | Tool definitions share `EditorSession`, `ProjectWorkspace`, guards and undo history. The registry exposes document, layer, selection, pixel, text, shape, effects, adjustment, profile, smart-object, render, file and batch operations. | [`MCPTools.swift`](../Compositor/MCP/MCPTools.swift), per-domain `MCPTools+*.swift`, [`MCPToolContractTests`](../CompositorTests/MCPToolContractTests.swift), [`MCPToolListBudgetTests`](../CompositorTests/MCPToolListBudgetTests.swift), and the generated [tool atlas](../skills/compositor/references/tool-atlas.md). |
| MCP paint and mask parity | Blur and layer-only Clone Stamp sampling use the stroke's layer grid at native resolution, preserving detail on scaled layers; sample-all Clone Stamp continues to use the document composite. The MCP `from_selection` kind reveals the selected region and `hide_selection` hides it, matching the 1.4.1 UI semantics and app undo names. | [`EditorSession+Brush.swift`](../Compositor/Document/EditorSession+Brush.swift), [`CloneStamp.swift`](../Compositor/Document/CloneStamp.swift), [`BlurTool.swift`](../Compositor/Document/BlurTool.swift), [`MCPTools+Masks.swift`](../Compositor/MCP/MCPTools+Masks.swift), [`MCPPaintToolTests`](../CompositorTests/MCPPaintToolTests.swift), and [`MCPMasksToolTests`](../CompositorTests/MCPMasksToolTests.swift). |
| Mixed-size editable type | PSD imports retain supported color, font and size runs at zero-based UTF-16 offsets. The inline editor, controls, project files, MCP style patch and PSD writer use the same runs. Unsupported character spacing and faux styles still produce a conversion note. | [`TypeTool.swift`](../Compositor/Document/TypeTool.swift), [`InlineTextEditor.swift`](../Compositor/Rendering/InlineTextEditor.swift), [`PSDText.swift`](../Compositor/IO/PSD/PSDText.swift), [`PSDTextWriter.swift`](../Compositor/IO/PSD/Writer/PSDTextWriter.swift), and their `TypeToolTests`, `PSDTextImportTests`, `PSDTextWriterTests` and `MCPTextToolTests`. Adobe documents per-character properties in [UXP TextItem](https://developer.adobe.com/photoshop/uxp/2022/ps-reference/classes/textitem) and [CharacterStyle](https://developer.adobe.com/photoshop/uxp/2022/ps-reference/classes/characterstyle). |
| Solid Color Fill layers | A standalone `SoCo` block without a vector mask imports as a visible full-canvas live rectangle. An unchanged fill keeps its original descriptor; an edited fill writes as a Photoshop rectangle shape. MCP adds `add_solid_fill`; existing `set_shape_style` edits its color. | [`PSDVector.swift`](../Compositor/IO/PSD/PSDVector.swift), [`PSDDocumentBuilder.swift`](../Compositor/IO/PSD/PSDDocumentBuilder.swift), [`MCPTools+Shapes.swift`](../Compositor/MCP/MCPTools+Shapes.swift), and `PSDRoundTripTests`/`MCPShapesToolTests`. Adobe's [Photoshop file-format specification](https://www.adobe.com/devnet-apps/photoshop/fileformatashtml/) describes the layer blocks; Adobe's [manifest migration guide](https://developer.adobe.com/firefly-services/docs/photoshop/guides/photoshop-v2/v1-to-v2/manifest-response-migration) identifies the `solid_color_layer` type. |
| PSD/project preservation | The reader and writer preserve Photoshop blocks, names, masks, text, shapes, effects and smart-object payloads when unchanged; edited output reports lossy conversions before writing. `.comp` keeps the full editable model. | [`PSDReader.swift`](../Compositor/IO/PSD/PSDReader.swift), [`PSDDocumentBuilder.swift`](../Compositor/IO/PSD/PSDDocumentBuilder.swift), [`PSDWriter.swift`](../Compositor/IO/PSD/Writer/PSDWriter.swift), [`ProjectStore.swift`](../Compositor/IO/ProjectStore.swift), and [`docs/psd-export.md`](psd-export.md). |

The MCP contract follows MCP's server-owned `tools/list` definitions and input schemas. The generated atlas is the inspectable client-facing reference; do not hand-edit its content. Its source grouping lives in [`tool-atlas.py`](../skills/compositor/scripts/tool-atlas.py).

## MCP examples

Create a full-canvas fill through `tools/call`:

```json
{
  "name": "add_solid_fill",
  "arguments": {"color": "#244d73", "name": "Backdrop"}
}
```

Create a reveal-selection layer mask after selecting an area. Use `hide_selection` to hide that area instead:

```json
{
  "name": "add_layer_mask",
  "arguments": {"layer": "Photo", "kind": "from_selection"}
}
```

Set a heading with a larger second word. Run offsets are UTF-16 code units, matching Cocoa's text ranges and Photoshop EngineData:

```json
{
  "name": "set_text_style",
  "arguments": {
    "layer": "Headline",
    "style": {
      "size_runs": [{"location": 7, "length": 4, "font_size": 64}],
      "font_runs": [{"location": 7, "length": 4, "font_name": "HelveticaNeue-Bold"}],
      "color_runs": [{"location": 7, "length": 4, "red": 1, "green": 0.55, "blue": 0.1}]
    }
  }
}
```

The MCP tool's schema and handler reject overlapping, out-of-bounds or invalid ranges before editing. One successful mutation records one undo step; `run_batch` can combine several calls into one step. Save a working Photoshop file with `save_document_as`, review its warnings, and pass `allow_lossy: true` only when the caller accepts listed losses.

## Compatibility and behavior

- `.comp` manifest version is 13 because mixed size runs are new saved data. Versions 1–12 still load. Version 13 projects retain `sizeRuns`; an older app that does not understand version 13 refuses it instead of silently discarding styles. The version and gates are in [`ProjectStore.swift`](../Compositor/IO/ProjectStore.swift) and [`project-format.md`](project-format.md).
- `size_runs` is optional in the MCP `set_text_style` patch, so clients that send the previous schema fields keep working. The added `add_solid_fill` tool is additive and does not change existing `add_shape` behavior.
- Solid fills reuse the existing live-shape project representation, so they do not introduce another `.comp` field or manifest bump. On canvas resize or crop, the rectangle moves or clips like other shapes; expand it to the new canvas when the intended Photoshop behavior is a canvas-bound fill.
- PSD import supports 8-bit RGB PSD and PSB. PSD export writes version-1 8-bit RGB PSD. CMYK and 16/32-bit input remain unsupported. Gradient and pattern fill layers remain preserved hidden placeholders; Compositor does not approximate their appearance as a solid color.
- Mixed fonts, colors and sizes remain editable. Per-letter leading, tracking, character scale, faux bold/italic, warp, vertical type and some paragraph behavior remain either noted or pixel-preserved, as described in [`PSDText.swift`](../Compositor/IO/PSD/PSDText.swift) and [`psd-export.md`](psd-export.md).

## Pull-request review order

File one draft PR against upstream `main`. The incoming MCP and Photoshop integration is itself part of this change, so the dependent parity work is kept in the same branch and separated into reviewable commits. Review the commits in this order:

1. **1.4.1 integration baseline** — existing commit `b9a56e9` carries the server, PSD model and writer, app integration, shared project-model changes, tests and install/docs onto upstream `main`; the following test-only commit makes the external-project watcher test wait for its asynchronous notification.
2. **MCP paint and selection-mask parity** — review native-resolution Clone Stamp and Blur sampling, `from_selection`/`hide_selection` behavior, and their paint, pixel, mask and undo tests.
3. **Editable mixed-size text** — review the `sizeRuns` model, format 13 gate, import/render/control/MCP/writer path and malformed-range tests as one vertical feature.
4. **Solid Fill MCP and PSD support** — review standalone `SoCo` import, its preservation/edit path, the `add_solid_fill` tool, tool atlas and examples.

If the maintainer wants separate PRs, split the follow-ups after the baseline has landed in upstream `main`; then retarget each feature branch to the newly integrated code and rerun the relevant suite. Do not force-push over an upstream or owner update; rebase the working branch and rerun the relevant suite.

## Verification checklist

Run from the repository root with an isolated DerivedData path and signing disabled in a development environment without a signing certificate:

```sh
xcodebuild -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/compositor-dd CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/compositor-dd CODE_SIGNING_ALLOWED=NO test
python3 skills/compositor/scripts/tool-atlas.py --check
```

For Photoshop acceptance, use anonymized copies: open the PSD in Photoshop, compare its flattened render with Compositor's, inspect the imported fill and text layer editability, save a copy from Compositor, reopen it, then re-typeset only the changed text. Record the app version, fixture hash and comparison thresholds outside client-data repositories. This acceptance run has not passed yet; the previous native harness stopped at System Events preflight, and automated PSD parsing is not a substitute.

## Remaining measured Photoshop gaps

The current parity notes are measured differences, not product promises. [`psd-export.md`](psd-export.md#known-differences) records Color Balance intensity, Hue/Saturation Master Lightness, Black & White tint and Gradient Map differences, along with text re-typesetting drift. Do not bundle unmeasured corrections into the import/MCP feature PRs. For each adjustment follow-up, add a Photoshop-generated fixture, compare channel values and gradients across ranges, preserve imported bytes when untouched, and add both positive and negative tests before changing the renderer.
