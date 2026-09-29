import CoreGraphics
import Foundation

// The one mapping in each direction between a document layer and its saved record. Everything that rebuilds a
// layer or a record — saving, loading, Image Size, Canvas Size, Crop, copies, pixel edits — goes through these, so a
// property added to a layer is carried everywhere by adding it here.

extension ProjectLayerRecord {
    /// The layer as saved. Text and shape sources are written only while they are live (their raster is the layer's).
    init(layer: ImageLayer) {
        self.init(id: layer.id, name: layer.name, isVisible: layer.isVisible, transform: layer.transform,
            imageFile: layer.asset == nil ? nil : "\(layer.id.uuidString).png", parentID: layer.parentID,
            isGroup: layer.isGroup, opacity: layer.opacity, blendMode: layer.blendMode,
            maskFile: layer.mask == nil ? nil : "\(layer.id.uuidString).mask.png", maskEnabled: layer.mask?.isEnabled,
            maskSourceID: layer.maskSourceID, adjustment: layer.adjustment, maskPlacement: layer.mask?.placement,
            maskLinked: layer.mask?.isLinked, shape: layer.liveShape?.style, effects: layer.effects,
            text: layer.liveText?.style, locks: layer.locks.isEmpty ? nil : layer.locks,
            fillOpacity: layer.fillOpacity == 1 ? nil : layer.fillOpacity,
            psd: layer.psdExtras.map { PSDLayerExtrasRecord($0, layerID: layer.id) },
            smartObject: layer.smartObject?.info,
            smartObjectFile: layer.smartObject.flatMap { smartObject in
                smartObject.payload.map { SmartObjectFileRecord(layerID: layer.id, info: smartObject.info, payload: $0) }
            })
    }

    /// Canvas Size and Crop: the layer and its own mask placement move by `offset`; nothing is resampled, so text,
    /// shapes and effects are unchanged.
    nonisolated func translated(by offset: CGPoint) -> ProjectLayerRecord {
        var record = self
        record.transform.origin.x += offset.x
        record.transform.origin.y += offset.y
        record.maskPlacement?.origin.x += offset.x
        record.maskPlacement?.origin.y += offset.y
        return record
    }

    /// Image Size: the layer placed at `transform` with pixels resampled by `sx` × `sy` in its own axes. Text sizes
    /// follow the pixels, shape corners, line and stroke widths the shorter side, effects the average. A source that no
    /// longer validates at the new size is dropped, leaving the layer as its resampled pixels. Text still showing
    /// Photoshop's pixels scales what import made of it too, so a writer still tells it is untouched.
    nonisolated func scaled(x sx: CGFloat, y sy: CGFloat, transform: LayerTransform, maskPlacement: LayerTransform?) -> ProjectLayerRecord {
        var record = self
        record.transform = transform
        record.maskPlacement = maskPlacement
        record.text = text?.scaled(x: sx, y: sy)
        if let extras = psd?.extras, extras.importedTextAnchor != nil, let imported = extras.importedText {
            record.psd?.extras.importedText = imported.scaled(x: sx, y: sy) ?? imported
        }
        record.shape = shape?.scaled(by: min(sx, sy))
        record.effects = effects?.scaled(by: (sx + sy) / 2)
        return record
    }
}

extension ImageLayer {
    /// The layer a record describes, its pixels and mask taken from `snapshot`. Text and shape sources are live
    /// against the snapshot's raster.
    init(record: ProjectLayerRecord, snapshot: ProjectSnapshot) {
        let asset = snapshot.images[record.id]
        self.init(id: record.id, asset: asset, name: record.name, isVisible: record.isVisible,
            transform: record.transform, parentID: record.parentID, isGroup: record.isGroup == true,
            opacity: record.opacity ?? 1, blendMode: record.blendMode ?? .normal, mask: snapshot.mask(for: record),
            maskSourceID: record.maskSourceID, adjustment: record.adjustment,
            shape: LayerShape.loaded(record.shape, image: asset?.image), effects: record.effects,
            text: LayerText.loaded(record.text, image: asset?.image), locks: record.locks ?? [],
            fillOpacity: record.fillOpacity ?? 1, psdExtras: record.psd?.extras,
            smartObject: record.smartObject.map { LayerSmartObject(info: $0, payload: record.smartObjectFile?.payload) })
    }

    /// A destructive pixel edit: new pixels, placement and mask. Everything drawn around the layer and every other
    /// property is kept (locks, fill and Photoshop data included); the text, shape or smart object it was is not,
    /// since these pixels are no longer what that source draws, nor are Photoshop shape blocks import kept.
    func replacingPixels(_ asset: ImportedImage?, transform: LayerTransform, mask: LayerMask?) -> ImageLayer {
        var layer = self
        layer.asset = asset
        layer.transform = transform
        layer.mask = mask
        layer.isGroup = false
        layer.adjustment = nil
        layer.shape = nil
        layer.text = nil
        layer.smartObject = nil
        // Photoshop shape blocks Compositor kept (`importedShapeFrame`) don't describe these pixels.
        layer.psdExtras?.importedShapeFrame = nil
        return layer
    }

