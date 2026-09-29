import SwiftUI
import UniformTypeIdentifiers

struct ImageLayer: Identifiable, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.isVisible == rhs.isVisible && lhs.transform == rhs.transform
            && lhs.asset?.image === rhs.asset?.image && lhs.parentID == rhs.parentID && lhs.isGroup == rhs.isGroup && lhs.opacity == rhs.opacity && lhs.blendMode == rhs.blendMode && lhs.mask == rhs.mask && lhs.maskSourceID == rhs.maskSourceID && lhs.adjustment == rhs.adjustment && lhs.shape == rhs.shape && lhs.text == rhs.text && lhs.effects == rhs.effects
            && lhs.locks == rhs.locks && lhs.fillOpacity == rhs.fillOpacity && lhs.psdExtras == rhs.psdExtras
            && lhs.smartObject == rhs.smartObject
    }
    let id: UUID
    var asset: ImportedImage?
    var transform: LayerTransform
    var origin: CGPoint { transform.origin }
    var name: String
    var isVisible = true
    var parentID: UUID?
    var isGroup = false
    var opacity: Double = 1
    var blendMode: LayerBlendMode = .normal
    var maskSourceID: UUID?
    var mask: LayerMask?
    var adjustment: LayerAdjustment?
    /// Set on layers the Shape tool made; see `liveShape`.
    var shape: LayerShape?
    /// A stroke and drop shadow drawn around the layer, kept apart from its pixels.
    var effects: LayerEffects?
    var text: LayerText?
    /// Photoshop's layer locks, kept and written back. A position lock keeps the layer from moving; a pixel lock
    /// keeps painting, fills and filters off its pixels (see LayerLocks.swift).
    var locks: LayerLocks = []
    /// Photoshop's Fill: the opacity of the layer's own pixels, apart from `opacity`, which also covers its effects.
    var fillOpacity: Double = 1
    /// What a Photoshop file held for this layer beyond what Compositor models, kept to be written back.
    var psdExtras: PSDLayerExtras?
    /// A smart object's contents and placement. The layer shows pixels drawn from them; a destructive pixel edit
    /// leaves the pixels and drops the smart object.
    var smartObject: LayerSmartObject?
    nonisolated var size: CGSize { transform.size }
    /// A Photoshop layer Compositor can't show (an unsupported adjustment, say), kept hidden and without pixels
    /// only so it can be written back. It can't be painted on.
    var isPhotoshopPlaceholder: Bool { psdExtras?.placeholder != nil }

    init(asset: ImportedImage, origin: CGPoint) {
        self.id = UUID()
        self.asset = asset
        self.transform = LayerTransform(origin: origin, size: CGSize(width: asset.image.width, height: asset.image.height))
        self.name = asset.name
    }

    init(name: String, blankSize: CGSize) {
        self.id = UUID()
        self.asset = nil // Allocate pixels when painting begins, not when adding an empty layer.
        self.transform = LayerTransform(origin: .zero, size: blankSize)
        self.name = name
    }

    init(id: UUID, asset: ImportedImage?, name: String, isVisible: Bool, transform: LayerTransform, parentID: UUID? = nil, isGroup: Bool = false, opacity: Double = 1, blendMode: LayerBlendMode = .normal, mask: LayerMask? = nil, maskSourceID: UUID? = nil, adjustment: LayerAdjustment? = nil, shape: LayerShape? = nil, effects: LayerEffects? = nil, text: LayerText? = nil, locks: LayerLocks = [], fillOpacity: Double = 1, psdExtras: PSDLayerExtras? = nil, smartObject: LayerSmartObject? = nil) {
        self.id = id
        self.asset = asset
        self.name = name
        self.isVisible = isVisible
        self.transform = transform
        self.parentID = parentID
        self.isGroup = isGroup
        self.opacity = opacity
        self.blendMode = blendMode
        self.mask = mask
        self.maskSourceID = maskSourceID
        self.adjustment = adjustment
        self.shape = shape
        self.effects = effects
        self.text = text
        self.locks = locks
        self.fillOpacity = fillOpacity
        self.psdExtras = psdExtras
        self.smartObject = smartObject
    }
}

/// The file format a document saves in.
nonisolated enum ProjectFileFormat: String, Codable, Sendable {
    case comp, psd
}

struct CanvasDocument: Equatable {
    let id: UUID
    let width: Int
    let height: Int
    var resolution: Double = 72
    var layers: [ImageLayer] = [] // Bottom to top.
    /// User-placed alignment lines. Saved with the project; undo covers them.
    var guides: [CanvasGuide] = []
    /// Part of the document so undo/redo covers selection changes. Not saved to disk.
    var selection: DocumentSelection?
    /// What the Photoshop file this document came from held beyond its layers, kept to be written back.
    var psdExtras: PSDDocumentExtras?
    var size: CGSize { CGSize(width: width, height: height) }
    init(id: UUID = UUID(), width: Int, height: Int, layers: [ImageLayer] = [], resolution: Double = 72, guides: [CanvasGuide] = []) {
        self.id = id
        self.width = width
        self.height = height
        self.layers = layers
        self.resolution = resolution
        self.guides = guides
    }

    // Geometry limit; raster memory limits will be established with image import.
    static func validDimension(_ value: String) -> Int? {
        guard let n = Int(value.trimmingCharacters(in: .whitespaces)),
              (1...DocumentLimits.maxSide).contains(n) else { return nil }
        return n
    }
}

enum NavigationTool: String, CaseIterable {
    case move, marquee, lasso, wand, crop, brush, spotHealing, cloneStamp, blur, gradient, shape, type, eyedropper, hand, zoom
    /// No tool (A): nothing in the tool rail is selected and canvas clicks do nothing.
    case idle
    /// Tools that paint with the brush tip, sharing its size, hardness, opacity, and keys.
    var isBrushTool: Bool { self == .brush || self == .spotHealing || self == .cloneStamp || self == .blur }
    /// Tools that draw and edit selections, sharing modifiers, moving, and nudging.
    var isSelectionTool: Bool { self == .marquee || self == .lasso || self == .wand }
    var symbol: String { self == .type ? "textformat" : self == .eyedropper ? "eyedropper" : self == .marquee ? "rectangle.dashed" : self == .lasso ? "lasso" : self == .wand ? "wand.and.stars" : self == .brush ? "paintbrush.pointed" : self == .spotHealing ? "bandage" : self == .cloneStamp ? "seal" : self == .blur ? "drop" : self == .gradient ? "square.bottomhalf.filled" : self == .shape ? "square.on.circle" : self == .crop ? "crop" : self == .move ? "arrow.up.left.and.arrow.down.right" : self == .hand ? "hand.draw" : "magnifyingglass" }
    var label: String { self == .type ? "Type (T)" : self == .eyedropper ? "Eyedropper (I)" : self == .marquee ? "Marquee (M)" : self == .lasso ? "Lasso (L)" : self == .wand ? "Magic (W) · Tab switches Wand and Object" : self == .brush ? "Brush (B) · Eraser (E)" : self == .spotHealing ? "Spot Healing Brush (J)" : self == .cloneStamp ? "Clone Stamp (S) · Option-click sets the source" : self == .blur ? "Smear (R)" : self == .gradient ? "Gradient (G)" : self == .shape ? "Shape (U) · Shift-U switches Rectangle/Ellipse" : self == .crop ? "Crop (C)" : self == .move ? "Move / Transform (V)" : self == .hand ? "Hand (H)" : "Zoom (Z)" }
}

