# Testing

How Compositor's tests are written and run, the helpers to reuse, and the traps that have
cost this project time. Commands to build and run are in the skill's main file.

## Contents

- [Swift Testing conventions](#swift-testing-conventions)
- [MCP tool tests with MCPTestSupport](#mcp-tool-tests-with-mcptestsupport)
- [Server, transport and bridge tests](#server-transport-and-bridge-tests)
- [PSD tests with PSDFixture](#psd-tests-with-psdfixture)
- [Project round trips](#project-round-trips)
- [Preferences](#preferences)
- [The app is the test host](#the-app-is-the-test-host)
- [macOS privacy and cloud files](#macos-privacy-and-cloud-files)
- [Known failures and slow tests](#known-failures-and-slow-tests)
- [Parallel worktrees](#parallel-worktrees)

## Swift Testing conventions

- `import Testing` and `@testable import Compositor`; one suite type per feature, in
  `CompositorTests/<Feature>Tests.swift`. The file system synchronizes the folder into the
  target, so a new file needs no project edit.
- Name tests as sentences about behavior: `@Test func deletingAFolderBakesLayersClippedToIt()`.
  The name is the failure report, so say what must be true.
- `#expect(condition, "message")` for checks, `try #require(optional)` to unwrap or stop,
  `@Test(arguments: [...])` for a table of cases.
- Put `@MainActor` on a suite that touches `EditorSession`, `ProjectWorkspace`,
  `MCPToolRegistry` or other app types: the test target is not main-actor by default. Keep
  a suite nonisolated when parts of it must not wait for the main actor (as
  `MCPBridgeTests` does, isolating only the one test that needs it).
- Add `@Suite(.serialized)` when tests share process-wide state: the system pasteboard
  (`SelectionClipboardTests`), cursors, floating panels, global overrides.
- Assert observable behavior: pixels, saved files, undo and redo, error codes, what a
  second open reads back. A test that only restates the implementation catches nothing.
- Use temporary folders (`FileManager.default.temporaryDirectory` plus a UUID) and remove
  them in a `defer`; never a fixed path, and never the repository.

## MCP tool tests with MCPTestSupport

`CompositorTests/MCPTestSupport.swift` (a `@MainActor` enum) is the harness for tool tests:

| Helper | What it gives you |
|---|---|
| `workspace(width:height:)` | A `ProjectWorkspace` whose first tab already has a 640×480 (or given) document. |
| `call(_:_:in:expectError:)` | Calls `MCPToolRegistry.call` and checks the result's shape: success (`isError != true`), or `isError == true`, `ok == false` and `error.code` equal to `expectError`. Returns the `structuredContent` object. |
| `tempFile(_:)` | A path in a fresh temporary folder, for tools that read or write files. |
| `agentRootOverride` | The temporary folder installed as the Agent folder for the whole test process. |

Both `workspace` and `call` first install a temporary Agent folder through
`MCPSettings.agentRootOverride`, so relative paths and `list_files` never touch the real
`~/Library/Application Support/Compositor/Agent`. Go through them rather than calling
handlers directly.

```swift
@MainActor struct MCPLayerNoteToolTests {
    @Test func settingANoteIsOneUndoStep() async throws {
        let workspace = MCPTestSupport.workspace()
        let added = try await MCPTestSupport.call("add_blank_layer", ["name": "Headline"], in: workspace)
        let id = try #require(added["layer_id"]?.stringValue)

        let result = try await MCPTestSupport.call("set_layer_note", ["layer": .string(id), "note": "Check spelling"], in: workspace)
        #expect(result["undo"]?.objectValue?["recorded"] == .bool(true))

        try await MCPTestSupport.call("undo", in: workspace)
        #expect(workspace.current.session.document?.layers.last?.note == nil)
    }

    @Test func anUnknownLayerIsNotFound() async throws {
        let workspace = MCPTestSupport.workspace()
        try await MCPTestSupport.call("set_layer_note", ["layer": "Nope", "note": "x"], in: workspace, expectError: "not_found")
    }
}
```

(`set_layer_note` and `note` are invented for the example.) Arguments are MCP `Value`s;
string, number and boolean literals convert on their own, `.string(id)` wraps a variable.

`MCPRegistryTests` checks every registered tool automatically: names are unique lower
snake case, and a call with `{}` reaches a real handler without writing to the real Agent
folder. A new tool is covered the moment it is registered; add it to
`toolsSkippedForEmptyArgsCall` only if calling it with no arguments has a real effect
outside the test (as `reveal_in_finder` opens Finder).

## Server, transport and bridge tests

- A real server: `MCPServer(options: .init(preferredPort: 0, endpointFileURL: MCPTestSupport.tempFile("mcp/endpoint.json")))`,
  set `server.workspace`, `try await server.start(reason: .session)`, and
  `defer { server.stop() }`. Port 0 binds a free ephemeral port; the temporary endpoint
  file keeps the real one untouched. Never use `MCPServer()` in a test: its production
  options bind 2667 and write the real endpoint and access token files. The test options
  require no token unless a test opts in (`requiresToken: true`, with a `tokenFileURL` in a
  temporary folder, or none to keep the token in memory); `MCPAccessTokenTests` shows how,
  and uses `Options.production(defaults:applicationSupport:)` with its own defaults suite
  and folder to check the app's settings.
- `MCPBridgeTests` runs the embedded `compositor-mcp` binary (`BridgeProcess`) against an
  in-process server, always with `--no-launch` and a temporary `--endpoint-file` or an
  explicit ephemeral `--endpoint` (with a temporary `--token-file` when the server requires
  a token), so it never launches or signals a real Compositor or reads the real token.
- `MCPTransportTests`, `MCPRequestIDTests` and `MCPEndpointFileTests` cover the HTTP layer,
  id isolation and the endpoint file; follow their setup for anything at that level.

## PSD tests with PSDFixture

`CompositorTests/PSDFixture.swift` writes tiny, valid Photoshop files for reader tests.
It is test scaffolding, not the app's PSD writer. Build a `PSDDocument` of `PSDRecord`s,
turn it into bytes, and run the real import path:

```swift
var record = PSDRecord(id: UUID(), name: "Headline")
record.bounds = CGRect(x: 100, y: 60, width: 120, height: 40)
record.image = try raster(width: 120, height: 40)        // a CGImage helper in the suite
record.extras = PSDLayerExtras(blocks: [
    PSDTaggedBlock(key: "TySh", data: PSDFixture.typeToolBlock(text: "Sample headline", font: "HelveticaNeue", fontSize: 24)),
])
let data = try PSDFixture.data(PSDDocument(width: 400, height: 200, resolution: 72, layers: [record]),
                               composite: try raster(width: 400, height: 200))
let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
let session = EditorSession()
try session.insertPhotoshop(imported, named: "Fixture")
```

- Beyond the modeled fields, the fixture writes whatever you put in `record.extras`
  (tagged blocks, blending ranges, flags, clipping and filler bytes, mask fields, trailing
  bytes, a folder's divider extras), `fillOpacity` (`iOpa`), `locks` (`lspf`), the colour
  label (`lclr`), and document extras (resources, global layer mask info, document blocks,
  a negative layer count).
- Block builders: `typeToolBlock(text:font:fontSize:color:justification:leading:tracking:transform:box:runs:…)`
  (a `TySh` with real EngineData), `engineData(_:)`, and resources such as
  `guidesResource(vertical:horizontal:)`, `iccProfileResource(description:)`,
  `globalLightAngleResource(_:)`, `alphaChannelNamesResource(_:)`.
  `PSDVectorFixtures.circle()` / `.rectangle()` give the blocks of a live shape layer.
- Use synthetic names and text ("Headline", "Endorser Name", "Sample headline"). Real
  client PSDs are never committed, and tests must not depend on files outside the repo.

## Project round trips

Every persisted feature needs a test that saves and reopens a `.comp`:

```swift
let url = root.appendingPathComponent("Round Trip.comp")          // root: a temporary folder
try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
let reopened = EditorSession()
reopened.installProject(try await ProjectStore.shared.load(from: url), from: url)
#expect(reopened.document?.layers.map(\.psdExtras) == session.document?.layers.map(\.psdExtras))
```

Add a rejection test too: a manifest declaring an older version that carries the new
field must fail to load (see [PSD features and the .comp format](psd-and-projects.md)).

## Preferences

Code that reads settings takes a `UserDefaults` parameter (as `MCPSettings.port(in:)` and
`setPort(_:in:)` do) so tests can pass their own suite:

```swift
let suite = "MyFeatureTests-\(UUID())"
let defaults = try #require(UserDefaults(suiteName: suite))
defer { defaults.removePersistentDomain(forName: suite) }
```

Never write `UserDefaults.standard` from a test: the test host is the app, so its
standard defaults are the user's real Compositor preferences.

## The app is the test host

`xcodebuild test` launches `Compositor.app` and loads the tests into it. So:

- `CompositorApplicationDelegate.isHostingTests` (true when `XCTestConfigurationFilePath`
  is set) turns off launch work that touches real state: `launchTasks(isHostingTests:)`
  returns no preference migration and no MCP management (no stale-file cleanup, no
  auto-start, no start-notification observer). Route any new launch-time side effect
  through the same switch, and extend the test of `launchTasks` in
  `PreferencesMigrationTests`.
- Anything the app does at launch happens once per test run, in the real user account.
  Before the guard existed, a test run migrated the real preferences. The test host still
  opens the editor window, and AppKit saves that window's frame to the real preferences.
- The test host is a separate process per run. Two runs at once (two worktrees, or a
  worktree and the owner's own Compositor) are two Compositor processes sharing one
  preferences domain, one pasteboard and one Application Support folder.

## macOS privacy and cloud files

- macOS Files & Folders privacy guards Documents, Desktop, Downloads, iCloud Drive and
  cloud providers under `~/Library/CloudStorage`. A read there from the test host (or a
  development build) waits on a consent prompt, possibly on a screen nobody is watching;
  one corpus probe hung for six hours this way. Sandbox removal doesn't change this.
- Copy inputs to `/private/tmp` (from a shell that already has access) and point tests or
  probes at the copies; write reports and renders there too, never in the repository.
- A cloud file may be a placeholder whose bytes aren't on disk; reading it triggers a
  download that can stall indefinitely. `ls -lO <file>` lists `dataless` for such files.
- Unsigned or ad hoc signed development builds are separate apps to privacy settings:
  grants given to the installed Compositor don't cover them.
- Keep opt-in corpus or probe runs bounded (a timeout per file) so one stuck file can't hold
  a run for hours.

## Known failures and slow tests

- `SliderSnapTests/clickingTheTrackSnapsTheKnobAndStillEditsTheValue()` fails on its own
  (`sliders(hosting).first` is nil) and predates current work. Treat it as known; don't
  "fix" it inside an unrelated change.
- `SelectionClipboardTests` uses the one system pasteboard. It is serialized within a run,
  but a second test run at the same time (another worktree) can change the pasteboard
  under it. Re-run the suite alone before investigating.
- A couple of `ProjectTests` take close to a minute each (large packages, failure paths);
  the full suite takes several minutes. Run focused suites while iterating.
- To tell your regression from an old failure, run the same suite at the base commit in
  its own worktree and DerivedData.

## Parallel worktrees

- One DerivedData per worktree (`-derivedDataPath`), never shared and never the default
  `~/Library/Developer/Xcode/DerivedData` when several checkouts build at once.
- Name logs and scratch folders after the worktree (`/private/tmp/compositor-dd-<name>-test.log`)
  so runs don't overwrite each other's evidence.
- Expect pasteboard, preferences and Application Support to be shared between concurrent
  test hosts; keep tests off them (temporary suites, temporary folders, port 0).
- Stay inside your own worktree: never edit, reset or clean a sibling's files, and commit
  only the paths your task owns.
