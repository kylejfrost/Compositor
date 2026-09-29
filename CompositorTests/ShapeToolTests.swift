import AppKit
import Testing
@testable import Compositor

@MainActor
struct ShapeToolTests {
    private func makeSession() -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 100, height: 80, emptyLayer: true)
        session.selectTool(.shape)
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        return session
    }
    private func drag(_ session: EditorSession, from start: CGPoint, to end: CGPoint, square: Bool = false, fromCenter: Bool = false) {
        session.beginShape(at: start)
        session.dragShape(to: end, square: square, fromCenter: fromCenter)
        session.finishShape()
    }
    /// The flattened document as RGBA bytes, and a reader for one pixel's red and alpha.
    private func pixels(_ session: EditorSession) async throws -> (Int, Int) -> (red: Int, alpha: Int) {
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
                                              count: image.width * image.height * 4))
        let width = image.width
        return { x, y in (Int(bytes[(y * width + x) * 4]), Int(bytes[(y * width + x) * 4 + 3])) }
    }

    @Test func rectangleFillsANewLayerWithTheForegroundColorAsOneUndoStep() async throws {
        let session = makeSession()
        session.selectAll()
        let count = session.history.undoCount
        drag(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 30))
        let document = try #require(session.document)
        #expect(document.layers.map(\.name) == ["Layer 1", "Rectangle 1"])
        #expect(session.activeLayer?.name == "Rectangle 1" && session.history.undoCount == count + 1)
        #expect(session.activeLayer?.transform.origin == CGPoint(x: 10, y: 10)
                && session.activeLayer?.transform.size == CGSize(width: 30, height: 20))
        #expect(session.selection != nil) // unlike Paste, drawing a shape keeps the selection
        let pixel = try await pixels(session)
        #expect(pixel(25, 20) == (255, 255) && pixel(10, 10) == (255, 255) && pixel(39, 29) == (255, 255))
        #expect(pixel(9, 20).alpha == 0 && pixel(40, 20).alpha == 0 && pixel(25, 30).alpha == 0)

        drag(session, from: CGPoint(x: 60, y: 10), to: CGPoint(x: 70, y: 20))
        #expect(session.activeLayer?.name == "Rectangle 2")
        session.undo()
        session.undo()
        #expect(session.document?.layers.map(\.name) == ["Layer 1"])
    }

    @Test func ellipseLeavesItsCornersClearWithShiftCircleAndOptionFromCenter() async throws {
        let session = makeSession()
        session.toggleShapeKind()
        #expect(session.shapeKind == .ellipse)
        drag(session, from: CGPoint(x: 50, y: 40), to: CGPoint(x: 60, y: 45), square: true, fromCenter: true)
        #expect(session.activeLayer?.name == "Ellipse 1")
        #expect(session.activeLayer?.transform.origin == CGPoint(x: 40, y: 30)
                && session.activeLayer?.transform.size == CGSize(width: 20, height: 20))
        let pixel = try await pixels(session)
        #expect(pixel(50, 40) == (255, 255) && pixel(41, 40).alpha > 0 && pixel(50, 31).alpha > 0)
        #expect(pixel(40, 30).alpha == 0 && pixel(59, 49).alpha == 0) // outside the circle, inside its box
    }

    @Test func aClickEscapeOrToolSwitchMakesNoLayer() {
        let session = makeSession()
        let count = session.history.undoCount
        session.beginShape(at: CGPoint(x: 20, y: 20))
        session.finishShape()
        session.beginShape(at: CGPoint(x: 20, y: 20))
        session.dragShape(to: CGPoint(x: 50, y: 50), square: false, fromCenter: false)
        #expect(session.shapeDraft?.rect == CGRect(x: 20, y: 20, width: 30, height: 30))
        session.cancelShape()
        session.beginShape(at: CGPoint(x: 20, y: 20))
        session.dragShape(to: CGPoint(x: 50, y: 50), square: false, fromCenter: false)
        session.selectTool(.brush)
        #expect(session.shapeDraft == nil && session.history.undoCount == count)
        #expect(session.document?.layers.count == 1)
    }

    /// A corner radius cuts the rectangle's corners; one larger than half the shorter side makes a pill.
    @Test func roundedRectanglesFollowTheRadiusAndClampToAPill() async throws {
        let session = makeSession()
        session.shapeCornerRadius = 8
        drag(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 40)) // 40 × 30
        session.shapeCornerRadius = 500
        drag(session, from: CGPoint(x: 55, y: 50), to: CGPoint(x: 95, y: 70)) // 40 × 20: radius 10
        let pixel = try await pixels(session)
        #expect(pixel(10, 10).alpha == 0, "the corner is cut away")
        #expect(pixel(11, 11).alpha == 0)
        #expect(pixel(13, 13).alpha == 255, "inside the rounded corner")
        #expect(pixel(30, 10).alpha == 255, "straight edges stay full")
        #expect(pixel(30, 25) == (255, 255))
        #expect(pixel(55, 50).alpha == 0, "the pill's corner is round")
        #expect(pixel(75, 60) == (255, 255))
        #expect(session.document?.layers.count == 3)

        session.toggleShapeKind()
        session.beginShape(at: CGPoint(x: 5, y: 5))
        #expect(session.shapeDraft?.cornerRadius == 0, "ellipses take no radius")
        session.cancelShape()
    }

    /// A red 40 × 30 rectangle whose blue 4 px stroke is `enabled` (centered on the edge).
    private func strokedRectangle(enabled: Bool = true) -> LayerShapeStyle {
        LayerShapeStyle(kind: .rectangle, red: 1, green: 0, blue: 0, cornerRadius: 0,
                        stroke: ShapeStroke(enabled: enabled, width: 4, red: 0, green: 0, blue: 1, alignment: .center))
    }

    private func rgba(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let index = (y * image.width + x) * 4
        return (0..<4).map { Int(bytes[index + $0]) }
    }

    /// The stroke is drawn inside the layer's box, around the shape; a switched-off stroke draws nothing. On a line
    /// the stroke is the line's own color, so it draws a wider line.
    @Test func shapeStrokesDrawWithinTheLayerAndDisabledOnesDoNot() throws {
        let size = CGSize(width: 40, height: 30)
        let stroked = try EditorSession.shapeImage(strokedRectangle(), size: size)
        #expect(try rgba(stroked, x: 1, y: 15) == [0, 0, 255, 255] && rgba(stroked, x: 3, y: 15) == [0, 0, 255, 255])
        #expect(try rgba(stroked, x: 20, y: 1) == [0, 0, 255, 255])
        #expect(try rgba(stroked, x: 5, y: 15) == [255, 0, 0, 255] && rgba(stroked, x: 20, y: 15) == [255, 0, 0, 255])
        let plain = try EditorSession.shapeImage(strokedRectangle(enabled: false), size: size)
        #expect(try rgba(plain, x: 1, y: 15) == [255, 0, 0, 255])

        var line = LayerShapeStyle(kind: .line, red: 1, green: 0, blue: 0, cornerRadius: 0, lineWidth: 4,
                                   start: CGPoint(x: 0.25, y: 0.5), end: CGPoint(x: 0.75, y: 0.5))
        let thin = try EditorSession.shapeImage(line, size: CGSize(width: 40, height: 20))
        line.stroke = ShapeStroke(enabled: true, width: 6, red: 1, green: 0, blue: 0, alignment: .center)
        let wide = try EditorSession.shapeImage(line, size: CGSize(width: 40, height: 20))
        #expect(try rgba(thin, x: 20, y: 6)[3] == 0 && rgba(wide, x: 20, y: 6) == [255, 0, 0, 255])
        #expect(try rgba(thin, x: 20, y: 10) == [255, 0, 0, 255])
    }

    /// Scaling the layer redraws the stroke at its width; Image Size scales the width with the image; a project
    /// saves and reopens it.
    @Test func aStrokedShapeKeepsItsStrokeThroughResizingAndSaving() async throws {
        let session = makeSession()
        let style = strokedRectangle()
        let image = try EditorSession.shapeImage(style, size: CGSize(width: 40, height: 30))
        session.addPixelLayer(image, at: CGPoint(x: 10, y: 10), name: "Rectangle 1", editName: "Rectangle",
                              dropsSelection: false, shape: LayerShape(style: style, image: image))
        let index = try #require(session.document?.layers.firstIndex { $0.name == "Rectangle 1" })
        let id = try #require(session.document?.layers[index].id)
        session.document?.layers[index].transform.size = CGSize(width: 80, height: 60)
        session.redrawShape(at: index)
        let redrawn = try #require(session.document?.layers[index].liveShape)
        #expect(redrawn.style == style && redrawn.image.width == 80)
        #expect(try rgba(redrawn.image, x: 3, y: 30) == [0, 0, 255, 255] && rgba(redrawn.image, x: 5, y: 30) == [255, 0, 0, 255])

        #expect(style.scaled(by: 2)?.stroke?.width == 8)
        #expect(style.scaled(by: 200) == nil, "an 800 px stroke is more than a shape can hold")
        let resized = try await ImageResizer.shared.resize(try #require(session.projectSnapshot()),
            to: ImageSizeOptions(width: 200, height: 160, resolution: 72))
        session.applyImageSize(resized)
        let scaled = try #require(session.document?.layers.first { $0.id == id }?.liveShape)
        #expect(scaled.style.stroke?.width == 8 && scaled.image.width == 160)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShapeToolTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Stroke.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.layers.first { $0.id == id }?.shape == scaled.style)
        let reopened = EditorSession()
        reopened.installProject(loaded, from: url)
        #expect(reopened.document?.layers.first { $0.id == id }?.liveShape?.style == scaled.style)
        let json = String(decoding: try Data(contentsOf: url.appendingPathComponent("manifest.json")), as: UTF8.self)
        #expect(json.contains("\"alignment\" : \"center\""))
    }

    /// A switched-off stroke isn't drawn, so Image Size holds it within the widest a stroke can be rather than
    /// turning the shape into pixels.
    @Test func imageSizeKeepsAShapeLiveWhoseStrokeIsOff() async throws {
        var style = strokedRectangle(enabled: false)
        style.stroke?.width = 400
        let scaled = try #require(style.scaled(by: 2))
        #expect(scaled.stroke?.width == ShapeStroke.maxWidth && scaled.stroke?.enabled == false)
        var enabled = style
        enabled.stroke?.enabled = true
        #expect(enabled.scaled(by: 2) == nil, "an enabled 800 px stroke still can't be held")

        let session = makeSession()
        let image = try EditorSession.shapeImage(style, size: CGSize(width: 40, height: 30))
        session.addPixelLayer(image, at: CGPoint(x: 10, y: 10), name: "Rectangle 1", editName: "Rectangle",
                              dropsSelection: false, shape: LayerShape(style: style, image: image))
        let id = try #require(session.activeLayerID)
        let resized = try await ImageResizer.shared.resize(try #require(session.projectSnapshot()),
            to: ImageSizeOptions(width: 200, height: 160, resolution: 72))
        session.applyImageSize(resized)
        let live = try #require(session.document?.layers.first { $0.id == id }?.liveShape)
        #expect(live.style.stroke?.width == ShapeStroke.maxWidth && live.image.width == 80)
    }

    // MARK: addShapeLayer and updateShapeStyle

    @Test func addShapeLayerMakesALiveShapeAboveTheActiveLayerAsOneStep() throws {
        let session = makeSession()
        let count = session.history.undoCount
        let id = try session.addShapeLayer(.rectangle, rect: CGRect(x: 10, y: 10, width: 30, height: 20),
                                           color: PaletteColor(red: 0, green: 0, blue: 1), cornerRadius: 6, lineWidth: 4, ends: nil)
        let layer = try #require(session.document?.layers.first { $0.id == id })
        #expect(session.activeLayerID == id && layer.name == "Rectangle 1")
        #expect(session.document?.layers.map(\.name) == ["Layer 1", "Rectangle 1"])
        #expect(layer.transform.origin == CGPoint(x: 10, y: 10) && layer.transform.size == CGSize(width: 30, height: 20))
        let style = try #require(layer.liveShape?.style)
        #expect(style.kind == .rectangle && style.cornerRadius == 6 && style.lineWidth == nil && style.blue == 1 && style.red == 0)
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "Rectangle")
        #expect(session.foregroundColor == PaletteColor(red: 1, green: 0, blue: 0) && session.shapeCornerRadius == 0,
                "the Shape tool's own settings are left alone")

        // A line is its ends' box with room for its thickness; the ends are kept as fractions of that box.
        let line = try session.addShapeLayer(.line, rect: .zero, color: PaletteColor(red: 0, green: 1, blue: 0), cornerRadius: 9,
                                             lineWidth: 4, ends: (CGPoint(x: 10, y: 50), CGPoint(x: 50, y: 50)))
        let drawn = try #require(session.document?.layers.first { $0.id == line })
        #expect(drawn.name == "Line 1")
        #expect(drawn.transform.origin == CGPoint(x: 8, y: 48) && drawn.transform.size == CGSize(width: 44, height: 4))
        let lineStyle = try #require(drawn.liveShape?.style)
        #expect(lineStyle.lineWidth == 4 && lineStyle.cornerRadius == 0)
        #expect(lineStyle.start == CGPoint(x: 2.0 / 44, y: 0.5) && lineStyle.end == CGPoint(x: 42.0 / 44, y: 0.5))
    }

    @Test func addShapeLayerRefusesWhatItCannotDraw() throws {
        let session = makeSession()
        let red = PaletteColor(red: 1, green: 0, blue: 0)
        #expect(throws: ShapeLayerError.empty) {
            try session.addShapeLayer(.ellipse, rect: CGRect(x: 10, y: 10, width: 0.5, height: 20), color: red, cornerRadius: 0,
                                      lineWidth: 4, ends: nil)
        }
        #expect(throws: ShapeLayerError.tooLarge) {
            try session.addShapeLayer(.rectangle, rect: CGRect(x: 0, y: 0, width: 20_000, height: 20_000), color: red,
                                      cornerRadius: 0, lineWidth: 4, ends: nil)
        }
        #expect(throws: ShapeLayerError.outOfBounds) {
            try session.addShapeLayer(.rectangle, rect: CGRect(x: 2_000_000, y: 0, width: 20, height: 20), color: red,
                                      cornerRadius: 0, lineWidth: 4, ends: nil)
        }
        session.beginText(at: CGPoint(x: 5, y: 5), newLayer: true)
        #expect(throws: ShapeLayerError.notEditable) {
            try session.addShapeLayer(.rectangle, rect: CGRect(x: 0, y: 0, width: 20, height: 20), color: red,
                                      cornerRadius: 0, lineWidth: 4, ends: nil)
        }
        session.cancelText()
        #expect(session.document?.layers.count == 1 && session.brushError == nil)
    }

    /// The layer's box is the shape grown by how far its stroke reaches past it, so adding, widening, moving or switching
    /// off a stroke grows or shrinks the box around its center and the shape itself stays where it was.
    @Test func updateShapeStyleGrowsTheBoxByTheStrokeOutsetAndKeepsTheShape() async throws {
        let session = makeSession()
        let id = try session.addShapeLayer(.rectangle, rect: CGRect(x: 10, y: 10, width: 40, height: 30),
                                           color: PaletteColor(red: 1, green: 0, blue: 0), cornerRadius: 0, lineWidth: 4, ends: nil)
        func layer() throws -> ImageLayer { try #require(session.document?.layers.first { $0.id == id }) }
        let count = session.history.undoCount
        let stroke = ShapeStroke(enabled: true, width: 4, red: 0, green: 0, blue: 1, alignment: .center)
        try session.updateShapeStyle(id) { $0.stroke = stroke }
        #expect(try layer().transform.origin == CGPoint(x: 8, y: 8) && layer().transform.size == CGSize(width: 44, height: 34))
        #expect(try layer().liveShape?.style.stroke == stroke && layer().liveShape?.image.width == 44)
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "Edit Shape")
        var pixel = try await pixels(session)
        #expect(pixel(8, 25).alpha == 255 && pixel(8, 25).red == 0, "the stroke's outer half lies outside the shape")
        #expect(pixel(7, 25).alpha == 0 && pixel(12, 25) == (255, 255))

        // The same style again is no step, and doesn't grow the box twice.
        try session.updateShapeStyle(id) { $0.stroke = stroke }
        #expect(try session.history.undoCount == count + 1 && layer().transform.size == CGSize(width: 44, height: 34))

        try session.updateShapeStyle(id) { $0.stroke?.alignment = .outside }
        #expect(try layer().transform.origin == CGPoint(x: 6, y: 6) && layer().transform.size == CGSize(width: 48, height: 38))
        try session.updateShapeStyle(id) { $0.stroke?.enabled = false }
        #expect(try layer().transform.origin == CGPoint(x: 10, y: 10) && layer().transform.size == CGSize(width: 40, height: 30))
        try session.updateShapeStyle(id) { $0.red = 0; $0.green = 1 }
        #expect(try layer().liveShape?.style.green == 1 && layer().transform.size == CGSize(width: 40, height: 30))
        pixel = try await pixels(session)
        #expect(pixel(10, 10).alpha == 255 && pixel(10, 10).red == 0 && pixel(9, 10).alpha == 0)
        #expect(session.history.undoCount == count + 4)

        session.undo()
        session.undo()
        session.undo()
        session.undo()
        #expect(try layer().liveShape?.style.stroke == nil && layer().transform.size == CGSize(width: 40, height: 30))

        // A turned shape grows around its center too.
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].transform.rotation = 30
        let center = try layer().transform.center
        try session.updateShapeStyle(id) { $0.stroke = stroke }
        #expect(try layer().transform.center == center && layer().transform.rotation == 30)
    }

    /// A line's thickness (its weight and a stroke in its color) reaches past its ends, so a thicker line grows its box
    /// and the ends stay where they were in the document.
    @Test func updateShapeStyleKeepsALinesEndsWhereTheyWere() throws {
        let session = makeSession()
        let id = try session.addShapeLayer(.line, rect: .zero, color: PaletteColor(red: 1, green: 0, blue: 0), cornerRadius: 0,
                                           lineWidth: 4, ends: (CGPoint(x: 10, y: 20), CGPoint(x: 50, y: 60)))
        func ends() throws -> (CGPoint, CGPoint) {
            let layer = try #require(session.document?.layers.first { $0.id == id })
            let style = try #require(layer.liveShape?.style)
            return (layer.transform.point(try #require(style.start)), layer.transform.point(try #require(style.end)))
        }
        func near(_ a: (CGPoint, CGPoint), _ b: (CGPoint, CGPoint)) -> Bool {
            hypot(a.0.x - b.0.x, a.0.y - b.0.y) < 0.001 && hypot(a.1.x - b.1.x, a.1.y - b.1.y) < 0.001
        }
        let placed = (CGPoint(x: 10, y: 20), CGPoint(x: 50, y: 60))
        #expect(try near(ends(), placed))
        try session.updateShapeStyle(id) { $0.lineWidth = 10 }
        #expect(session.document?.layers.first { $0.id == id }?.transform.size == CGSize(width: 50, height: 50))
        #expect(try near(ends(), placed))
        try session.updateShapeStyle(id) { $0.stroke = ShapeStroke(enabled: true, width: 2, red: 1, green: 0, blue: 0, alignment: .outside) }
        #expect(session.document?.layers.first { $0.id == id }?.transform.size == CGSize(width: 54, height: 54))
        #expect(try near(ends(), placed))
    }

    @Test func updateShapeStyleRefusesLayersThatAreNotLiveShapes() throws {
        let session = makeSession()
        let pixels = try #require(session.activeLayerID)
        #expect(throws: ShapeLayerError.notShape) { try session.updateShapeStyle(pixels) { $0.red = 0 } }
        let id = try session.addShapeLayer(.ellipse, rect: CGRect(x: 10, y: 10, width: 30, height: 20),
                                           color: PaletteColor(red: 1, green: 0, blue: 0), cornerRadius: 0, lineWidth: 4, ends: nil)
        #expect(throws: ProjectError.self) {
            try session.updateShapeStyle(id) { $0.stroke = ShapeStroke(enabled: true, width: 900, red: 0, green: 0, blue: 0, alignment: .inside) }
        }
        session.beginText(at: CGPoint(x: 5, y: 5), newLayer: true)
        #expect(throws: ShapeLayerError.notEditable) { try session.updateShapeStyle(id) { $0.red = 0 } }
        session.cancelText()
    }

    /// While a shape is being scaled, one whose corners, stroke or line keep their size in document pixels is drawn at
    /// the size it's dragged to rather than stretched; a plain rectangle just stretches.
    @Test(arguments: [ShapeKind.rectangle, .ellipse])
    func scalingAStrokedShapePreviewsItsStrokeAtItsWidth(_ kind: ShapeKind) throws {
        let session = makeSession()
        let id = try session.addShapeLayer(kind, rect: CGRect(x: 10, y: 10, width: 40, height: 30),
                                           color: PaletteColor(red: 1, green: 0, blue: 0), cornerRadius: 0, lineWidth: 4, ends: nil)
        let plain = try #require(session.document?.layers.first { $0.id == id })
        session.beginTransform()
        #expect(session.shapeTransformPreview(for: plain, transform: plain.transform.scaled(toPercent: 200, pixelSize: CGSize(width: 40, height: 30))) == nil)
        session.cancelTransform()

        try session.updateShapeStyle(id) { $0.stroke = ShapeStroke(enabled: true, width: 4, red: 0, green: 0, blue: 1, alignment: .inside) }
        let stroked = try #require(session.document?.layers.first { $0.id == id })
        session.beginTransform()
        let doubled = stroked.transform.scaled(toPercent: 200, pixelSize: CGSize(width: 40, height: 30))
        let preview = try #require(session.shapeTransformPreview(for: stroked, transform: doubled))
        #expect(preview.width == 80 && preview.height == 60)
        // Across the middle, the 4-pixel stroke is still 4 pixels wide, not 8.
        #expect(try rgba(preview, x: 2, y: 30) == [0, 0, 255, 255] && rgba(preview, x: 5, y: 30) == [255, 0, 0, 255])
        session.cancelTransform()
    }

    @Test func scalingALinePreviewsItAtItsThickness() throws {
        let session = makeSession()
        let id = try session.addShapeLayer(.line, rect: .zero, color: PaletteColor(red: 1, green: 0, blue: 0), cornerRadius: 0,
                                           lineWidth: 4, ends: (CGPoint(x: 10, y: 20), CGPoint(x: 50, y: 20)))
        let line = try #require(session.document?.layers.first { $0.id == id })
        session.beginTransform()
        var taller = line.transform
        taller.size.height *= 4
        let preview = try #require(session.shapeTransformPreview(for: line, transform: taller))
        #expect(preview.height == 16)
        #expect(try rgba(preview, x: 22, y: 1)[3] == 0 && rgba(preview, x: 22, y: 8) == [255, 0, 0, 255])
        session.cancelTransform()
    }

    /// A stroke is at most 500 px wide, and arrived with version 10.
    @Test func projectsRejectStrokesTheyCannotHold() async throws {
        let session = makeSession()
        let style = strokedRectangle()
        let image = try EditorSession.shapeImage(style, size: CGSize(width: 40, height: 30))
        session.addPixelLayer(image, at: CGPoint(x: 10, y: 10), name: "Rectangle 1", editName: "Rectangle",
                              dropsSelection: false, shape: LayerShape(style: style, image: image))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShapeToolTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let edits: [(name: String, edit: (_ manifest: inout [String: Any], _ stroke: inout [String: Any]) -> Void)] = [
            ("width 501", { _, stroke in stroke["width"] = 501 }),
            ("negative width", { _, stroke in stroke["width"] = -1 }),
            ("version 9", { manifest, _ in manifest["version"] = 9 }),
        ]
        for (name, edit) in edits {
            let url = folder.appendingPathComponent("\(UUID()).comp")
            try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
            let file = url.appendingPathComponent("manifest.json")
            var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            var layers = try #require(json["layers"] as? [[String: Any]])
            let index = try #require(layers.firstIndex { $0["shape"] != nil })
            var shape = try #require(layers[index]["shape"] as? [String: Any])
            var stroke = try #require(shape["stroke"] as? [String: Any])
            edit(&json, &stroke)
            shape["stroke"] = stroke
            layers[index]["shape"] = shape
            json["layers"] = layers
            try JSONSerialization.data(withJSONObject: json).write(to: file)
            do {
                _ = try await ProjectStore.shared.load(from: url)
                Issue.record("Accepted a stroke with \(name)")
            } catch ProjectError.invalid {
            } catch {
                Issue.record("\(name): expected ProjectError.invalid, got \(error)")
            }
        }
    }
}
