---
name: compositor-development
description: How to change the Compositor codebase safely — the native macOS image editor with an embedded MCP server, Photoshop PSD import and the .comp project format. Covers the architecture, build and test commands with an isolated DerivedData, Swift 5 and MainActor conventions, Swift Testing patterns (MCPTestSupport, PSDFixture), adding an MCP tool or a PSD feature end to end, .comp versioning, preserve-by-default Photoshop fidelity, known flaky tests and macOS privacy and test-host pitfalls. Use this whenever you edit, build, test, debug or review code in a Compositor checkout (Compositor.xcodeproj, Compositor/, CompositorTests/, Tools/compositor-mcp, scripts/psd-*.py), even for a one-line fix, and whenever a task names EditorSession, ProjectWorkspace, MCPToolRegistry, PSDReader, ProjectStore or the .comp format.
---

# Compositor development

Compositor is a native macOS image editor (SwiftUI and AppKit, Swift 5 language mode, macOS
26.5+) built around a Photoshop-style layer model. Three things set it apart and shape most
changes: an **embedded MCP server** that lets agents drive the same document model and undo
stack as the UI, a **PSD reader** that keeps everything a Photoshop file holds so it can be
written back, and the **`.comp` package format** (version 11) that stores all of it.

Read this file first, then only the reference your change needs:

| Changing… | Read |
|---|---|
| Where code lives, how a document flows from file to canvas to disk | [Architecture](references/architecture.md) |
| Any test, flaky results, test-host or macOS privacy trouble, parallel worktrees | [Testing](references/testing.md) |
| An MCP tool (new or changed), the server, the bridge | [Adding an MCP tool](references/mcp-tools.md) |
| PSD import, the `.comp` format, Photoshop round-trip fidelity | [PSD features and the .comp format](references/psd-and-projects.md) |

The code on your branch is the ground truth. Plans, docs and this skill can lag it; when
they disagree, trust the code, and fix the doc as part of your change.

## Ground rules

These exist because breaking them has cost real time or real data on this project.

- **Build into your own DerivedData.** Pass `-derivedDataPath` to every `xcodebuild`, one
  folder per checkout or worktree. A shared DerivedData lets two checkouts overwrite each
  other's products and test host mid-run, and the failures that follow look like code bugs.
- **Never touch the user's real Compositor state from code or tests.** That means
  `~/Library/Application Support/Compositor` (the Agent folder, the MCP endpoint file and the
  access token file),
  the app's real preferences (`com.wonderassembly.compositor`), and port 2667. The owner's
  own Compositor may be running and serving agents on that port and file right now. Tests
  use temporary folders, their own `UserDefaults(suiteName:)`, and port 0 (see
  [Testing](references/testing.md)).
- **Remember the app hosts the unit tests.** `xcodebuild test` launches Compositor itself
  as the test host. `CompositorApplicationDelegate.isHostingTests` (set from
  `XCTestConfigurationFilePath`) skips the preference migration and everything MCP does at
  launch; any new launch-time work that touches real files, defaults, ports or the network
  must be skipped the same way (`launchTasks(isHostingTests:)`).
- **Never read the owner's files in place from tests or probes.** Folders such as Documents,
  Desktop, Downloads, iCloud Drive and `~/Library/CloudStorage` sit behind macOS privacy
  prompts (a test host blocked on one hung for hours) and cloud placeholders can stall a
  read. Copy inputs to a temporary folder first. Client PSDs never enter the repository,
  and client names, text or file names never appear in code, tests, docs or commit messages.
- **Leave no new warnings.** A few warnings predate current work (in `LayerEffects.swift`,
  `FloatingSelection.swift` and `TiledLayerTests.swift` at the time of writing); every
  `warning:` line in a file you touched is yours to fix.
- **Keep docs in step.** `docs/mcp.md` (tools, errors, limits), `docs/project-format.md`
  (the `.comp` schema) and `docs/psd-export.md` (PSD verification) describe the code;
  change them in the same commit as the behavior.

## Build and test