    /// This layer under a new identity, every property carried: duplicates and copies between projects. The copy is
    /// a new Photoshop layer too: it keeps the Photoshop blocks but not the layer IDs (`lyid`, its folder divider's
    /// too), so a writer gives it IDs of its own instead of two layers sharing one. A smart object's copy shares its
    /// contents, as a duplicated Photoshop smart object does.
    func copy(as id: UUID) -> ImageLayer {
        let extras = psdExtras?.withoutLayerIDs
        return ImageLayer(id: id, asset: asset, name: name, isVisible: isVisible, transform: transform, parentID: parentID,
            isGroup: isGroup, opacity: opacity, blendMode: blendMode, mask: mask, maskSourceID: maskSourceID,
            adjustment: adjustment, shape: shape, effects: effects, text: text, locks: locks, fillOpacity: fillOpacity,
            psdExtras: extras, smartObject: smartObject)
    }
}

extension LayerTextStyle {
    /// Sizes in layer pixels scaled with those pixels: type, leading and tracking follow the height, the letters' width
    /// the difference between the two (type scaled unevenly is drawn wider or narrower), and a paragraph's text area
    /// both sides, to whole pixels (its padding is fixed, so the text wraps as it did). Nil when the result is outside
    /// what text supports.
    nonisolated func scaled(x sx: CGFloat, y sy: CGFloat) -> LayerTextStyle? {
        var style = self
        style.fontSize *= sy
        style.leading *= sy
        style.tracking *= sy
        let widthScale = self.widthScale * sx / sy
        style.horizontalScale = abs(widthScale - 1) < 0.0001 ? nil : widthScale
        let padding = 2 * LayerTextStyle.padding
        style.boxSize = boxSize.map {
            CGSize(width: (($0.width - padding) * sx + padding).rounded(), height: (($0.height - padding) * sy + padding).rounded())
        }
        return style.isValid ? style : nil
    }
}

extension LayerShapeStyle {
    /// Corner radius, line width and stroke width in document pixels, scaled by `factor`. Line ends are fractions of
    /// the box. A switched-off stroke isn't drawn, so its width stops at the widest a stroke can be. Nil when the
    /// result is outside what a shape supports.
    nonisolated func scaled(by factor: CGFloat) -> LayerShapeStyle? {
        var style = self
        style.cornerRadius *= factor
        style.lineWidth = lineWidth.map { $0 * factor }
        style.stroke?.width *= factor
        if style.stroke?.enabled == false, let width = style.stroke?.width, width > ShapeStroke.maxWidth {
            style.stroke?.width = ShapeStroke.maxWidth
        }
        guard style.cornerRadius.isFinite, style.lineWidth?.isFinite ?? true, style.stroke?.isValid ?? true else { return nil }
        return style
    }
}

extension LayerEffects {
    /// Sizes, distances and softness scaled by `factor`, each held within what its effect supports.
    nonisolated func scaled(by factor: CGFloat) -> LayerEffects {
        guard factor.isFinite, factor > 0 else { return self }
        func clamp(_ value: CGFloat, _ limit: CGFloat) -> CGFloat { min(max(0, value * factor), limit) }
        var effects = self
        effects.stroke?.size = clamp(stroke?.size ?? 0, StrokeEffect.maxSize)
        effects.shadow?.distance = clamp(shadow?.distance ?? 0, ShadowEffect.maxDistance)
        effects.shadow?.blur = clamp(shadow?.blur ?? 0, ShadowEffect.maxBlur)
        effects.innerShadow?.distance = clamp(innerShadow?.distance ?? 0, InnerShadowEffect.maxDistance)
        effects.innerShadow?.blur = clamp(innerShadow?.blur ?? 0, InnerShadowEffect.maxBlur)
        effects.outerGlow?.size = clamp(outerGlow?.size ?? 0, OuterGlowEffect.maxSize)
        effects.innerGlow?.size = clamp(innerGlow?.size ?? 0, InnerGlowEffect.maxSize)
        return effects
    }
}

extension LayerEffects {
    /// The effects of a layer whose pixels are redrawn with `map` (a layer-pixel vector to the vector it becomes in
    /// the new, unrotated and unflipped raster). Effects are drawn in the layer's own pixels and then placed by its
    /// transform, so a layer shown at 50% draws its 10-pixel stroke 5 pixels wide; baked at twice the size that is
    /// a 10-pixel stroke. Shadow offsets are mapped exactly, so their distance and direction follow the old scale,
    /// rotation and flips. Sizes and softness scale by the average length of the map's two axes: under uneven
    /// scaling the old stroke and blur were wider one way than the other, which one size cannot express.
    nonisolated func baked(through map: CGAffineTransform) -> LayerEffects {
        let factor = (hypot(map.a, map.b) + hypot(map.c, map.d)) / 2
        guard factor.isFinite, factor > 0 else { return self }
        var effects = scaled(by: factor)
        func mapped(_ offset: CGSize, angle: CGFloat, maxDistance: CGFloat) -> (angle: CGFloat, distance: CGFloat) {
            let x = map.a * offset.width + map.c * offset.height, y = map.b * offset.width + map.d * offset.height
            let distance = hypot(x, y)
            guard distance.isFinite, distance > 0 else { return (angle, 0) }
            // The inverse of `offset`: (-cos, sin) × distance, in degrees counterclockwise from the right.
            return (atan2(y, -x) * 180 / .pi, min(distance, maxDistance))
        }
        if let shadow {
            (effects.shadow!.angle, effects.shadow!.distance) = mapped(shadow.offset, angle: shadow.angle, maxDistance: ShadowEffect.maxDistance)
        }
        if let innerShadow {
            (effects.innerShadow!.angle, effects.innerShadow!.distance) = mapped(innerShadow.offset, angle: innerShadow.angle,
                                                                                maxDistance: InnerShadowEffect.maxDistance)
        }
        return effects
    }
}
