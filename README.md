# Compositor

Adobe Photoshop costs too much and tools like GIMP don’t feel familiar enough for me to stay in flow. That’s why I built Compositor.

The goal was to create a full-featured image editor that is completely free and open source. I used to use Photoshop for compositing and post-processing, so Compositor is built around that workflow - with the tools needed to create a pixel-perfect final image.

Because it’s open source, you can download the Xcode project and add, remove, or modify any feature to fit your workflow.

## Installation

### Download
Get Compositor from [robbietilton.com/compositor](https://robbietilton.com/compositor), or download the latest release directly from [GitHub Releases](https://github.com/robbietilton/Compositor/releases/latest).

### Homebrew

```sh
brew install --cask robbietilton-compositor
```

## Features

### Layers
- Layers and folders, with opacity and Photoshop's full set of blend modes in its order — a folder's opacity dims everything inside it
- Layer masks: paint, fill, invert, blur and feather them anywhere on the canvas, past the layer's own pixels; link or unlink them to transform a mask on its own
- Clipping masks and folder masks
- Adjustment layers: Levels, Curves, Hue/Saturation, Exposure, Color Balance, Black & White, Invert, Gradient Map, Grain, Gaussian Blur, Motion Blur, Add Noise and Profile
- Layer effects: Stroke, Drop Shadow, Color Overlay, Inner Shadow, Outer Glow and Inner Glow, rendered on the GPU and editable at any time
- Merge Down, Merge Layers and Merge Group (⌘E)
- Duplicate, rename inline, reorder and nest by drag and drop; Option-drag to duplicate; a right-click menu in the Layers panel
- Copy and paste whole layers and folders (⌘C/⌘V with no selection), within a project or between projects, or drag them between projects

### Transform
- Non-destructive move, scale, rotate and flip — images keep their full resolution however small you make them
- Free distort (⌘-drag a handle), with Shift to lock to an axis
- Transform several layers, or a whole folder, together
- Snapping to canvas and layer edges and centers, with guides
- Exact values for position, size, scale and angle, stepped with the arrow keys
- Flip Layer and Flip Canvas, horizontal and vertical

### Selections
- Rectangle and Ellipse Marquee, Freehand and Polygonal Lasso, and the Magic tool — Wand selects by color, Object traces whatever you click (Tab switches)
- Select Subject, and Expand, Contract and Feather on any selection
- Add to and subtract from selections, move the outline, or move and duplicate the pixels inside
- Load a layer's pixels or a mask as a selection
- Content-Aware Fill, which can also extend an image past its edges

### Painting and retouching
- Brush with size, hardness, opacity and smoothing, in Paint or Erase mode (B and E), and Shift for straight lines
- Spot Healing Brush (content-aware)
- Clone Stamp, aligned or not, sampling one layer or all of them
- Blur tool, on pixels or masks
- Gradient tool and Shape tool (rectangles, rounded rectangles, ellipses and lines), which stay editable rather than being rasterized
- Type tool (T): inline multiline editing in draggable, resizable paragraph boxes; font, size, color, alignment and spacing in the tool header; transform text and use it as a clipping mask
- Eyedropper and a full color picker

### Adjustments and filters
- Camera Raw filter: light, color, curves, color mixer, color grading, detail, optics and geometry, in a panel beside the canvas
- Levels (with Auto), Curves, Hue/Saturation, Exposure, Gradient Map, Grain, Black & White, Color Balance and Invert
- Gaussian Blur and Motion Blur that spread past a layer's edges
- Add Noise, Vignette, Bloom / Glow, Tonal Contrast, Lens Correction and Remove Background
- Live previews, limited to the selection when there is one
- Lightroom and Camera Raw creative profiles as a Profile adjustment layer: browse the profiles Lightroom and Camera Raw installed, or import your own `.xmp` files, preview each one on the image, and set its amount from 0 to 200%. A project embeds the profiles it uses, so it looks the same on another Mac. See [`docs/profiles.md`](docs/profiles.md)

### Canvas and files
- Multiple projects in tabs
- Rulers (⌘R), guides dragged from them, a layout grid with adjustable spacing and subdivisions, and Snap To for guides, grid, layers and document bounds
- Crop with snapping, ratios including 3:4 and 9:16, and Option for symmetric cropping; with a selection, the crop starts at it
- Canvas Size, Image Size and Trim
- Sharp high-quality downsampling when zoomed out, and a pixel grid when zoomed in
- Import JPEG, PNG, HEIC, TIFF, SVG (drawn into pixels) and camera RAW (with a develop step first), and open layered Photoshop PSD and PSB files (see below)
- Large documents: the memory budget scales with your Mac, and a Photoshop file too big to open has its layers cropped to the canvas instead
- Export PNG, and JPEG with a live preview (⇧⌥⌘S); Copy Merged
- Keep working while a project saves
- Photoshop-style keyboard shortcuts throughout, remappable in Edit > Keyboard Shortcuts
- Drag a number's label to scrub its value, as in Photoshop
- Automatic updates, signed and notarized

### Works with AI agents
- AI agents and scripts can build and edit projects directly: a `.comp` is a folder of PNG layers and a manifest, and an open project updates live as it's written. See [Writing Compositor projects](docs/writing-comp-files.md)
### Photoshop files

Compositor opens a layered Photoshop file, lets you edit it, and saves it back as a PSD.
Layers and data you don't change are written back as Photoshop stored them. Compositor saves
letters recolored or assigned another font as Photoshop style runs; other imported style
differences are flattened when that text is edited (see
[`docs/psd-export.md`](docs/psd-export.md)). It reads PSD and Large Document (PSB) files in
8-bit RGB (not CMYK, or 16- and 32-bit files), and writes PSD: a document opened from a PSB
is saved as a `.psd`. A file with only a background opens from its merged image.

- Folders, layer masks, clipping masks, opacity and fill opacity, and every blend mode except Dissolve, Darker Color and Lighter Color
- Type layers open as editable text, showing Photoshop's own rendering until you change them. A missing font is replaced by an installed member of its family with the closest weight and slant, or, when none of its family is installed, by Helvetica Neue (Times New Roman for serif fonts). Vertical, warped, rotated and skewed type keeps Photoshop's pixels
- Layer effects: Stroke, Drop Shadow, Inner Shadow, Outer Glow, Inner Glow and Color Overlay stay live
- Embedded smart objects keep their contents, placement and settings, and an agent can replace their contents or place new ones
- Shape layers with a solid fill (rectangles, rounded rectangles, ellipses and lines, with their strokes) stay editable; other shapes keep Photoshop's pixels
- Levels, Curves, Hue/Saturation, Exposure, Color Balance, Black & White, Invert and Gradient Map adjustment layers stay editable (Compositor edits a Gradient Map's first and last colors and keeps any between them for Photoshop)
- Guides, resolution, and layer locks, which Compositor honors (a locked folder locks everything inside it)
- Whatever Compositor can't show — another adjustment or fill layer, another effect, a shape's vector data — is kept with the layer, hidden where it has to be, and written back to Photoshop. A conversion report lists each change before the file opens

**Save As…** can write a Photoshop file instead of a Compositor project. A PSD is then the
document's working format, as in Photoshop: ⌘S keeps saving to it and the document counts as
saved. Layers you haven't changed go back as Photoshop stored them, and text, smart objects,
shapes, effects and adjustment layers are written as their Photoshop equivalents. Layers
Photoshop has no equivalent for, such as Grain, Gaussian Blur, Motion Blur, Add Noise and
Profile adjustment layers, are only rasterized after you agree to it. A `.comp` project
remains the format that keeps everything Compositor can edit.
[`docs/psd-export.md`](docs/psd-export.md) describes the file Compositor writes and how it's
checked with psd-tools and Photoshop, and [`docs/project-format.md`](docs/project-format.md)
the `.comp` format.

## MCP server

Compositor can run a local [MCP](https://modelcontextprotocol.io) server so an AI
agent — Claude Code, Codex, Claude Desktop, or anything else that speaks MCP — can
work in it the way you do: open and create documents, including Photoshop files; edit
layers, masks, selections, text, shapes, smart objects, effects and adjustment layers
(Lightroom profiles included); paint, filter, transform and resize; render previews to
check its work; and save or export. Its edits go through the same document model and undo
stack as yours, and a batch of calls can be one undo step.

The server is off by default, binds `127.0.0.1` only, and requires an access token that only
your account can read. Turn it on with **Allow AI agents to control this document** in
Compositor › Settings…, or launch with `--mcp` for one session. Settings also has
ready-to-copy setup for each client. Claude Code, Codex, Claude Desktop and other clients
run `compositor-mcp`, a small bridge inside the app bundle that finds the server and sends the
token for them; Claude Code and Codex can also connect over HTTP with the token.
See [`docs/mcp.md`](docs/mcp.md) for the full setup, security posture and tool reference.

**Folder access.** Compositor doesn't use the App Sandbox, so it and the agents driving it
can open and save files wherever you can. macOS still asks before any app reads Documents,
Desktop, Downloads, iCloud Drive, cloud storage or external volumes, and an agent working
while you're away can't answer that prompt. Settings › Folder access shows each of these
locations and can ask for access while you're at the Mac. A call that would wait on a
prompt fails within two seconds, with an error saying what to grant, instead of waiting.
See [Granting folder access](docs/mcp.md#granting-folder-access).

**Diagnostic logs.** Compositor, its MCP server and the `compositor-mcp` bridge log what they do (launches, agents'
calls and how they ended, opens, saves and exports, errors) to `~/Library/Logs/Compositor`, never the access token
or image data, and keep 14 days. Settings › Diagnostic logs turns them off or verbose and shows the folder;
`scripts/collect-logs.sh` gathers them, from this Mac or another over SSH. See [`docs/logging.md`](docs/logging.md).

## Agent skills

`skills/` holds agent skills (a `SKILL.md` with references, scripts and evals per folder)
that teach an agent to use Compositor well, not just call its tools:

| Skill | For |
| --- | --- |
| `compositor` | The entry point: what every call depends on (selectors, pixel coordinates, colors, undo and `run_batch`, the overwrite and discard flags), the render-and-verify loop, every error code and limit, and a tool atlas generated from `tools/list` |
| `compositor-setup` | Turning the server on, connecting Claude Code, Codex and Claude Desktop, folder access, and fixing a connection |
| `compositor-psd-templates` | Filling Photoshop templates: photos into smart objects, text that fits, locks kept, a new PSD saved beside the source and verified |
| `compositor-layout-and-type` | Designing from scratch: canvas sizes, margins and grids, type, shapes, framing images, alignment, contrast |
| `compositor-image-editing` | Photo work: selections, masks and cutouts, adjustment layers and Lightroom profiles, retouching, filters, crop and resize |
| `compositor-variants-and-delivery` | Sets of outputs: sizes and versions from a master, export settings, naming, PSD delivery, verification, contact sheets |
| `compositor-development` | Changing Compositor itself: architecture, build and test commands, adding MCP tools and PSD features |

Install them for Claude Code and Codex by linking (nothing is copied, so they stay in step
with the checkout):

```sh
scripts/install-skills.sh --dry-run   # show what it would link
scripts/install-skills.sh             # link ~/.agents/skills/<name>, ~/.claude/skills/<name>, ~/.codex/skills/<name>
scripts/install-skills.sh --uninstall # remove only this checkout's links
```

Run it from the main checkout, the one you keep: the links point into whichever checkout
runs it, so an install from a temporary worktree breaks when that worktree is removed.

For Claude Desktop, which imports skills as files rather than links, package them:

```sh
scripts/package-skills.sh                   # every skill as dist/skills/<name>.skill
scripts/package-skills.sh compositor        # just the named ones
```

It uses skill-creator's `package_skill.py` (set `SKILL_CREATOR` to its folder if it isn't
under `~/.claude/skills`) and `uv` for PyYAML. Each `.skill` leaves out the skill's
`evals/`; `compositor-psd-templates` and `compositor-variants-and-delivery` also carry
copies of `scripts/psd-verify.py`, `psd-diff.py` and `photoshop-verify.sh` (with its
`.jsx`), made when packaging so `scripts/` stays the one source. Upload each file in Claude
Desktop's skill settings (Settings › Capabilities › Skills at the time of writing), and
connect Compositor itself as described under MCP server: the skills teach, the MCP server
does the work. Claude Desktop runs a skill's scripts in its own sandbox, away from the
Mac's files, so there the skills fall back to reopening saved PSDs in Compositor to check
them. Package again after changing a skill.

When MCP tools change, regenerate the atlas with
`python3 skills/compositor/scripts/tool-atlas.py` (Compositor's server running); `--check`
reports drift. `scripts/tests/test_skills.py`, `test_tool_atlas.py` and
`test_skills_package.py` check the skills' structure, tool names, arguments and scripts;
`scripts/skills-eval/` runs their evals against a dedicated Compositor (see its README).

## Requirements

- macOS 26.0 or later on a Mac with Apple silicon
- Xcode 26 or later (to build from source)

## Building

Open `Compositor.xcodeproj` and run the **Compositor** scheme.

## Releasing

`scripts/release.sh` builds a Release version, signs it with Developer ID, notarizes and staples it, and packages it into `dist/Compositor-<version>.dmg`.

It needs, all kept outside this repository:

- a **Developer ID Application** certificate in the login keychain
- notarization credentials saved with `xcrun notarytool store-credentials "compositor-notary" …`
- [`create-dmg`](https://github.com/create-dmg/create-dmg) (`brew install create-dmg`)

Set the new `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in every target first.
`python3 -m unittest discover -s scripts/tests -p test_release.py` checks that the targets
agree and that Sparkle can offer the version: neither number is behind what `appcast.xml`
publishes, and a new `MARKETING_VERSION` comes with a higher build number.

## License

MIT — see [LICENSE](LICENSE).