Run each block below as one command, as written. Every block starts by setting `REPO` (the
checkout) and `DD` (that checkout's own DerivedData) because agent shells keep nothing
between commands: Claude Code, Codex and `claude -p` start a fresh shell each time, so a
variable set in an earlier command is empty in the next one. A block run without its first
two lines builds `-project "/Compositor.xcodeproj"` into `-derivedDataPath ""` and writes a
log named `-build.log` into the current folder. The first line finds the checkout from the
working directory; if your shell may start somewhere else, put the checkout's absolute path
there instead.

Build the app (and the embedded `compositor-mcp` bridge):

```bash
REPO=$(git rev-parse --show-toplevel)             # the checkout you are working in
DD=/private/tmp/compositor-dd-$(basename "$REPO") # this checkout's own DerivedData
xcodebuild build -project "$REPO/Compositor.xcodeproj" -scheme Compositor \
  -destination 'platform=macOS' -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO > "$DD-build.log" 2>&1
grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" "$DD-build.log" | sort -u | tail -40
```

Run one suite (a Swift Testing suite is its type name), or one test inside it:

```bash
REPO=$(git rev-parse --show-toplevel)
DD=/private/tmp/compositor-dd-$(basename "$REPO")
xcodebuild test -project "$REPO/Compositor.xcodeproj" -scheme Compositor \
  -destination 'platform=macOS' -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO \
  -only-testing:CompositorTests/MCPRegistryTests > "$DD-test.log" 2>&1
# one test: -only-testing:'CompositorTests/MCPRegistryTests/everyToolNameIsUniqueAndLowerSnakeCase()'
grep -E "error:|Test case '.*' failed|Failing tests|TEST (SUCCEEDED|FAILED)" "$DD-test.log" | tail -40
grep -c "Test case '.*' passed" "$DD-test.log"
```

- Write the log to a file and grep it. A full log runs to thousands of lines and buries
  the one failure you need.
- Each test prints `Test case 'Suite/test()' passed|failed on …`; the run ends with
  `** TEST SUCCEEDED **` or a `Failing tests:` list and `** TEST FAILED **`. The log doesn't
  say *why* a test failed; the newest result bundle does:

  ```bash
  REPO=$(git rev-parse --show-toplevel)
  DD=/private/tmp/compositor-dd-$(basename "$REPO")
  xcrun xcresulttool get test-results summary --path "$(ls -td "$DD"/Logs/Test/*.xcresult | head -1)"
  ```

  Its `testFailures[].failureText` holds each failed `#expect` or `#require`, with values.
- `-only-testing:CompositorTests` runs the whole unit suite (several minutes). Run the
  suites you touched while iterating, and the whole suite once before you commit.
  `CompositorUITests` drives the real UI and is not part of routine runs.
- Python tests for the scripts in `scripts/` (PSD verification, skills, install):
  `uv run --with psd-tools python3 -m unittest discover -s scripts/tests`.

**Known failures.** `SliderSnapTests/clickingTheTrackSnapsTheKnobAndStillEditsTheValue()`
fails on its own and predates current work; count it as known, not as yours. A
`SelectionClipboardTests` failure while other test runs are going on (another worktree, a
second terminal) is usually two runs sharing the one system pasteboard: re-run that suite
alone before debugging it. Anything else that fails is yours until shown otherwise; check by
running the same suite on the base commit.

## Conventions

- **Concurrency.** The app target uses Swift 5 mode with `SWIFT_DEFAULT_ACTOR_ISOLATION =
  MainActor` and approachable concurrency: everything is main-actor unless marked. Mark pure
  value types, file formats and anything used off the main actor `nonisolated` (as
  `MCPEndpointFile`, `PSDReader` and `ProjectLayerRecord` are). The test target does *not*
  default to the main actor: put `@MainActor` on suites that touch `EditorSession`,
  `ProjectWorkspace` or MCP tools. The `compositor-mcp` bridge builds with complete strict
  concurrency and must stay dependency-free (Foundation and AppKit only).
- **Project files.** `Compositor/`, `CompositorTests/`, `CompositorUITests/` and
  `Tools/compositor-mcp/` are file-system-synchronized groups: a new `.swift` file there is
  part of its target with no `project.pbxproj` edit. Touch `project.pbxproj` only for build
  settings, packages or targets.
- **One undo step per user action.** Every document mutation sits between
  `session.beginEdit("Name")` and `session.endEdit()` (nestable; only the outermost pair
  records), which is how both a menu command and an agent's tool call become one ⌘Z.
- **Guards before edits.** `EditorSession` exposes `can…` properties (`canEditLayers`,
  `canStartProjectOperation`, `canPaint`, …) that are false while a modal edit, dialog,
  import or long operation holds the document. Check the matching one before mutating, in
  UI and tools alike.
- **One mapping each way.** Layers become saved records and back only through
  `ProjectLayerRecord(layer:)` and `ImageLayer(record:snapshot:)` in
  `Compositor/Document/ImageLayer+Record.swift`; Image Size, Canvas Size, Crop, copies and
  saving all go through them. A new layer property that isn't added there is silently lost
  by some operation.
- **Files by feature.** `EditorSession+<Feature>.swift` and `<Feature>.swift` in
  `Compositor/Document/` extend the session; MCP tools live in
  `Compositor/MCP/MCPTools+<Domain>.swift`; PSD code in `Compositor/IO/PSD/`. Follow the
  neighbour's shape.
- **Comments say why**, in full sentences, with the constraint or decision behind the code;
  public types and non-obvious functions get a `///` summary. Match the existing tone.
- **Limits are shared, in `DocumentLimits`.** 30,000 px per side and 200 megapixels in any
  one surface (canvas, export, layer, filter target); a document's layers together, and its
  masks on their own, within `documentPixelBudget`, which scales with the Mac's memory
  (200–800 MP); 10,000 layers (`LayerLimitError.maximum`). Canvas, import, resize and export
  all enforce them, new entry points must too, and tests use the constants rather than
  numbers, since the budget differs between Macs.

## Before you commit

1. The suites you touched pass, then the whole `-only-testing:CompositorTests` run passes
   apart from the known failure above.
2. No new `warning:` lines in the build log for files you changed.
3. Docs that describe what you changed are updated (`docs/mcp.md`,
   `docs/project-format.md`, `docs/psd-export.md`, `README.md` features).
4. `git status` shows only files you meant to change: no DerivedData, logs, `__pycache__`
   (the Python script tests leave one in `scripts/tests/`), scratch PSDs, renders or
   reports. Test outputs and verification renders belong in `/private/tmp`.
5. Nothing client-identifying anywhere in the diff; tests use synthetic names such as
   "Headline" or "Endorser Name".
