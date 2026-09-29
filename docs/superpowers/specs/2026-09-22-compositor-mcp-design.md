Design spec for the Compositor MCP + PSD round-trip work. The full task-level plan is kept alongside the implementation history in git.

# Compositor MCP: Full Agent Autonomy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give an AI agent full, unattended control of Compositor over the Model Context Protocol, and make Compositor able to open, edit and save back the layered Photoshop files Red Hills Media actually produces (text, smart objects, shapes, effects, groups, masks, guides, locks), so the current Photoshop + ExtendScript pipeline can be replaced.

**Architecture:** Compositor already carries an uncommitted, compiling MCP server (official `modelcontextprotocol/swift-sdk` 0.12.1, Streamable HTTP on a loopback listener, 35 tools). This plan (1) fixes three live model bugs, (2) removes the App Sandbox and finishes the server's connection story (stable port, endpoint file, stdio bridge, stateless transport, document and layer selectors, image previews), (3) extends the document model and PSD reader so every feature in the real PSD corpus survives import as editable data, (4) completes the tool surface over every Compositor operation, and (5) adds a PSD writer with preserve-by-default round-tripping, verified with psd-tools and the installed Photoshop 2026.

**Tech Stack:** Swift 5 mode (SwiftUI + AppKit, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), Xcode 26 beta, macOS 26.5 deployment target, Swift Testing for unit tests, `modelcontextprotocol/swift-sdk` 0.12.1, Network.framework loopback HTTP listener, Sparkle 2.10 (Developer ID + notarization distribution), Python `psd-tools` via `uv run --with psd-tools` and Photoshop 2026 (27.8) via ExtendScript for verification only.

**Spec:** This document is the spec and the plan (plan mode allows one file). Task 0 copies it into the repo at `docs/superpowers/specs/2026-09-22-compositor-mcp-design.md` so the spec travels with the code.

---

## Context

### Why
Kyle's agents currently build campaign graphics (endorsement templates, mail pieces, MMS graphics, ad variants) by driving Photoshop 2026 with ExtendScript through a `photoshop-control` MCP server. The scripts open PSDs from Google Drive and iCloud, create and edit text layers by PostScript font name, measure bounds to center and fit text, fill shapes, place photos and logos, set clipping masks, and save layered PSD plus PNG/JPEG. The goal is for Compositor to do that job natively, driven by any MCP client, with no human in the loop.

### What exists today (verified 2026-09-22)
- **Compositor** is a native `.comp` editor (~26k lines, 330 Swift Testing tests). It **imports** PSD (8-bit RGB only, no PSB) and **cannot write PSD**. On import: text layers become pixels, smart objects are rasterized, layer effects are discarded, 13 of 16 recognized adjustment kinds cause the layer to be dropped, and all unknown blocks are parsed into `RawLayer.extra` and thrown away. Files: `Compositor/IO/PSD/*.swift`, `Compositor/IO/ProjectStore.swift`, model in `Compositor/Document/EditorSession.swift`.
- **MCP branch** `feat/mcp-server`: 7 uncommitted files in `Compositor/MCP/` (1,986 lines) plus wiring diffs. Compiles (`BUILD SUCCEEDED`). 35 tools, all implemented, none tested. Gaps: ephemeral port with no discovery file, no stdio bridge, mutating tools ignore the document index, layers addressed only by UUID, previews returned as base64 text instead of image content, no tool annotations, six non-Sendable capture warnings in `MCPHTTP.swift`, `try!` in `MCPToolRegistry.result`, no docs.
- **Sandbox**: `com.apple.security.app-sandbox` with only user-selected file access. Tools are confined to `~/Library/Containers/com.wonderassembly.compositor/Data/Library/Application Support/Compositor/Agent/`. This blocks the real workflow (Google Drive, iCloud, `~/Documents`).
- **Corpus** (34 most recently edited PSDs, 574 layers, all RGB 8-bit PSD v1): 239 text layers (legacy `TySh`, point + 16 paragraph, scale-only transforms, manual leading), 89 embedded smart objects (`SoLd`+`PlLd`, payloads in document `Lnk2`: svg 42, png 22, embedded PSB 15, eps 5, jpeg 4, psd 1), 24 shape layers (lines 13, ellipses 4, rects 2; `vstk` present but stroke disabled), 48 effect layers in 6 files (Color Overlay, Drop Shadow, Stroke; some disabled), 2 groups (pass-through), locks `lspf`=13 on 22 files, raster masks 9, vector masks 24, guides + ICC + XMP + EXIF + slices on every file, 300 DPI print pieces up to 132 MB. **No adjustment layers, no fill layers, no blend modes other than Normal/pass-through.**
- **Fonts**: CoreText on this Mac lacks Kanit-* and Jubilat* (used on most corpus text). InstrumentSerif, SFPro-*, HelveticaNeue and TimesNewRomanPSMT are available. Untouched imported text keeps its Photoshop raster, so only *edited* text is affected; the plan adds font checking and substitution reporting.
- **Clients on this Mac**: Claude Code 2.1.280 (user-scope MCP servers: agent-peers, app-store-connect, portclaim), Codex CLI 0.155.1 (`~/.codex/config.toml`, has `photoshop-control` and an HTTP server entry), Claude Desktop (config present, no servers). Port registry (`portclaim`) has only port 8000 claimed.

### Owner decisions (2026-09-22, do not reopen)
1. **Full editable PSD export**, built in phases, verified by re-opening in Photoshop 2026.
2. **Remove the App Sandbox.** Distribution stays Developer ID + notarization + Sparkle. Tools may read and write any path Kyle can.
3. **Clients out of the box:** Claude Code and Codex CLI (Streamable HTTP) and Claude Desktop / Cowork (stdio bridge).
4. **No priority ordering imposed**; phases are ordered by dependency and risk below.