@Observable
final class EditorSession {
    var skipsInitialClipboardCanvasSize = false
    var document: CanvasDocument?
    var canvasFocusRequest = 0
    var showsSampleRing = true
    var adjustmentOriginal: LayerAdjustment?
    var adjustmentEditingID: UUID? { didSet { resumeFileRequests() } }
    /// The open Profile browser, while a Profile layer is being edited.
    var profileEdit: ProfileEdit?
    /// The layer whose effects panel is open.
    var effectsEditing: LayerEffectSelection?
    var effectsEditingOriginal: LayerEffects?
    var effectSelection: LayerEffectSelection?
    @ObservationIgnored var effectsPreviews = EffectsPreviewCache()
    var projectURL: URL?
    /// The format a plain Save writes: `.comp` unless the document was opened from (or saved as) a Photoshop file.
    var documentFormat: ProjectFileFormat = .comp
    /// The file a Photoshop or image document was opened from. `projectURL` stays nil until the first save, so ⌘S
    /// never silently overwrites a client's template.
    var sourceURL: URL?
    /// Blocks overlapping edits immediately. Not observed by the UI: controls only dim via
    /// `showsBusy`, after an operation has run long enough to be worth showing, so quick
    /// edits (invert, fills, stroke commits) never flash the interface.
    @ObservationIgnored var isProjectBusy = false {
        didSet {
            if !isProjectBusy { resumeProjectWaiters() }
            resumeFileRequests()
            updateBusyIndicator()
        }
    }
    /// True once `isProjectBusy` has lasted longer than `busyIndicatorDelay`.
    private(set) var showsBusy = false
    static let busyIndicatorDelay: Duration = .milliseconds(250)
    @ObservationIgnored private var busyIndicatorTask: Task<Void, Never>?
    private func updateBusyIndicator() {
        if isProjectBusy {
            guard busyIndicatorTask == nil, !showsBusy else { return }
            busyIndicatorTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.busyIndicatorDelay)
                guard let self, !Task.isCancelled, self.isProjectBusy else { return }
                self.showsBusy = true
                self.busyIndicatorTask = nil
            }
        } else {
            busyIndicatorTask?.cancel()
            busyIndicatorTask = nil
            if showsBusy { showsBusy = false }
        }
    }
    private var projectWaiters: [CheckedContinuation<Void, Never>] = []
    private var fileRequestWaiters: [CheckedContinuation<Void, Never>] = []
    var canStartProjectOperation: Bool {
        _ = showsBusy // Re-evaluate in the UI when a long operation starts or ends.
        return selectionAmountOperation == nil && colorRange == nil && textDraft == nil && !isProjectBusy && !isImporting && brushStroke == nil && warpStroke == nil && levels == nil && !showsNewDocument && !showsImporter && renamingLayerID == nil && importError == nil && adjustmentEditingID == nil && !showsConversionSheet && !isHeldByAgentBatch
    }
    /// An agent's run_batch holds this document's undo history: its steps nest in one open edit, and a failure may
    /// roll the document back to where it began. The app's own edits, undo and project operations wait until it
    /// ends (`isHeldByAgentBatch` turns their gates off), so none is folded into the batch's step or lost to its
    /// rollback. Set by `beginAgentBatch` and `endAgentBatch`.
    private(set) var agentBatchHoldsHistory = false {
        didSet {
            if !agentBatchHoldsHistory { resumeProjectWaiters() }
            resumeFileRequests()
        }
    }
    /// Edits begun outside the batch's steps while it held the history: commands whose own guards let them through.
    /// The batch stops when this moves, and never rolls back over them.
    @ObservationIgnored private(set) var appEditsDuringAgentBatch = 0
    func waitForFileRequest() async {
        while !canStartProjectOperation {
            await withCheckedContinuation { fileRequestWaiters.append($0) }
        }
    }
    private func resumeFileRequests() {
        guard canStartProjectOperation else { return }
        let waiters = fileRequestWaiters
        fileRequestWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    /// Waits until no long operation runs (`isProjectBusy`) and no agent's batch holds the history
    /// (`isHeldByAgentBatch`), so an import the app starts, such as an image dropped on a tab that isn't showing, never
    /// opens its edit inside a batch's step.
    func waitForProjectAccess() async {
        while isProjectBusy || isHeldByAgentBatch {
            await withCheckedContinuation { projectWaiters.append($0) }
        }
    }
    private func resumeProjectWaiters() {
        let waiters = projectWaiters
        projectWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    var viewport = CanvasViewport()
    var tool: NavigationTool = .move
    var collapsedGroupIDs: Set<UUID> = []
    var cropRect: CGRect?
    var cropRatioChoice = "Free"
    var cropError: String? { didSet { AppLog.userError("crop", cropError) } }
    var transformEdit: TransformEdit?
    @ObservationIgnored var distortPreviewCache: [UUID: DistortPreviewCache] = [:]
    @ObservationIgnored var distortEffectsCache: [UUID: DistortEffectsCache] = [:]
    /// Document positions a move has just snapped to, drawn as guides while it lasts.
    @ObservationIgnored var snapGuides: (xs: [CGFloat], ys: [CGFloat]) = ([], [])
    var snappingEnabled = true {
        didSet {
            if !snappingEnabled { snapGuides = ([], []) }
            refreshCanvasPreview?()
        }
    }
    /// Where the last brush stroke ended, so a Shift-click paints a straight line on from it.
    @ObservationIgnored var lastBrushPoint: (point: CGPoint, layerID: UUID, mask: Bool)?
    /// Where the brush is while Smoothing trails it behind the pointer (see `smoothed`).
    @ObservationIgnored var brushAnchor: CGPoint?
    /// The pointer itself, so a smoothed stroke can catch up to it when the button is released.
    @ObservationIgnored var brushPointer: CGPoint?
    @ObservationIgnored var maskDistortPreviewCache: MaskDistortPreviewCache?
    /// The last rounded rectangle drawn for a transform in progress, by layer, with the size it was drawn at.
    @ObservationIgnored var shapeTransformPreviewCache: [UUID: (size: CGSize, image: CGImage)] = [:]
    var locksTransformRatio = true
    /// Off by default: a Move-tool press drags the active layer; hold Cmd (or turn this on) to pick the layer under the pointer.
    var transformAutoSelect = ToolDefaults.bool("autoSelect", false) { didSet { ToolDefaults.set(transformAutoSelect, "autoSelect") } }
    /// The Move tool's transform box and handles (⌘H). Hidden, a drag anywhere just moves the layer;
    /// a pending ⌘T transform still shows its box.
    var showsTransformControls = ToolDefaults.bool("transformControls", true) { didSet { ToolDefaults.set(showsTransformControls, "transformControls") } }
    /// The copies an Option-drag made, and what was selected before it, so Escape can take them away again.
    @ObservationIgnored var transformDuplicate: (copies: [UUID], source: Set<UUID>, primary: UUID?)?
    var brushSettings = BrushSettings() { didSet { refreshGradient() } }
    var spotHealingMode: SpotHealingMode = .contentAware
    var blurMode: BlurToolMode = .liquify
    /// The Brush's two modes: Paint lays down the foreground color, Erase clears pixels away (B and E).
    var brushMode: BrushToolMode = .paint
    /// The tool rail's icon, which follows the mode a tool is in.
    func symbol(for tool: NavigationTool) -> String {
        tool == .brush && brushMode == .erase ? "eraser" : tool.symbol
    }
    /// The Magic tool's two modes: Wand selects by color, Object traces the object under the pointer (Tab).
    var wandMode: WandMode = .wand
    /// Clone Stamp: the source Option-click set (document pixels), its options, and — once a
    /// stroke has started — the offset from brush to source that aligned strokes keep.
    var cloneSource: CGPoint?
    var cloneSettings = CloneSettings()
    /// The brush tip (size, hardness, opacity) of the side not in use: Clone Stamp keeps its own,
    /// soft by default, while Brush and Spot Healing share theirs.
    /// The tips of the brush families not in use: Clone Stamp and Smear each keep their own size, hardness and
    /// opacity (both starting soft); the other brushes share one.
    @ObservationIgnored var parkedBrushTips: [Int: (diameter: CGFloat, hardness: CGFloat, opacity: CGFloat)] = [1: (40, 0, 1), 2: (40, 0, 1)]
    private static func tipFamily(_ tool: NavigationTool) -> Int { tool == .cloneStamp ? 1 : tool == .blur ? 2 : 0 }
    @ObservationIgnored var cloneOffset: CGSize?
    var maskPaintWhite = false { didSet { refreshGradient() } }
    var backgroundColor = PaletteColor.white { didSet { refreshGradient() } }
    var gradientSettings = GradientSettings() { didSet { refreshGradient() } }
    var gradientEdit: GradientEdit?
    var lassoDraft: LassoDraft?
    var lassoKind = LassoKind.freehand
    var marqueeKind = LassoKind.rectangle
    var textDraft: TextDraft? { didSet { if oldValue != nil && textDraft == nil { resumeFileRequests() } } }
    var textDefaults = LayerTextStyle()
    var shapeKind = ShapeKind.rectangle
    /// Corner radius in pixels for rectangles the Shape tool draws; 0 keeps the corners square.
    var shapeCornerRadius: Double = 0
    /// A Line shape's thickness in document pixels.
    var shapeLineWidth: Double = 4
    /// The shape being dragged out with the Shape tool, before it becomes a layer.
    var shapeDraft: ShapeDraft?
    var selectionModeChoice = SelectionMode.replace
    /// Mode implied by the Shift/Option keys currently held, nil when neither is.
    var heldSelectionMode: SelectionMode?
    /// The selection as it was when a drag-move began; the drag is one undo step.
    @ObservationIgnored var selectionMoveOrigin: DocumentSelection?
    var pixelMove: PixelMove?
    @ObservationIgnored var pixelClipboard: PixelClipboard?
    /// The pasteboard Copy writes and Paste reads (`SelectionClipboard`): the system's, except in a test host (see
    /// `defaultPasteboard`). A test can give a session one of its own.
    @ObservationIgnored var pasteboard: NSPasteboard = EditorSession.defaultPasteboard
    @ObservationIgnored var copiedLayer: CopiedLayer?
    var levels: LevelsEdit? { didSet { resumeFileRequests() } }
    var hueSaturation: HueSaturationEdit?
    /// The open filter (Filter menu), and the settings the next one starts from.
    var filterEdit: FilterEdit?
    var filterSettings = FilterSettings()
    @ObservationIgnored var hueSaturationTask: Task<Void, Never>?
    /// The newest preview request while one is already rendering.
    @ObservationIgnored var hueSaturationPending: HueSaturationJob?
    /// The armed eyedropper and the targeted-adjustment tool, while the panel is open.
    var hueSampleMode: HueSampleMode?
    var hueTargeting = false
    @ObservationIgnored var hueTargetDrag: HueTargetDrag?
    var selectionAntialiased = true
    /// How far Feather softens the selection's edge each time it is applied, in document pixels.
    var selectionAmountOperation: SelectionAmountOperation? { didSet { resumeFileRequests() } }
    /// Select > Color Range's panel is open; the selection shown is its preview until OK.
    var colorRange: ColorRangeEdit? { didSet { resumeFileRequests() } }
    /// The dialog whose color the picker is open on (`ColorPickerTarget.dialog`).
    @ObservationIgnored var dialogColorChange: ((PaletteColor) -> Void)?
    /// A dialog with its own zoomable preview (Export JPEG) is open: the View menu's zoom commands zoom that instead.
    @ObservationIgnored var previewZoom: ((PreviewZoomCommand) -> Void)?
    /// The text's style before the font menu started previewing faces on it (see `previewFont`).
    @ObservationIgnored var fontPreviewOriginal: LayerTextStyle?
    var selectionFeatherAmount = 2
    var wandSettings = WandSettings()
    var objectSelectionSettings = ObjectSelectionSettings()
    var showsPixelGrid = ToolDefaults.bool("pixelGrid", true) { didSet { ToolDefaults.set(showsPixelGrid, "pixelGrid") } }
    /// Layout grid (View > Show > Grid). Off until turned on; independent of the 800% pixel grid.
    var showsGrid = ToolDefaults.bool("grid", false) { didSet { ToolDefaults.set(showsGrid, "grid") } }
    /// The layout grid's spacing and subdivisions (View > Grid Settings…). The person's, not the project's.
    var layoutGrid = LayoutGrid(spacing: ToolDefaults.int("gridSpacing", 64), subdivisions: ToolDefaults.int("gridSubdivisions", 8)) {
        didSet {
            ToolDefaults.set(layoutGrid.spacing, "gridSpacing")
            ToolDefaults.set(layoutGrid.subdivisions, "gridSubdivisions")
        }
    }
    /// The layout grid's color, line style and opacity (View > Grid Settings…), also the person's.
    var gridAppearance = GridAppearance(
        preset: GridAppearance.Preset(rawValue: ToolDefaults.string("gridColor", "")) ?? .lightGray,
        customColor: PaletteColor(hex: ToolDefaults.string("gridCustomColor", "")) ?? GridAppearance().customColor,
        style: GridAppearance.Style(rawValue: ToolDefaults.string("gridStyle", "")) ?? .lines,
        opacity: ToolDefaults.int("gridOpacity", GridAppearance().opacity)) {
        didSet {
            ToolDefaults.set(gridAppearance.preset.rawValue, "gridColor")
            ToolDefaults.set(gridAppearance.customColor.hex, "gridCustomColor")
            ToolDefaults.set(gridAppearance.style.rawValue, "gridStyle")
            ToolDefaults.set(gridAppearance.opacity, "gridOpacity")
        }
    }
    /// User guides. Hidden extras do not snap.
    var showsGuides = ToolDefaults.bool("guides", true) { didSet { ToolDefaults.set(showsGuides, "guides") } }
    var showsRulers = ToolDefaults.bool("rulers", false) { didSet { ToolDefaults.set(showsRulers, "rulers") } }
    /// Master snap switch (View > Snap). On so today's layer/canvas snap keeps working.
    var snapEnabled = ToolDefaults.bool("snap", true) { didSet { ToolDefaults.set(snapEnabled, "snap") } }
    var snapToGuides = ToolDefaults.bool("snapGuides", true) { didSet { ToolDefaults.set(snapToGuides, "snapGuides") } }
    var snapToGrid = ToolDefaults.bool("snapGrid", false) { didSet { ToolDefaults.set(snapToGrid, "snapGrid") } }
    var snapToLayers = ToolDefaults.bool("snapLayers", true) { didSet { ToolDefaults.set(snapToLayers, "snapLayers") } }
    var snapToDocumentBounds = ToolDefaults.bool("snapBounds", true) { didSet { ToolDefaults.set(snapToDocumentBounds, "snapBounds") } }
    var locksGuides = ToolDefaults.bool("lockGuides", false) { didSet { ToolDefaults.set(locksGuides, "lockGuides") } }
    var guideDrag: GuideDrag?
    /// Pixels the Expand / Contract buttons grow or shrink the selection by.
    var selectionExpandAmount = 1
    var selectionContractAmount = 1
    @ObservationIgnored var pendingOpacityDigit: (digit: Int, time: TimeInterval)?
    var colorPicker: ColorPickerState?
    var brushError: String? { didSet { AppLog.userError("paint", brushError) } }
    var brushRevision = 0
    /// Not observed by the UI, so controls don't dim for the length of every stroke;
    /// a stroke keeps the settings it started with, so edits made mid-stroke are harmless.
    @ObservationIgnored var brushStroke: BrushStroke? { didSet { resumeFileRequests() } }
    /// A Smudge or Liquify stroke in progress.
    @ObservationIgnored var warpStroke: WarpStroke? { didSet { resumeFileRequests() } }

    var canTransform: Bool {
        guard let targets = transformTargets else { return false }
        // Several selected layers, or a folder's contents, transform together — none of them if one is locked in
        // place, as Photoshop refuses the move.
        return !isPositionLocked(targets)
    }
    /// Whether a position lock (a layer's own or a folder's around it) is what keeps the active layer, or the layers
    /// moving with it, from being moved or transformed. The app beeps when one refuses a move.
    var isTransformPositionLocked: Bool { transformTargets.map(isPositionLocked) ?? false }
    /// What a transform would move if no lock held it: the group's members, or the active layer. Nil when there is
    /// nothing to transform.
    private var transformTargets: [UUID]? {
        guard canEditLayers else { return nil }
        if transformsAsGroup {
            let members = groupTransformMembers
            return members.isEmpty ? nil : members.map(\.id)
        }
        guard let layer = activeLayer, layer.asset != nil, !layer.isGroup, document?.effectiveVisibleIDs.contains(layer.id) == true else {
            return nil
        }
        return [layer.id]
    }
    /// Several layers selected, or a folder: the transform moves them (a folder, everything in it) together in one box.
    var transformsAsGroup: Bool { selectedLayerIDs.count > 1 || (selectedLayerIDs.count == 1 && activeLayer?.isGroup == true) }
    /// What a group transform moves: the visible pixel layers selected and inside selected folders.
    var groupTransformMembers: [ImageLayer] {
        guard transformsAsGroup, let document else { return [] }
        let parents = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.id, $0.parentID) })
        let visible = document.effectiveVisibleIDs
        return document.layers.filter { layer in
            guard layer.asset != nil, !layer.isGroup, visible.contains(layer.id) else { return false }
            var current: UUID? = layer.id
            for _ in 0..<64 {
                guard let id = current else { return false }
                if selectedLayerIDs.contains(id) { return true }
                current = parents[id] ?? nil
            }
            return false
        }
    }
    /// The upright box around `groupTransformMembers`.
    var groupTransformBox: LayerTransform? {
        let points = groupTransformMembers.flatMap { DistortWarp.corners(of: $0.transform) }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        return LayerTransform(origin: CGPoint(x: minX, y: minY), size: CGSize(width: max(1, maxX - minX), height: max(1, maxY - minY)))
    }
    func selectLayer(_ id: UUID?) {
        effectSelection = nil
        if id != activeLayerID, !finishText() { return }
        guard brushStroke == nil, warpStroke == nil, levels == nil else { return }
        if id != activeLayerID { commitTransform(); resolveGradient() }
        activeLayerID = id
    }
    func selectTool(_ value: NavigationTool) {
        if tool != value, !finishText() { return }
        guard !isProjectBusy, brushStroke == nil, warpStroke == nil, levels == nil else { return }
        if tool != value { commitTransform(); cancelCrop(); resolveGradient(); cancelLasso(); cancelShape() }
        let from = Self.tipFamily(tool), to = Self.tipFamily(value)
        if from != to, let parked = parkedBrushTips[to] {
            parkedBrushTips[from] = (brushSettings.diameter, brushSettings.hardness, brushSettings.opacity)
            var settings = brushSettings
            settings.diameter = parked.diameter
            settings.hardness = parked.hardness
            settings.opacity = parked.opacity
            brushSettings = settings
        }
        tool = value
        if value.isBrushTool { _ = MetalBrushCoverage.shared }
        if value == .crop, cropRect == nil, let document {
            cropRatioChoice = "Free"
            let canvas = CGRect(origin: .zero, size: document.size)
            // With a selection, the crop starts at its bounds, as Photoshop's does: C, then Return, crops to it.
            if let selection, !selection.isEmpty {
                let bounds = selection.path.boundingBoxOfPath.integral.intersection(canvas)
                cropRect = CropGeometry.valid(bounds) ? bounds : canvas
            } else {
                cropRect = canvas
            }
        }
    }
    /// Tab steps the current tool through its own modes — the setting sitting at the left of its tool bar. Tools
    /// without modes (Move, Crop, Type, Eyedropper, Hand, Zoom) ignore it.
    func cycleToolMode() {
        guard !isProjectBusy, brushStroke == nil, warpStroke == nil else { return }
        func next<T: CaseIterable & Equatable>(_ value: T) -> T where T.AllCases.Index == Int {
            let all = Array(T.allCases)
            let index = all.firstIndex(of: value) ?? 0
            return all[(index + 1) % all.count]
        }
        switch tool {
        case .marquee: toggleMarqueeKind()
        case .wand: wandMode = next(wandMode)
        case .lasso: toggleLassoKind()
        case .shape: toggleShapeKind()
        case .brush: brushMode = next(brushMode)
        case .blur: blurMode = next(blurMode)
        case .spotHealing: spotHealingMode = next(spotHealingMode)
        case .cloneStamp: cloneSettings.sampleAllLayers.toggle()
        case .gradient: gradientSettings.shape = next(gradientSettings.shape)
        default: break
        }
    }

    func beginTransform(persistent: Bool = true) {
        cancelCrop()
        guard transformEdit == nil, canTransform, let layer = activeLayer else { return }
        tool = .move
        if transformsAsGroup {
            let members = groupTransformMembers
            guard let box = groupTransformBox else { return }
            transformEdit = TransformEdit(layerID: layer.id, draft: box, persistent: persistent,
                group: TransformGroup(box: box, originals: Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.transform) })))
            return
        }
        // An unlinked mask, when selected, transforms on its own; linked, layer and mask move together.
        let maskAlone = isMaskSelected && layer.mask?.isLinked == false
        transformEdit = TransformEdit(layerID: layer.id, draft: maskAlone ? layer.maskTransform : layer.transform,
                                      persistent: persistent, mask: maskAlone)
    }
    func previewTransform(_ value: LayerTransform) {
        guard value.isValid, transformEdit != nil else { return }
        transformEdit?.draft = value
    }
    /// Option-drag duplicates selected roots with their descendants and drags the copies.
    func beginDuplicateTransform() {
        guard transformDuplicate == nil, let primary = activeLayerID else { return }
        commitTransform()
        guard canTransform else { return }
        let selection = selectedLayerIDs
        // Bottom to top, so the copies keep the order they had.
        let carried = selection.reduce(into: Set<UUID>()) { $0.formUnion(descendantIDs(of: $1)) }
        let targets = (document?.layers ?? []).filter { selection.contains($0.id) && !carried.contains($0.id) }.map(\.id)
        guard !targets.isEmpty else { return }
        beginEdit(targets.count > 1 ? "Duplicate Layers" : "Duplicate Layer")
        // Stacked as Duplicate Layer stacks them: several together above the topmost original.
        duplicateLayers(targets)
        let copies = selectedLayerIDs.subtracting(selection)
        guard !copies.isEmpty else { endEdit(); selectLayers(selection, primary: primary); return }
        transformDuplicate = (Array(copies), selection, primary)
        selectLayers(copies, primary: activeLayerID)
        beginTransform(persistent: false)
    }
    func commitTransform() {
        snapGuides = ([], [])
        blendPreview = nil
        finishOpacityEdit()
        guard let edit = transformEdit else { return }
        defer {
            if transformDuplicate != nil { transformDuplicate = nil; endEdit() }
        }
        transformEdit = nil
        if let floating = edit.floating {
            // Unchanged: restore exactly, so soft selection edges never pick up a seam.
            if edit.draft == floating.original && edit.corners == nil { cancelFloatingTransform(floating) }
            else { mergeFloatingTransform(edit, floating) }
            return
        }
        if edit.mask { commitMaskTransform(edit); return }
        if let corners = edit.corners { commitDistort(edit, corners: corners); return }
        if let group = edit.group {
            guard edit.draft.isValid else { return }
            beginEdit("Transform Layers")
            for (id, original) in group.originals {
                guard let index = document?.layers.firstIndex(where: { $0.id == id }) else { continue }
                let moved = original.following(from: group.box, to: edit.draft)
                guard moved.isValid else { continue }
                if let mask = document?.layers[index].mask {
                    document?.layers[index].mask?.placement = mask.placement(movingLayer: original, to: moved)
                }
                document?.layers[index].transform = moved
                redrawShape(at: index)
            }
            endEdit()
            return
        }
        guard edit.draft.isValid, let index = document?.layers.firstIndex(where: { $0.id == edit.layerID }) else { return }
        beginEdit("Transform Layer")
        if let mask = document?.layers[index].mask, let old = document?.layers[index].transform {
            document?.layers[index].mask?.placement = mask.placement(movingLayer: old, to: edit.draft)
        }
        document?.layers[index].transform = edit.draft
        redrawShape(at: index)
        endEdit()
    }
    func cancelTransform() {
        snapGuides = ([], [])
        guard let edit = transformEdit else { return }
        transformEdit = nil
        if let duplicate = transformDuplicate {
            let removed = duplicate.copies.reduce(into: Set(duplicate.copies)) { $0.formUnion(descendantIDs(of: $1)) }
            document?.layers.removeAll { removed.contains($0.id) }
            collapsedGroupIDs.subtract(removed)
            selectLayers(duplicate.source, primary: duplicate.primary)
            transformDuplicate = nil
            endEdit()
        }
        if let floating = edit.floating { cancelFloatingTransform(floating) }
    }
    /// Pixels the transform places — what 100% scale draws 1:1. Nil for a layer without pixels.
    var transformPixelSize: CGSize? {
        if let group = transformEdit?.group { return group.box.size }
        if transformEdit == nil, transformsAsGroup { return groupTransformBox?.size }
        if transformTargetsMask { return nil }
        if let floating = transformEdit?.floating { return floating.pixelSize }
        guard let image = activeLayer?.asset?.image else { return nil }
        return CGSize(width: image.width, height: image.height)
    }
    func displayedTransform(for layer: ImageLayer) -> LayerTransform {
        if let pending = pendingTransform(for: layer) { return pending }
        // Content-Aware Fill past the layer's edge previews on the grown layer.
        if let edit = filterEdit, let grown = edit.preparedTransform, edit.previewImage(for: layer.id) != nil { return grown }
        return layer.transform
    }
    /// Whether transforming places only the active layer's mask (an unlinked mask selected in the Layers panel).
    var transformTargetsMask: Bool { transformEdit.map(\.mask) ?? (isMaskSelected && activeLayer?.mask?.isLinked == false) }
    /// Where `layer`'s transform handles sit: the pending edit's draft — the layer's or its mask's — else the layer.
    func editedTransform(for layer: ImageLayer) -> LayerTransform {
        if transformEdit?.layerID == layer.id { return transformEdit!.draft }
        if transformEdit == nil, layer.id == activeLayerID, transformsAsGroup, let box = groupTransformBox { return box }
        return layer.id == activeLayerID && transformTargetsMask ? layer.maskTransform : layer.transform
    }
    /// A layer's transform under the pending edit: the draft for the edited layer, carried along with the box for
    /// each layer of a group; nil when the edit doesn't move it.
    func pendingTransform(for layer: ImageLayer) -> LayerTransform? {
        guard let edit = transformEdit, !edit.mask else { return nil }
        if let group = edit.group { return group.originals[layer.id].map { $0.following(from: group.box, to: edit.draft) } }
        return edit.layerID == layer.id ? edit.draft : nil
    }
    /// Arrow keys with the Move tool: moves the active layer (or what transforms with it) by `dx`, `dy`. False when
    /// nothing could move; the app beeps then when a position lock is why (`isTransformPositionLocked`).
    @discardableResult
    func nudgeLayer(dx: CGFloat, dy: CGFloat) -> Bool {
        let alreadyEditing = transformEdit != nil
        if !alreadyEditing { beginTransform(persistent: false) }
        guard var value = transformEdit?.draft else { return false }
        value.origin.x += dx
        value.origin.y += dy
        previewTransform(value)
        if let corners = transformEdit?.corners { previewCorners(corners.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }) }
        if !alreadyEditing { commitTransform() }
        return true
    }
    /// Moves layers (folders take their descendants) by an offset; mask placements follow. One undo step.
    /// Nothing moves when the offset is zero or would take any of them past the ±1,000,000 pixel limit.
    func translateLayers(_ ids: Set<UUID>, by offset: CGPoint, name: String = "Move Layer") {
        commitTransform()
        guard canEditLayers, let document, offset != .zero, offset.x.isFinite, offset.y.isFinite else { return }
        let moved = ids.reduce(into: ids) { $0.formUnion(descendantIDs(of: $1)) }
        var changes: [(index: Int, transform: LayerTransform)] = []
        for index in document.layers.indices where moved.contains(document.layers[index].id) {
            var transform = document.layers[index].transform
            transform.origin.x += offset.x
            transform.origin.y += offset.y
            guard transform.isValid else { return }
            changes.append((index, transform))
        }
        guard !changes.isEmpty else { return }
        finishOpacityEdit()
        beginEdit(name)
        for change in changes {
            let layer = document.layers[change.index]
            if let mask = layer.mask {
                self.document?.layers[change.index].mask?.placement = mask.placement(movingLayer: layer.transform, to: change.transform)
            }
            self.document?.layers[change.index].transform = change.transform
        }
        endEdit()
    }
    var showsNewDocument = false { didSet { resumeFileRequests() } }
    var showsImporter = false { didSet { resumeFileRequests() } }
    var isImporting = false { didSet { resumeFileRequests() } }
    var importError: String? { didSet { resumeFileRequests(); AppLog.userError("import", importError) } }
    var showsConversionSheet = false { didSet { resumeFileRequests() } }
    var conversionRequest: PSDConversionRequest?
    /// Tests assign this to skip the conversion sheet.
    @ObservationIgnored var confirmConversions: (([PSDConversion]) async -> Bool)?
    /// The RAW file being developed, and the settings the sheet is editing (see RawImporter).
    var rawDevelop: (url: URL, settings: RawDevelopSettings)?
    var showsRawDevelop = false { didSet { resumeFileRequests() } }
    @ObservationIgnored private var rawContinuation: CheckedContinuation<RawDevelopSettings?, Never>?
    /// Tests assign this to develop without a sheet.
    @ObservationIgnored var confirmRawDevelop: ((URL, RawDevelopSettings) async -> RawDevelopSettings?)?

    /// Puts the develop sheet up and waits for the choice; nil means the import was cancelled.
    func developRaw(_ url: URL) async -> RawDevelopSettings? {
        let asShot = await FileProbe.rawAsShot(url) ?? RawDevelopSettings()
        if let confirmRawDevelop { return await confirmRawDevelop(url, asShot) }
        return await withCheckedContinuation { continuation in
            rawContinuation = continuation
            rawDevelop = (url, asShot)
            showsRawDevelop = true
        }
    }
    func finishRawDevelop(_ settings: RawDevelopSettings?) {
        showsRawDevelop = false
        rawDevelop = nil
        Task { await RawImporter.Queue.shared.release() }
        let continuation = rawContinuation
        rawContinuation = nil
        continuation?.resume(returning: settings)
    }
    @ObservationIgnored private var conversionContinuation: CheckedContinuation<Bool, Never>?
    /// Cancel pressed while a Photoshop file was still being read.
    @ObservationIgnored private var conversionCancelled = false
    var opacityEditLayerID: UUID?
    var blendPreview: (layerID: UUID, mode: LayerBlendMode)?
    @ObservationIgnored var refreshCanvasPreview: (() -> Void)?
    var isMaskSelected = false { didSet { if !isMaskSelected { viewsMaskAlone = false } } }
    /// Option-click on a mask thumbnail: the canvas shows the targeted mask by itself, in grayscale, so it can be
    /// painted with nothing else in the way, as in Photoshop. Targeting the layer's pixels, or another layer, ends it.
    var viewsMaskAlone = false
    /// The layer whose mask the canvas is showing by itself; nil for the ordinary composite.
    var maskAloneLayer: ImageLayer? {
        guard viewsMaskAlone, isMaskSelected, let layer = activeLayer, layer.mask != nil else { return nil }
        return layer
    }
    var selectedLayerIDs: Set<UUID> = []
    var activeLayerID: UUID? {
        didSet {
            if activeLayerID != oldValue { isMaskSelected = false }
            selectedLayerIDs = activeLayerID.map { [$0] } ?? []
        }
    }
    var renamingLayerID: UUID? { didSet { resumeFileRequests() } }
    let history = DocumentHistory()
    var isModified: Bool { history.isModified }
    /// Undo, redo and an agent's run_batch may move through or record into the history: nothing in progress would
    /// record into it when it ends. A guide drag counts: it records "New Guide" or "Move Guide" when the mouse goes up.
    var canUseHistory: Bool {
        _ = showsBusy
        return selectionAmountOperation == nil && colorRange == nil && textDraft == nil && !isProjectBusy && !isImporting && brushStroke == nil && warpStroke == nil && levels == nil && !showsNewDocument && !showsImporter && renamingLayerID == nil && importError == nil && transformEdit == nil && guideDrag == nil && !showsConversionSheet && !isHeldByAgentBatch
    }
    var canUndo: Bool { canUseHistory && (history.canUndo || gradientEdit != nil) }
    var canRedo: Bool { canUseHistory && history.canRedo }

    func undo() {
        // Like Photoshop, the first Undo discards a pending gradient.
        if gradientEdit != nil { cancelGradient(); return }
        guard canUndo, let snapshot = history.undo() else { return }
        restore(snapshot)
    }

    func redo() {
        guard canRedo, let snapshot = history.redo() else { return }
        restore(snapshot)
    }

    private func restore(_ snapshot: DocumentHistory.Snapshot) {
        cancelCrop()
        cancelGradient()
        let changedCanvas = document?.id != snapshot.document?.id
        let keepMaskTarget = isMaskSelected && activeLayerID == snapshot.activeLayerID
        document = snapshot.document
        activeLayerID = snapshot.activeLayerID
        isMaskSelected = keepMaskTarget && activeLayer?.mask != nil
        if changedCanvas, let document { viewport.fit(documentSize: document.size) }
    }

    /// Nestable transaction boundary; future tools can group a complete gesture.
    func beginEdit(_ name: String) {
        if isHeldByAgentBatch { appEditsDuringAgentBatch += 1 }
        history.begin(name, document: document, selection: activeLayerID)
    }

    /// True for code running as a step of an agent's batch (a task-local value run_batch sets around each step, so
    /// it reaches whatever the step awaits but never the app's own event handling).
    @TaskLocal static var runsAgentBatchStep = false

    /// The app must wait: an agent's batch holds the history (`agentBatchHoldsHistory`) and this isn't one of its steps.
    var isHeldByAgentBatch: Bool { agentBatchHoldsHistory && !Self.runsAgentBatchStep }

    /// Marks the history held by an agent's batch, from just after it opens its edit.
    func beginAgentBatch() {
        appEditsDuringAgentBatch = 0
        agentBatchHoldsHistory = true
    }

    func endAgentBatch() {
        agentBatchHoldsHistory = false
    }

    func endEdit() { history.end(document: document, selection: activeLayerID) }
    var activeLayer: ImageLayer? { document?.layers.first { $0.id == activeLayerID } }
    var canEditLayers: Bool {
        _ = showsBusy
        return selectionAmountOperation == nil && colorRange == nil && textDraft == nil && document != nil && brushStroke == nil && warpStroke == nil && !isProjectBusy && !isImporting && !showsNewDocument && !showsImporter && renamingLayerID == nil && transformEdit == nil && cropRect == nil && gradientEdit == nil && pixelMove == nil && hueSaturation == nil && levels == nil && filterEdit == nil && adjustmentEditingID == nil && !isHeldByAgentBatch
    }

    /// Where a new layer goes among `layers` (the document's layers, less one being moved) to sit directly above
    /// `active`, or, when `active` is a folder, at the top of it: just above its topmost contents, however deep. The
    /// top of the stack when no layer is active. The one rule New Blank Layer, Place Smart Object and the agent's
    /// add_image_layer place a new layer by.
    func insertionIndex(above active: UUID?, in layers: [ImageLayer]) -> Int {
        var insertion = layers.firstIndex { $0.id == active }.map { $0 + 1 } ?? layers.count
        if let folder = active, layers.first(where: { $0.id == folder })?.isGroup == true {
            let inside = descendantIDs(of: folder)
            if let topmost = layers.lastIndex(where: { inside.contains($0.id) }) { insertion = max(insertion, topmost + 1) }
        }
        return insertion
    }

    func addBlankLayer() {
        guard canEditLayers, let document else { return }
        let names = Set(document.layers.map(\.name))
        var number = 1
        while names.contains("Layer \(number)") { number += 1 }
        var layer = ImageLayer(name: "Layer \(number)", blankSize: document.size)
        layer.parentID = activeLayer?.isGroup == true ? activeLayerID : activeLayer?.parentID
        if let parent = layer.parentID { collapsedGroupIDs.remove(parent) }
        let insertion = insertionIndex(above: activeLayerID, in: document.layers)
        beginEdit("New Blank Layer")
        defer { endEdit() }
        self.document?.layers.insert(layer, at: insertion)
        activeLayerID = layer.id
    }

    func deleteLayer(_ id: UUID) {
        guard canEditLayers, document?.layers.contains(where: { $0.id == id }) == true, deletionUnlocked([id]) else { return }
        guard !deleteWithLiveMaskChoice(id) else { return }
        finishDeletingLayer(id, baked: [:])
    }

    func deleteActiveLayer() {
        if let activeLayerID { deleteLayer(activeLayerID) }
    }

    /// Deletes every selected layer as one undo step (a selected folder takes its contents); with one
    /// layer selected, just that one.
    func deleteSelectedLayers() {
        guard canEditLayers, let document else { return }
        // Captured first: deleting moves the active layer, which resets the selection.
        let ids = document.layers.map(\.id).filter(selectedLayerIDs.contains)
        guard ids.count > 1 else { deleteActiveLayer(); return }
        guard deletionUnlocked(ids), !deleteWithLiveMaskChoice(ids) else { return }
        finishDeletingLayers(ids, baked: [:])
    }

    func renameLayer(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isProjectBusy, !isImporting, !name.isEmpty, let index = document?.layers.firstIndex(where: { $0.id == id }) else { return }
        beginEdit("Rename Layer")
        defer { endEdit() }
        document?.layers[index].name = name
    }

    func toggleLayerVisibility(_ id: UUID) {
        guard canEditLayers, let index = document?.layers.firstIndex(where: { $0.id == id }) else { return }
        beginEdit(document?.layers[index].isVisible == true ? "Hide Layer" : "Show Layer")
        defer { endEdit() }
        document?.layers[index].isVisible.toggle()
    }

    /// Photoshop's eye swipe: pressing an eye shows or hides that layer, and dragging over other eyes gives them the
    /// same state, all as one undo step (`beginEdit` at the press, `endEdit` when the button comes up).
    func beginVisibilitySwipe(_ id: UUID) -> Bool? {
        guard canEditLayers, let layer = document?.layers.first(where: { $0.id == id }) else { return nil }
        let visible = !layer.isVisible
        beginEdit(visible ? "Show Layer" : "Hide Layer")
        setVisibilityInSwipe(id, visible: visible)
        return visible
    }
    func setVisibilityInSwipe(_ id: UUID, visible: Bool) {
        guard let index = document?.layers.firstIndex(where: { $0.id == id }),
              document?.layers[index].isVisible != visible else { return }
        document?.layers[index].isVisible = visible
    }
    func endVisibilitySwipe() { endEdit() }

    func reorderLayers(from offsets: IndexSet, to destination: Int) {
        guard canEditLayers, var layers = document?.layers.reversed().map({ $0 }),
              offsets.allSatisfy({ layers.indices.contains($0) }), (0...layers.count).contains(destination) else { return }
        // List order is top-to-bottom; the compositor stores bottom-to-top.
        layers.move(fromOffsets: offsets, toOffset: destination)
        beginEdit("Reorder Layers")
        defer { endEdit() }
        document?.layers = layers.reversed()
    }

    func canMoveActiveLayer(by offset: Int) -> Bool {
        guard canEditLayers, let activeLayer else { return false }
        let siblings = document?.layers.filter { $0.parentID == activeLayer.parentID } ?? []
        guard let index = siblings.firstIndex(where: { $0.id == activeLayer.id }) else { return false }
        return siblings.indices.contains(index + offset)
    }
    func moveActiveLayer(by offset: Int) {
        guard canMoveActiveLayer(by: offset), let activeLayer, let layers = document?.layers else { return }
        let siblings = layers.filter { $0.parentID == activeLayer.parentID }
        guard let index = siblings.firstIndex(where: { $0.id == activeLayer.id }),
              let a = layers.firstIndex(where: { $0.id == activeLayer.id }),
              let b = layers.firstIndex(where: { $0.id == siblings[index + offset].id }) else { return }
        beginEdit("Reorder Layers")
        document?.layers.swapAt(a, b)
        endEdit()
    }
    private struct ImportRequest {
        let files: [(url: URL, scoped: Bool)]
        let point: CGPoint?
        let completion: CheckedContinuation<Void, Never>
    }
    private var pendingImports: [ImportRequest] = []

    /// What an import may still add to the document (`DocumentLimits.documentPixelBudget` less its layers' pixels), and
    /// its masks (`LayerMask.maximumProjectPixels` less the masks it has), counted apart as a project counts them.
    func remainingImportPixels() -> (pixels: Int, maskPixels: Int) {
        let layers = document?.layers ?? []
        let used = layers.reduce(0) { total, layer in
            guard let image = layer.asset?.image else { return total }
            return total + image.width * image.height
        }
        let usedMasks = layers.reduce(0) { total, layer in
            guard let mask = layer.mask?.asset.image else { return total }
            return total + mask.width * mask.height
        }
        return (DocumentLimits.documentPixelBudget - used, LayerMask.maximumProjectPixels - usedMasks)
    }

    func importImages(_ urls: [URL], at point: CGPoint? = nil) async {
        guard !urls.isEmpty else { return }
        if brushStroke != nil { await finishBrush() }
        cancelCrop()
        commitTransform()
        // Hold sandbox grants while requests wait behind an in-progress decode.
        let files = urls.map { (url: $0, scoped: $0.startAccessingSecurityScopedResource()) }
        await waitForProjectAccess()
        await withCheckedContinuation { completion in
            pendingImports.append(ImportRequest(files: files, point: point, completion: completion))
            if !isImporting {
                isImporting = true
                Task { await drainImports() }
            }
        }
    }

    private func drainImports() async {
        var failures: [String] = []
        while !pendingImports.isEmpty {
          let request = pendingImports.removeFirst()
          // Each check reads the file (a cloud-only one downloads first), so none runs on the main actor.
          var psdOnly = true
          for file in request.files where !(await FileProbe.isPhotoshop(file.url)) { psdOnly = false; break }
          beginEdit(psdOnly ? "Import Photoshop File" : "Import Images")
          // No document: the first successful image determines the canvas, regardless of drop point.
          let point = document == nil ? nil : request.point
          for (url, scoped) in request.files {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard url.isFileURL else { throw ImageImportError.unsupported }
                let remaining = remainingImportPixels()
                if RawImporter.matches(url) {
                    guard let size = await FileProbe.rawPixelSize(url) else { throw ImageImportError.unreadable }
                    guard size.width <= DocumentLimits.maxSide, size.height <= DocumentLimits.maxSide,
                          size.width * size.height <= remaining.pixels else { throw ImageImportError.tooLarge }
                    guard let settings = await developRaw(url) else { continue }
                    // Seconds of work: off the main actor, or pressing Import freezes the window.
                    guard let developed = await RawImporter.Queue.shared.develop(url, settings: settings, limit: nil)
                    else { throw ImageImportError.unreadable }
                    let thumbnail = try await FileProbe.thumbnail(of: developed)
                    insert(ImportedImage(image: developed, thumbnail: thumbnail,
                                         name: url.deletingPathExtension().lastPathComponent), centeredAt: point)
                } else if ImageImporter.isSVG(url) {
                    let asset = try await ImageImporter.shared.decodeSVG(url, fitting: document?.size, remainingPixels: remaining.pixels)
                    insert(asset, centeredAt: point)
                } else if await FileProbe.isPhotoshop(url) {
                    beginPSDReading(title: "Open “\(url.lastPathComponent)”?", confirmTitle: "Import")
                    let imported: PSDImport
                    do {
                        let parsed = try await ImageImporter.shared.loadPhotoshop(
                            url, remainingPixels: remaining.pixels, remainingMaskPixels: remaining.maskPixels)
                        // Only a background: Photoshop writes no layer records, just the merged image, so that is
                        // what comes in, as one layer.
                        if parsed.layers.isEmpty {
                            endPSDReading()
                            let asset = try await ImageImporter.shared.decode(url, remainingPixels: remaining.pixels,
                                                                              flattenedPhotoshop: true)
                            insert(asset, centeredAt: point)
                            continue
                        }
                        let assets = try await ImageImporter.shared.photoshopAssets(parsed)
                        imported = try PSDDocumentBuilder.makeImport(parsed, assets: assets)
                    } catch {
                        endPSDReading()
                        throw error
                    }
                    var conversions = imported.conversions
                    if let document, let note = PSDDocumentBuilder.resolutionMismatchNote(
                        fileName: url.lastPathComponent, importedResolution: imported.resolution, existingResolution: document.resolution) {
                        conversions.append(note)
                    }
                    if !(await finishPSDReading(conversions)) { continue }
                    try insertPhotoshop(imported, named: url.deletingPathExtension().lastPathComponent, centeredAt: point)
                } else {
                    let asset = try await ImageImporter.shared.decode(url, remainingPixels: remaining.pixels)
                    insert(asset, centeredAt: point)
                }
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
          }
          endEdit()
          request.completion.resume()
        }
        isImporting = false
        if !failures.isEmpty { importError = failures.joined(separator: "\n\n") }
    }

    func insert(_ asset: ImportedImage, centeredAt point: CGPoint? = nil) {
        beginEdit("Import Image")
        defer { endEdit() }
        if document == nil {
            document = CanvasDocument(width: asset.image.width, height: asset.image.height)
            viewport.fit(documentSize: document!.size)
        }
        guard let document else { return }
        let center = point ?? CGPoint(x: CGFloat(document.width) / 2, y: CGFloat(document.height) / 2)
        var layer = ImageLayer(asset: asset, origin: CGPoint(
            x: floor(center.x - CGFloat(asset.image.width) / 2),
            y: floor(center.y - CGFloat(asset.image.height) / 2)))
        layer.parentID = activeLayer?.isGroup == true ? activeLayerID : activeLayer?.parentID
        if let parent = layer.parentID { collapsedGroupIDs.remove(parent) }
        self.document?.layers.append(layer)
        activeLayerID = layer.id
    }

    /// Puts the sheet up before the file is read, so a big PSD doesn't leave the click unanswered.
    /// `finishPSDReading` fills it in, or takes it away when there is nothing to report.
    func beginPSDReading(title: String, confirmTitle: String) {
        guard confirmConversions == nil else { return }
        conversionCancelled = false
        conversionRequest = PSDConversionRequest(title: title, confirmTitle: confirmTitle, conversions: [], isReading: true)
        showsConversionSheet = true
    }
    func finishPSDReading(_ conversions: [PSDConversion]) async -> Bool {
        if let confirmConversions {
            if conversions.isEmpty { return true }
            return await confirmConversions(conversions)
        }
        if conversionCancelled { endPSDReading(); return false }
        guard !conversions.isEmpty else { endPSDReading(); return true }
        return await withCheckedContinuation { continuation in
            conversionContinuation = continuation
            conversionRequest?.conversions = conversions
            conversionRequest?.isReading = false
        }
    }
    /// Takes the sheet away without an answer: nothing to report, or the read failed.
    func endPSDReading() {
        guard conversionContinuation == nil else { return }
        showsConversionSheet = false
        conversionRequest = nil
    }
    func confirmPSDConversions(_ conversions: [PSDConversion], title: String, confirmTitle: String) async -> Bool {
        if let confirmConversions { return await confirmConversions(conversions) }
        return await withCheckedContinuation { continuation in
            conversionContinuation = continuation
            conversionRequest = PSDConversionRequest(title: title, confirmTitle: confirmTitle, conversions: conversions)
            showsConversionSheet = true
        }
    }

    func finishConversion(_ confirmed: Bool) {
        if !confirmed, conversionRequest?.isReading == true { conversionCancelled = true }
        showsConversionSheet = false
        conversionRequest = nil
        let continuation = conversionContinuation
        conversionContinuation = nil
        continuation?.resume(returning: confirmed)
    }

    func insertPhotoshop(_ imported: PSDImport, named: String, centeredAt point: CGPoint? = nil) throws {
        beginEdit("Import Photoshop File")
        defer { endEdit() }
        var incoming = imported.layers
        let wrapping = document != nil
        let added = incoming.count + (wrapping ? 1 : 0)
        if (document?.layers.count ?? 0) + added > LayerLimitError.maximum { throw LayerLimitError() }
        if document == nil {
            document = CanvasDocument(width: imported.width, height: imported.height, layers: incoming,
                                      resolution: imported.resolution, guides: imported.guides)
            document?.psdExtras = imported.extras
            viewport.fit(documentSize: document!.size)
            // The topmost layer that shows, not a hidden Photoshop placeholder.
            activeLayerID = incoming.last(where: { $0.parentID == nil && !$0.isPhotoshopPlaceholder })?.id
                ?? incoming.last(where: { !$0.isPhotoshopPlaceholder })?.id ?? incoming.last?.id
            return
        }
        guard document != nil else { return }
        var group = ImageLayer(name: named, blankSize: document!.size)
        group.isGroup = true
        group.parentID = activeLayer?.isGroup == true ? activeLayerID : activeLayer?.parentID
        if let point {
            let box = incoming.filter { !$0.isGroup }.reduce(CGRect.null) { $0.union(CGRect(origin: $1.origin, size: $1.size)) }
            if !box.isNull, !box.isInfinite, !box.isEmpty, box.origin.x.isFinite, box.origin.y.isFinite {
                let dx = point.x - box.midX, dy = point.y - box.midY
                for index in incoming.indices {
                    incoming[index].transform.origin.x += dx
                    incoming[index].transform.origin.y += dy
                    // A mask placed apart from its layer moves with it.
                    incoming[index].mask?.placement?.origin.x += dx
                    incoming[index].mask?.placement?.origin.y += dy
                }
            }
        }
        for index in incoming.indices where incoming[index].parentID == nil {
            incoming[index].parentID = group.id
        }
        self.document?.layers.append(group)
        self.document?.layers.append(contentsOf: incoming)
        if let parent = group.parentID { collapsedGroupIDs.remove(parent) }
        collapsedGroupIDs.remove(group.id)
        activeLayerID = group.id
    }

    /// `emptyLayer` starts the canvas with a selected blank "Layer 1", as File > New does.
    func createDocument(width: Int, height: Int, emptyLayer: Bool = false) {
        guard !isProjectBusy, !isImporting, (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height) else { return }
        commitTransform()
        beginEdit("New Canvas")
        defer { endEdit() }
        var document = CanvasDocument(width: width, height: height)
        let layer = emptyLayer ? ImageLayer(name: "Layer 1", blankSize: document.size) : nil
        if let layer { document.layers = [layer] }
        self.document = document
        activeLayerID = layer?.id
        renamingLayerID = nil
        viewport.fit(documentSize: document.size)
        showsNewDocument = false
    }

    func fit() {
        guard let document else { return }
        viewport.fit(documentSize: document.size)
    }

    func zoom(to value: CGFloat, anchor: CGPoint? = nil) {
        guard let document else { return }
        viewport.setZoom(value, anchoredAt: anchor ?? viewport.center, documentSize: document.size)
    }

    /// Step through stable keyboard zoom levels while keeping the viewport center fixed.
    enum PreviewZoomCommand { case zoomIn, zoomOut, fit, actual }

    func zoomKeyboard(by step: Int) {
        guard let document, step != 0 else { return }
        let target = viewport.keyboardZoomTarget(by: step)
        guard target != viewport.zoom else { return }
        viewport.setZoom(target, anchoredAt: viewport.center, documentSize: document.size)
    }
}
