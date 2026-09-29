import AppKit
import Foundation
import MCP

// MARK: - View, tools and palette

extension MCPToolRegistry {
    /// Brings Compositor to the front; tests replace it so they never take focus from the user's app.
    static var activateApp: @MainActor () -> Void = {
        NSApp.unhide(nil)
        // The frontmost editor window, or a minimized one when none is on screen.
        let window = NSApp.orderedWindows.first(where: \.canBecomeMain)
            ?? NSApp.windows.first { $0.canBecomeMain && $0.isMiniaturized }
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }

    static let viewTools: [MCPToolEntry] = [
        tool("zoom_to_fit", title: "Zoom to fit",
             description: "Zooms and centers the canvas to fit the window, as ⌘0 does, and returns the zoom (1 is 100%). Only the view changes.",
             effect: .additive(idempotent: true), handler: zoomToFit),
        tool("set_zoom", title: "Set zoom",
             description: "Sets the canvas zoom (1 is 100%, 2 is 200%), clamped to 0.001–32 (clamped says so), keeping 'anchor', a document pixel, where it is on screen. Only the view changes.",
             properties: [
                 "zoom": MCPSchema.num("Zoom factor; 1 is 100%.", exclusiveMin: 0),
                 "anchor": MCPSchema.point("Document pixel kept in place (default the view's middle)."),
             ],
             required: ["zoom"], effect: .additive(idempotent: true), handler: setZoom),
        tool("select_tool", title: "Select tool",
             description: "Selects a tool in the tool rail, ready for the user's clicks; crop starts a whole-canvas crop that holds other edits. Refused while an edit that switching would commit or cancel is open.",
             properties: ["tool": MCPSchema.enumString("The tool (the app's own spellings, such as \"spotHealing\", work too).",
                                                       navigationToolNames)],
             required: ["tool"], effect: .additive(idempotent: true), handler: selectTool),
        tool("bring_app_to_front", title: "Bring Compositor to front",
             description: "Brings Compositor's window to the front so the user sees your work; macOS may keep an app the user is typing in in front.",
             targetsDocument: false, effect: .additive(idempotent: true), handler: bringAppToFront),
        tool("set_palette_colors", title: "Set palette colors",
             description: "Sets the foreground and/or background color, the app's swatches that brushes, type, shapes and fills use. They belong to the app, not the document, so no undo step; mask painting keeps its own black and white.",
             properties: [
                 "foreground": MCPSchema.color("Foreground color."),
                 "background": MCPSchema.color("Background color."),
             ],
             effect: .additive(idempotent: true), handler: setPaletteColors),
    ]

    // MARK: Zoom

    static func zoomToFit(_ ctx: MCPCallContext) throws -> CallTool.Result {
        _ = try ctx.document()
        ctx.session.fit()
        return ok(["zoom": .double(Double(ctx.session.viewport.zoom))])
    }

    static func setZoom(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let requested = try ctx.args.double("zoom")
        guard requested > 0 else { throw MCPToolError.invalidArgument("zoom must be above 0; 1 is 100%.") }
        let anchor = try ctx.args["anchor"].map { value in
            guard let point = MCPValues.point(from: value) else {
                throw MCPToolError.invalidArgument("anchor must be a point {x, y} in document pixels.")
            }
            return point
        }
        let document = try ctx.document()
        let session = ctx.session
        let range = CanvasViewport.zoomRange
        let zoom = min(range.upperBound, max(range.lowerBound, CGFloat(requested)))
        session.zoom(to: zoom, anchor: anchor.map { session.viewport.viewPoint(from: $0, documentSize: document.size) })
        return ok(["zoom": .double(Double(session.viewport.zoom)), "clamped": .bool(Double(zoom) != requested)])
    }

    // MARK: Tools

    /// A tool's name as tools take it: its raw value in snake_case ("spotHealing" is "spot_healing").
    static func navigationToolName(_ tool: NavigationTool) -> String {
        tool.rawValue.reduce(into: "") { name, character in
            if character.isUppercase { name += "_" + character.lowercased() } else { name.append(character) }
        }
    }

    static var navigationToolNames: [String] { NavigationTool.allCases.map(navigationToolName) }

    static func selectTool(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let session = ctx.session
        let name = try ctx.args.string("tool")
        guard let tool = NavigationTool.allCases.first(where: { normalized($0.rawValue) == normalized(name) }) else {
            throw MCPToolError.invalidArgument("Unknown tool '\(name)'. Tools: \(navigationToolNames.joined(separator: ", ")).")
        }
        let previous = session.tool
        if tool != previous {
            if let document = session.document {
                // Selecting Crop starts a crop of the whole canvas; leaving it untouched loses nothing, so it doesn't
                // hold the switch the way a crop the user changed does.
                let crop = session.cropRect
                if crop == CGRect(origin: .zero, size: document.size) { session.cancelCrop() }
                do { try MCPGuards.requireEditable(session) } catch { session.cropRect = crop; throw error }
            }
            session.selectTool(tool)
            guard session.tool == tool else {
                let transient = session.isProjectBusy || session.isImporting
                throw MCPToolError(transient ? .busy : .preconditionFailed,
                                   MCPGuards.blockingReason(session) ?? "Compositor can't switch tools right now.",
                                   hint: transient ? "Wait for it to finish, then retry." : "Finish or cancel it in Compositor, then retry.",
                                   guard: "can_select_tool")
            }
        }
        return ok(["tool": .string(navigationToolName(tool)), "previous": .string(navigationToolName(previous))])
    }

    // MARK: App

    static func bringAppToFront(_ ctx: MCPCallContext) throws -> CallTool.Result {
        activateApp()
        return ok()
    }

    // MARK: Palette

    static func setPaletteColors(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let session = ctx.session
        let foreground = try ctx.args.color("foreground").map { PaletteColor(red: $0.red, green: $0.green, blue: $0.blue) }
        let background = try ctx.args.color("background").map { PaletteColor(red: $0.red, green: $0.green, blue: $0.blue) }
        guard foreground != nil || background != nil else {
            throw MCPToolError.invalidArgument("Give foreground, background or both.")
        }
        guard session.canEditPalette else {
            let transient = session.isProjectBusy
            throw MCPToolError(transient ? .busy : .preconditionFailed,
                               MCPGuards.blockingReason(session) ?? "The palette can't change while a brush stroke is in progress.",
                               hint: transient ? "Wait for it to finish, then retry." : nil, guard: "can_edit_palette")
        }
        // The colors themselves, as get_document reports them; the swatches' black and white for a selected mask are
        // the app's own and stay as they are.
        if let foreground, foreground != session.foregroundColor { session.foregroundColor = foreground }
        if let background, background != session.backgroundColor { session.backgroundColor = background }
        return ok([
            "foreground": MCPValues.paletteColor(session.foregroundColor),
            "background": MCPValues.paletteColor(session.backgroundColor),
        ])
    }
}