### Decisions made in this plan (routine engineering calls)
- **No authentication** on the MCP endpoint: loopback binding plus Origin/Host validation. Any local process running as Kyle can already do everything the server can. Stated explicitly in `docs/mcp.md`.
- **Stateless Streamable HTTP** (`StatelessHTTPServerTransport`): several clients at once (Claude Code + Codex), no session-renewal hack. Tool calls stay serialized on the main actor.
- **Default port 2667** ("COMP" on a phone keypad), configurable in Settings, ephemeral fallback if busy. The implementer verifies it is free (`lsof -nP -iTCP:2667`, `portclaim_find`) and registers a persistent `portclaim` claim `compositor-mcp` for this machine.
- **Endpoint file** `~/Library/Application Support/Compositor/mcp/endpoint.json` written on start, removed on stop.
- **Every tool takes an optional `document`** (UUID or tab index; default current). **Layers are addressed by `layer`** (UUID, exact unique name, or `Group/Child` path). Ambiguity is an error listing candidates.
- **Previews are MCP image content** (PNG, `max_size` default 1024) so the agent can see its work.
- **Safety defaults:** never overwrite an existing file without `overwrite: true`; `close_document` needs `discard_changes: true` to drop unsaved work; every mutating tool is one undo step; tab cap 32.
- **Preserve-by-default PSD round trip:** unedited imported layers re-emit their original tagged blocks byte-for-byte; synthesized blocks are written only for new or edited layers.
- **Private client PSDs are never committed.** Corpus tests run only when `COMPOSITOR_PSD_CORPUS` points at a local folder.
- **Publishing a release (Sparkle appcast, GitHub release) is out of scope** until Kyle explicitly authorizes it; the plan ends at a release-ready branch.

### Live bugs found during exploration (fixed in Phase 0)
1. `Compositor/IO/ProjectStore.swift:14` writes manifest `version = 9`; `:142` rejects anything above 8 on read (`guard (1...8).contains(header.version)`), and the `.version` error text says "1–8". **Files saved by this build cannot be reopened.**
2. `EditorSession.applyDocumentSize(_:actionName:)` (`Compositor/IO/ImageResizer.swift` ~118) rebuilds layers without `shape:`, `effects:`, `text:`, and the `ProjectLayerRecord` built for resizing omits them too. **Canvas Size, Image Size and Crop silently rasterize live shapes and editable text and drop layer effects.**
3. `ProjectWorkspace.copyLayer` (`Compositor/Document/ProjectWorkspace.swift:197-199`) omits `effects:` when copying layers between projects.

---

## Global Constraints
- Swift language mode stays 5.0 with `SWIFT_APPROACHABLE_CONCURRENCY = YES`; new code must be warning-free under `-strict-concurrency=complete` semantics (no non-Sendable captures in `@Sendable` closures).
- Deployment target macOS 26.5; Xcode 26 beta (`/Applications/Xcode-beta.app`).
- Test framework: Swift Testing (`@Test`, `#expect`) in `CompositorTests/`; build/test command:
  `xcodebuild test -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' -derivedDataPath /private/tmp/claude-501/-Users-kyle-Development-Compositor/1bb2fb80-6fee-4070-9856-fea485b02101/scratchpad/DerivedData CODE_SIGNING_ALLOWED=NO -only-testing:CompositorTests/<Suite>`
- Compositor remains 8-bit sRGB RGB; PSD v1 only (no PSB, 16/32-bit, CMYK) as top-level documents.
- `.comp` manifest changes bump `ProjectManifest.version` to 10 and extend `docs/project-format.md` plus round-trip tests ("Future editable features must extend the schema and round-trip tests").
- Never print secrets; never commit client PSDs; keep `Package.resolved` pins at `upToNextMinor` from 0.12.1.
- Commit after every task (small commits, conventional messages, attribution line `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).

---

## Phase map

| Phase | Goal | Depends on | Ships |
|---|---|---|---|
| 0 | Baseline commit, three bug fixes, sandbox removal, test scaffold | — | A build that reopens its own files and can touch any path |
| 1 | MCP connection story and hardening: stateless transport, multi-client, selectors, image previews, stable port, endpoint file, stdio bridge, docs | 0 | Claude Code, Codex and Claude Desktop drive the existing 35 tools reliably |
| 2 | Model + `.comp` v10 + PSD import fidelity: text, effects, smart objects, lines, guides, locks, fill opacity, opaque block preservation, headless open | 0 | Corpus PSDs open with every feature editable or preserved |
| 3 | Complete MCP tool surface over every Compositor operation, plus the new session commands agents need (align, fill with color, fit text, flatten, rasterize, apply mask, batch) | 1, 2 | Full autonomy over `.comp` and imported PSD documents |
| 4 | PSD writer with preserve-by-default round trip; Save As PSD in the app and over MCP; psd-tools + Photoshop verification | 2 | Layered PSDs Photoshop 2026 opens with editable text, shapes, effects, smart objects |
| 5 | Breadth and polish: remaining adjustment parsers/writers, view tools, tool-list budget, instructions, release readiness | 3, 4 | Release-ready branch (publishing waits for Kyle) |

Phases 1 and 2 are independent and can run in parallel worktrees; Phase 3 domain tasks are independent of each other once Task 1.3 (selectors) lands; Phase 4 tasks are sequential.

Run-command template used by every task (`$SCRATCH` is the session scratchpad DerivedData path from Global Constraints):

```bash
xcodebuild test -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' \
  -derivedDataPath "$SCRATCH" CODE_SIGNING_ALLOWED=NO -only-testing:CompositorTests/<Suite>
```

---
