import Foundation
import GRDB

// MARK: - AnnotationLayer

/// A layer containing annotation shapes with visibility and blend settings.
/// Layers are rendered bottom-to-top (index 0 is the bottom layer).
struct AnnotationLayer: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var isVisible: Bool
    var isLocked: Bool
    var opacity: CGFloat
    var blendMode: LayerBlendMode
    var shapes: [AnnotationShape]

    init(
        id: UUID = UUID(),
        name: String = "Layer",
        isVisible: Bool = true,
        isLocked: Bool = false,
        opacity: CGFloat = 1.0,
        blendMode: LayerBlendMode = .normal,
        shapes: [AnnotationShape] = []
    ) {
        self.id = id
        self.name = name
        self.isVisible = isVisible
        self.isLocked = isLocked
        self.opacity = opacity
        self.blendMode = blendMode
        self.shapes = shapes
    }

    /// Whether this layer has any content
    var isEmpty: Bool {
        shapes.isEmpty
    }

    // Custom Codable to handle missing isLocked in legacy JSON
    enum CodingKeys: String, CodingKey {
        case id, name, isVisible, isLocked, opacity, blendMode, shapes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        opacity = try container.decodeIfPresent(CGFloat.self, forKey: .opacity) ?? 1.0
        blendMode = try container.decodeIfPresent(LayerBlendMode.self, forKey: .blendMode) ?? .normal
        shapes = try container.decode([AnnotationShape].self, forKey: .shapes)
    }
}

// MARK: - LayerBlendMode

/// Blend mode for layer compositing
enum LayerBlendMode: String, Codable, CaseIterable {
    case normal
    case multiply
    case screen
    case overlay
    case darken
    case lighten

    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .multiply: return "Multiply"
        case .screen: return "Screen"
        case .overlay: return "Overlay"
        case .darken: return "Darken"
        case .lighten: return "Lighten"
        }
    }
}

// MARK: - PhotoAdjustments

/// Non-destructive photo adjustments stored alongside annotations.
/// Applied as CIFilter pipeline during rendering.
struct PhotoAdjustments: Codable, Equatable {
    var brightness: CGFloat  // -1.0 to 1.0, default 0
    var contrast: CGFloat    // 0.0 to 4.0, default 1.0
    var saturation: CGFloat  // 0.0 to 2.0, default 1.0
    var temperature: CGFloat // 2000-10000, default 6500
    var tint: CGFloat        // -100 to 100, default 0
    var sharpness: CGFloat   // 0 to 2.0, default 0
    var vignette: CGFloat    // 0 to 2.0, default 0

    init(
        brightness: CGFloat = 0,
        contrast: CGFloat = 1.0,
        saturation: CGFloat = 1.0,
        temperature: CGFloat = 6500,
        tint: CGFloat = 0,
        sharpness: CGFloat = 0,
        vignette: CGFloat = 0
    ) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.temperature = temperature
        self.tint = tint
        self.sharpness = sharpness
        self.vignette = vignette
    }

    static let identity = PhotoAdjustments()

    /// Whether any adjustment differs from default
    var isModified: Bool {
        brightness != 0 || contrast != 1.0 || saturation != 1.0 ||
        temperature != 6500 || tint != 0 || sharpness != 0 || vignette != 0
    }
}

// MARK: - AnnotationSet

/// Container for all annotations on a single media file.
/// Stored as JSON for flexibility and easy versioning.
/// Supports multiple layers for organized annotation editing.
struct AnnotationSet: Codable, Equatable {
    var layers: [AnnotationLayer]
    var activeLayerId: UUID?
    var cropRegion: NormalizedRect?
    var adjustments: PhotoAdjustments?

    /// Read-only flattened view of all shapes across all layers.
    /// Use layer-safe mutation APIs (addShape, removeShape, updateShape, etc.) instead of writing through this.
    var shapes: [AnnotationShape] {
        layers.flatMap { $0.shapes }
    }

    init(layers: [AnnotationLayer] = [], activeLayerId: UUID? = nil, cropRegion: NormalizedRect? = nil, adjustments: PhotoAdjustments? = nil) {
        self.layers = layers
        self.activeLayerId = activeLayerId ?? layers.first?.id
        self.cropRegion = cropRegion
        self.adjustments = adjustments
    }

    /// Legacy initializer for backwards compatibility
    init(shapes: [AnnotationShape], cropRegion: NormalizedRect? = nil) {
        if shapes.isEmpty {
            self.layers = []
            self.activeLayerId = nil
        } else {
            let defaultLayer = AnnotationLayer(name: "Layer 1", shapes: shapes)
            self.layers = [defaultLayer]
            self.activeLayerId = defaultLayer.id
        }
        self.cropRegion = cropRegion
    }

    /// Empty annotation set
    static let empty = AnnotationSet()

    /// Total number of shapes across all layers
    var shapeCount: Int {
        layers.reduce(0) { $0 + $1.shapes.count }
    }

    /// Get visible shapes whose bounding rects intersect the given viewport.
    /// Viewport is in normalized coordinates (0-1).
    func visibleShapes(in viewport: NormalizedRect) -> [AnnotationShape] {
        var result: [AnnotationShape] = []
        for layer in layers where layer.isVisible {
            for shape in layer.shapes {
                let bounds = shape.boundingRect
                // AABB intersection
                if bounds.x < viewport.x + viewport.width &&
                   bounds.x + bounds.width > viewport.x &&
                   bounds.y < viewport.y + viewport.height &&
                   bounds.y + bounds.height > viewport.y {
                    result.append(shape)
                }
            }
        }
        return result
    }

    /// Get selectable shape IDs whose bounding rects intersect the given selection rect.
    /// Selection rect is in normalized coordinates (0-1).
    func shapesInRect(_ selectionRect: NormalizedRect) -> [UUID] {
        var result: [UUID] = []
        for layer in layers where layer.isVisible && !layer.isLocked {
            for shape in layer.shapes {
                if rectsIntersect(shape.boundingRect, selectionRect) {
                    result.append(shape.id)
                }
            }
        }
        return result
    }

    private func rectsIntersect(_ a: NormalizedRect, _ b: NormalizedRect) -> Bool {
        let aRight = a.x + a.width
        let aBottom = a.y + a.height
        let bRight = b.x + b.width
        let bBottom = b.y + b.height

        return a.x < bRight && aRight > b.x && a.y < bBottom && aBottom > b.y
    }

    /// Whether this set contains any annotations
    var isEmpty: Bool {
        layers.allSatisfy { $0.isEmpty } && cropRegion == nil && (adjustments == nil || adjustments == .identity)
    }

    /// Get the active layer (where new shapes are added)
    var activeLayer: AnnotationLayer? {
        guard let activeId = activeLayerId else { return layers.first }
        return layers.first { $0.id == activeId }
    }

    /// Get index of active layer
    var activeLayerIndex: Int? {
        guard let activeId = activeLayerId else { return layers.isEmpty ? nil : 0 }
        return layers.firstIndex { $0.id == activeId }
    }

    /// Add a new layer
    mutating func addLayer(name: String? = nil) -> AnnotationLayer {
        let layerNumber = layers.count + 1
        let newLayer = AnnotationLayer(name: name ?? "Layer \(layerNumber)")
        layers.append(newLayer)
        activeLayerId = newLayer.id
        return newLayer
    }

    /// Auto-generate a descriptive name based on the first shape in the layer
    static func autoNameForShape(_ shape: AnnotationShape) -> String {
        switch shape {
        case .rectangle: return "Rectangles"
        case .ellipse: return "Ellipses"
        case .arrow: return "Arrows"
        case .freeform: return "Drawings"
        case .text: return "Text"
        case .mask: return "Masks"
        case .extractedSubject: return "Subjects"
        }
    }

    /// Remove a layer by ID
    mutating func removeLayer(id: UUID) {
        guard let index = layers.firstIndex(where: { $0.id == id }), !layers[index].isLocked else { return }
        layers.remove(at: index)
        // Update active layer if removed
        if activeLayerId == id {
            activeLayerId = layers.first?.id
        }
    }

    /// Move layer from one index to another
    mutating func moveLayer(from source: Int, to destination: Int) {
        guard source != destination,
              source >= 0, source < layers.count, !layers[source].isLocked,
              destination >= 0, destination <= layers.count else { return }
        let layer = layers.remove(at: source)
        let adjustedDestination = destination > source ? destination - 1 : destination
        layers.insert(layer, at: adjustedDestination)
    }

    /// Add shape to active layer
    mutating func addShape(_ shape: AnnotationShape) {
        if layers.isEmpty {
            // Auto-name the new layer based on the first shape type
            let _ = addLayer(name: AnnotationSet.autoNameForShape(shape))
        }
        if let index = activeLayerIndex, !layers[index].isLocked {
            // If this is the first shape in the layer and it has a generic name, rename it
            if layers[index].shapes.isEmpty && layers[index].name.hasPrefix("Layer ") {
                layers[index].name = AnnotationSet.autoNameForShape(shape)
            }
            layers[index].shapes.append(shape)
        }
    }

    /// Find and remove shape by ID from any layer
    mutating func removeShape(id: UUID) {
        for i in layers.indices where !layers[i].isLocked {
            layers[i].shapes.removeAll { $0.id == id }
        }
    }

    /// Find which layer contains a shape
    func layerContaining(shapeId: UUID) -> AnnotationLayer? {
        layers.first { layer in
            layer.shapes.contains { $0.id == shapeId }
        }
    }

    // MARK: - Layer-Safe Mutation APIs

    /// Find the layer and shape indices for a shape by ID
    func shapeLocation(id: UUID) -> (layerIndex: Int, shapeIndex: Int)? {
        for layerIndex in layers.indices {
            if let shapeIndex = layers[layerIndex].shapes.firstIndex(where: { $0.id == id }) {
                return (layerIndex, shapeIndex)
            }
        }
        return nil
    }

    /// Update a shape in place by ID using a mutation closure
    @discardableResult
    mutating func updateShape(id: UUID, _ mutate: (inout AnnotationShape) -> Void) -> Bool {
        guard let location = shapeLocation(id: id), !layers[location.layerIndex].isLocked else { return false }
        mutate(&layers[location.layerIndex].shapes[location.shapeIndex])
        return true
    }

    /// Translate a shape without moving it between layers or modifying locked content.
    @discardableResult
    mutating func translateShape(id: UUID, delta: NormalizedPoint) -> Bool {
        guard let location = shapeLocation(id: id), !layers[location.layerIndex].isLocked else { return false }
        let oldShape = layers[location.layerIndex].shapes[location.shapeIndex]
        let translated = oldShape.translated(by: delta)
        guard translated != oldShape else { return false }
        layers[location.layerIndex].shapes[location.shapeIndex] = translated
        return true
    }

    /// Get a shape by ID
    func shape(id: UUID) -> AnnotationShape? {
        guard let location = shapeLocation(id: id) else { return nil }
        return layers[location.layerIndex].shapes[location.shapeIndex]
    }

    /// Replace a shape by ID with a new shape (layer-safe)
    @discardableResult
    mutating func replaceShape(id: UUID, with newShape: AnnotationShape) -> Bool {
        guard let location = shapeLocation(id: id), !layers[location.layerIndex].isLocked else { return false }
        layers[location.layerIndex].shapes[location.shapeIndex] = newShape
        return true
    }

    /// Add shape to a specific layer by ID
    mutating func addShape(_ shape: AnnotationShape, toLayerId layerId: UUID) {
        guard let index = layers.firstIndex(where: { $0.id == layerId }), !layers[index].isLocked else { return }
        layers[index].shapes.append(shape)
    }

    /// Transform all shapes across all layers (layer boundaries preserved)
    mutating func transformAllShapes(_ transform: (AnnotationShape) -> AnnotationShape) {
        for i in layers.indices where !layers[i].isLocked {
            layers[i].shapes = layers[i].shapes.map(transform)
        }
    }

    /// Mirror all shapes horizontally across all layers
    mutating func mirrorAllHorizontally() {
        transformAllShapes { $0.mirroredHorizontally() }
    }

    /// Mirror all shapes vertically across all layers
    mutating func mirrorAllVertically() {
        transformAllShapes { $0.mirroredVertically() }
    }

    // MARK: - Codable

    /// Format version for migration tracking.
    /// v1 = legacy flat shapes, v2 = layers + adjustments + enhanced text styles.
    static let currentFormatVersion = 2

    enum CodingKeys: String, CodingKey {
        case formatVersion
        case layers
        case activeLayerId
        case cropRegion
        case adjustments
        case shapes // For backwards compatibility
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // formatVersion is read for future migration gates but not stored as a property —
        // we always write currentFormatVersion on encode.
        _ = try container.decodeIfPresent(Int.self, forKey: .formatVersion)

        cropRegion = try container.decodeIfPresent(NormalizedRect.self, forKey: .cropRegion)
        adjustments = try container.decodeIfPresent(PhotoAdjustments.self, forKey: .adjustments)

        // A present layer document must decode successfully. Falling back after
        // a layer error could replace a real document with an empty autosave.
        if container.contains(.layers) {
            layers = try container.decode([AnnotationLayer].self, forKey: .layers)
            activeLayerId = try container.decodeIfPresent(UUID.self, forKey: .activeLayerId) ?? layers.first?.id
        } else if container.contains(.shapes) {
            let legacyShapes = try container.decode([AnnotationShape].self, forKey: .shapes)
            // Migrate the legacy flat-shape format only when layers are absent.
            if legacyShapes.isEmpty {
                layers = []
                activeLayerId = nil
            } else {
                let defaultLayer = AnnotationLayer(name: "Layer 1", shapes: legacyShapes)
                layers = [defaultLayer]
                activeLayerId = defaultLayer.id
            }
        } else {
            throw DecodingError.keyNotFound(CodingKeys.layers, .init(
                codingPath: decoder.codingPath,
                debugDescription: "Annotation document has neither layers nor legacy shapes."
            ))
        }
        guard Set(layers.map(\.id)).count == layers.count,
              Set(shapes.map(\.id)).count == shapes.count else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Annotation layer and shape identifiers must be unique."))
        }
        if let activeLayerId, !layers.contains(where: { $0.id == activeLayerId }) {
            throw DecodingError.dataCorruptedError(forKey: .activeLayerId, in: container,
                debugDescription: "The active annotation layer is missing.")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentFormatVersion, forKey: .formatVersion)
        try container.encode(layers, forKey: .layers)
        try container.encodeIfPresent(activeLayerId, forKey: .activeLayerId)
        try container.encodeIfPresent(cropRegion, forKey: .cropRegion)
        try container.encodeIfPresent(adjustments, forKey: .adjustments)
    }
}

// MARK: - AnnotationShape

/// Individual annotation shape with normalized coordinates (0-1 range).
/// All coordinates are resolution-independent.
enum AnnotationShape: Codable, Equatable, Identifiable {
    case rectangle(id: UUID, rect: NormalizedRect, style: ShapeStyle)
    case ellipse(id: UUID, rect: NormalizedRect, style: ShapeStyle)
    case arrow(id: UUID, from: NormalizedPoint, to: NormalizedPoint, style: ShapeStyle)
    case freeform(id: UUID, points: [NormalizedPoint], style: ShapeStyle)
    case text(id: UUID, position: NormalizedPoint, content: String, style: TextStyle)
    case mask(id: UUID, maskData: Data, bounds: NormalizedRect, blendMode: BlendMode, opacity: CGFloat, featherRadius: CGFloat = 2.0)
    /// Extracted subject layer: lifted subject stored by asset key with transform
    case extractedSubject(id: UUID, assetKey: String, bounds: NormalizedRect, opacity: CGFloat, transform: ShapeTransform, sourceSubjectId: UUID?)

    var id: UUID {
        switch self {
        case .rectangle(let id, _, _): return id
        case .ellipse(let id, _, _): return id
        case .arrow(let id, _, _, _): return id
        case .freeform(let id, _, _): return id
        case .text(let id, _, _, _): return id
        case .mask(let id, _, _, _, _, _): return id
        case .extractedSubject(let id, _, _, _, _, _): return id
        }
    }

    /// Get bounding rect for hit testing
    var boundingRect: NormalizedRect {
        switch self {
        case .rectangle(_, let rect, _), .ellipse(_, let rect, _):
            return rect
        case .arrow(_, let from, let to, let style):
            let minX = min(from.x, to.x) - style.strokeWidth / 100
            let minY = min(from.y, to.y) - style.strokeWidth / 100
            let maxX = max(from.x, to.x) + style.strokeWidth / 100
            let maxY = max(from.y, to.y) + style.strokeWidth / 100
            return NormalizedRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .freeform(_, let points, let style):
            guard !points.isEmpty else {
                return NormalizedRect(x: 0, y: 0, width: 0, height: 0)
            }
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            let minX = (xs.min() ?? 0) - style.strokeWidth / 100
            let minY = (ys.min() ?? 0) - style.strokeWidth / 100
            let maxX = (xs.max() ?? 0) + style.strokeWidth / 100
            let maxY = (ys.max() ?? 0) + style.strokeWidth / 100
            return NormalizedRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .text(_, let position, _, _):
            // Approximate text bounds - actual bounds depend on font size
            return NormalizedRect(x: position.x, y: position.y, width: 0.2, height: 0.05)
        case .mask(_, _, let bounds, _, _, _):
            return bounds
        case .extractedSubject(_, _, let bounds, _, let transform, _):
            // Apply transform offset to bounds
            return NormalizedRect(
                x: bounds.x + transform.offset.x,
                y: bounds.y + transform.offset.y,
                width: bounds.width * transform.scale,
                height: bounds.height * transform.scale
            )
        }
    }

    /// Check if point is within this shape (for selection)
    func contains(point: NormalizedPoint, tolerance: CGFloat = 0.02) -> Bool {
        let rect = boundingRect
        let expanded = NormalizedRect(
            x: rect.x - tolerance,
            y: rect.y - tolerance,
            width: rect.width + tolerance * 2,
            height: rect.height + tolerance * 2
        )
        return expanded.contains(point)
    }

    /// Mirror shape horizontally (flip around vertical axis)
    func mirroredHorizontally() -> AnnotationShape {
        switch self {
        case .rectangle(let id, let rect, let style):
            return .rectangle(id: id, rect: rect.mirroredHorizontally(), style: style)
        case .ellipse(let id, let rect, let style):
            return .ellipse(id: id, rect: rect.mirroredHorizontally(), style: style)
        case .arrow(let id, let from, let to, let style):
            return .arrow(id: id, from: from.mirroredHorizontally(), to: to.mirroredHorizontally(), style: style)
        case .freeform(let id, let points, let style):
            return .freeform(id: id, points: points.map { $0.mirroredHorizontally() }, style: style)
        case .text(let id, let position, let content, let style):
            return .text(id: id, position: position.mirroredHorizontally(), content: content, style: style)
        case .mask(let id, let maskData, let bounds, let blendMode, let opacity, let featherRadius):
            return .mask(id: id, maskData: maskData, bounds: bounds.mirroredHorizontally(), blendMode: blendMode, opacity: opacity, featherRadius: featherRadius)
        case .extractedSubject(let id, let assetKey, let bounds, let opacity, let transform, let sourceId):
            let mirroredOffset = NormalizedPoint(x: -transform.offset.x, y: transform.offset.y)
            let mirroredTransform = ShapeTransform(offset: mirroredOffset, scale: transform.scale, rotation: -transform.rotation)
            return .extractedSubject(id: id, assetKey: assetKey, bounds: bounds.mirroredHorizontally(), opacity: opacity, transform: mirroredTransform, sourceSubjectId: sourceId)
        }
    }

    /// Check if this shape is a mask
    var isMask: Bool {
        if case .mask = self { return true }
        return false
    }

    /// Get feather radius if this is a mask shape
    var featherRadius: CGFloat? {
        if case .mask(_, _, _, _, _, let radius) = self {
            return radius
        }
        return nil
    }

    /// Return a copy with updated feather radius (only affects mask shapes)
    func withFeatherRadius(_ radius: CGFloat) -> AnnotationShape {
        if case .mask(let id, let maskData, let bounds, let blendMode, let opacity, _) = self {
            return .mask(id: id, maskData: maskData, bounds: bounds, blendMode: blendMode, opacity: opacity, featherRadius: radius)
        }
        return self
    }

    /// Mirror shape vertically (flip around horizontal axis)
    func mirroredVertically() -> AnnotationShape {
        switch self {
        case .rectangle(let id, let rect, let style):
            return .rectangle(id: id, rect: rect.mirroredVertically(), style: style)
        case .ellipse(let id, let rect, let style):
            return .ellipse(id: id, rect: rect.mirroredVertically(), style: style)
        case .arrow(let id, let from, let to, let style):
            return .arrow(id: id, from: from.mirroredVertically(), to: to.mirroredVertically(), style: style)
        case .freeform(let id, let points, let style):
            return .freeform(id: id, points: points.map { $0.mirroredVertically() }, style: style)
        case .text(let id, let position, let content, let style):
            return .text(id: id, position: position.mirroredVertically(), content: content, style: style)
        case .mask(let id, let maskData, let bounds, let blendMode, let opacity, let featherRadius):
            return .mask(id: id, maskData: maskData, bounds: bounds.mirroredVertically(), blendMode: blendMode, opacity: opacity, featherRadius: featherRadius)
        case .extractedSubject(let id, let assetKey, let bounds, let opacity, let transform, let sourceId):
            let mirroredOffset = NormalizedPoint(x: transform.offset.x, y: -transform.offset.y)
            let mirroredTransform = ShapeTransform(offset: mirroredOffset, scale: transform.scale, rotation: -transform.rotation)
            return .extractedSubject(id: id, assetKey: assetKey, bounds: bounds.mirroredVertically(), opacity: opacity, transform: mirroredTransform, sourceSubjectId: sourceId)
        }
    }

    /// Check if this shape is an extracted subject
    var isExtractedSubject: Bool {
        if case .extractedSubject = self { return true }
        return false
    }

    /// Get transform if this is an extracted subject
    var transform: ShapeTransform? {
        if case .extractedSubject(_, _, _, _, let transform, _) = self {
            return transform
        }
        return nil
    }

    /// Return a copy with updated transform (only affects extracted subjects)
    func withTransform(_ newTransform: ShapeTransform) -> AnnotationShape {
        if case .extractedSubject(let id, let assetKey, let bounds, let opacity, _, let sourceId) = self {
            return .extractedSubject(id: id, assetKey: assetKey, bounds: bounds, opacity: opacity, transform: newTransform, sourceSubjectId: sourceId)
        }
        return self
    }

    /// Return a copy with updated bounding rect (for resize operations)
    func withBoundingRect(_ newRect: NormalizedRect) -> AnnotationShape {
        switch self {
        case .rectangle(let id, _, let style):
            return .rectangle(id: id, rect: newRect, style: style)
        case .ellipse(let id, _, let style):
            return .ellipse(id: id, rect: newRect, style: style)
        case .mask(let id, let data, _, let blend, let opacity, let feather):
            return .mask(id: id, maskData: data, bounds: newRect, blendMode: blend, opacity: opacity, featherRadius: feather)
        case .extractedSubject(let id, let key, _, let opacity, let transform, let source):
            return .extractedSubject(id: id, assetKey: key, bounds: newRect, opacity: opacity, transform: transform, sourceSubjectId: source)
        default:
            return self // Arrows, freeform, text don't have simple bounding rect resize
        }
    }

    /// Return a translated copy, retaining shape identity and all style data.
    func translated(by delta: NormalizedPoint) -> AnnotationShape {
        func point(_ value: NormalizedPoint) -> NormalizedPoint {
            NormalizedPoint(x: value.x + delta.x, y: value.y + delta.y)
        }
        func rect(_ value: NormalizedRect) -> NormalizedRect {
            NormalizedRect(x: value.x + delta.x, y: value.y + delta.y, width: value.width, height: value.height)
        }
        switch self {
        case .rectangle(let id, let bounds, let style):
            return .rectangle(id: id, rect: rect(bounds), style: style)
        case .ellipse(let id, let bounds, let style):
            return .ellipse(id: id, rect: rect(bounds), style: style)
        case .arrow(let id, let from, let to, let style):
            return .arrow(id: id, from: point(from), to: point(to), style: style)
        case .freeform(let id, let points, let style):
            return .freeform(id: id, points: points.map(point), style: style)
        case .text(let id, let position, let content, let style):
            return .text(id: id, position: point(position), content: content, style: style)
        case .mask(let id, let data, let bounds, let blend, let opacity, let feather):
            return .mask(id: id, maskData: data, bounds: rect(bounds), blendMode: blend, opacity: opacity, featherRadius: feather)
        case .extractedSubject(let id, let key, let bounds, let opacity, let transform, let source):
            return .extractedSubject(id: id, assetKey: key, bounds: bounds, opacity: opacity, transform: transform.translated(by: delta), sourceSubjectId: source)
        }
    }

    /// Create a duplicate with a new ID and optional positional offset.
    /// Used by copy/paste and duplicate operations.
    func duplicated(newId: UUID = UUID(), offset: CGFloat = 0.02) -> AnnotationShape {
        switch self {
        case .rectangle(_, let rect, let style):
            return .rectangle(id: newId, rect: NormalizedRect(x: rect.x + offset, y: rect.y + offset, width: rect.width, height: rect.height), style: style)
        case .ellipse(_, let rect, let style):
            return .ellipse(id: newId, rect: NormalizedRect(x: rect.x + offset, y: rect.y + offset, width: rect.width, height: rect.height), style: style)
        case .arrow(_, let from, let to, let style):
            return .arrow(id: newId, from: NormalizedPoint(x: from.x + offset, y: from.y + offset), to: NormalizedPoint(x: to.x + offset, y: to.y + offset), style: style)
        case .freeform(_, let points, let style):
            return .freeform(id: newId, points: points.map { NormalizedPoint(x: $0.x + offset, y: $0.y + offset) }, style: style)
        case .text(_, let pos, let content, let style):
            return .text(id: newId, position: NormalizedPoint(x: pos.x + offset, y: pos.y + offset), content: content, style: style)
        case .mask(_, let data, let bounds, let blend, let opacity, let feather):
            return .mask(id: newId, maskData: data, bounds: NormalizedRect(x: bounds.x + offset, y: bounds.y + offset, width: bounds.width, height: bounds.height), blendMode: blend, opacity: opacity, featherRadius: feather)
        case .extractedSubject(_, let key, let bounds, let opacity, let transform, let source):
            return .extractedSubject(id: newId, assetKey: key, bounds: bounds, opacity: opacity, transform: transform.translated(by: NormalizedPoint(x: offset, y: offset)), sourceSubjectId: source)
        }
    }
}

// MARK: - BlendMode

/// Blend mode for mask annotations
enum BlendMode: String, Codable, CaseIterable {
    case normal
    case multiply
    case screen
    case overlay
    case maskRemove   // Use as cutout (remove background)
    case maskKeep     // Use as preserve area
    case maskRestore  // Paint adjusted original pixels back through this mask
}

// MARK: - ShapeTransform

/// Transform state for shapes (position, scale, rotation).
/// Used for extracted subjects and other movable shapes.
struct ShapeTransform: Codable, Equatable {
    /// Position offset from original bounds (normalized 0-1)
    var offset: NormalizedPoint
    /// Scale factor (1.0 = original size)
    var scale: CGFloat
    /// Rotation in degrees
    var rotation: CGFloat

    init(offset: NormalizedPoint = NormalizedPoint(x: 0, y: 0), scale: CGFloat = 1.0, rotation: CGFloat = 0) {
        self.offset = offset
        self.scale = scale
        self.rotation = rotation
    }

    static let identity = ShapeTransform()

    /// Apply translation delta
    func translated(by delta: NormalizedPoint) -> ShapeTransform {
        ShapeTransform(
            offset: NormalizedPoint(x: offset.x + delta.x, y: offset.y + delta.y),
            scale: scale,
            rotation: rotation
        )
    }

    /// Apply scale factor
    func scaled(by factor: CGFloat) -> ShapeTransform {
        ShapeTransform(offset: offset, scale: scale * factor, rotation: rotation)
    }

    /// Apply rotation delta
    func rotated(by degrees: CGFloat) -> ShapeTransform {
        ShapeTransform(offset: offset, scale: scale, rotation: rotation + degrees)
    }
}

// MARK: - ShapeStyle

/// Visual style for annotation shapes
struct ShapeStyle: Codable, Equatable {
    var strokeColor: UInt32  // RGBA packed as 0xRRGGBBAA
    var strokeWidth: CGFloat
    var fillColor: UInt32?   // nil = no fill

    init(strokeColor: UInt32 = UInt32(AnnotationColorDefaults.systemAccentRGBA), strokeWidth: CGFloat = 3, fillColor: UInt32? = nil) {
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.fillColor = fillColor
    }

    // MARK: - Color Helpers

    var strokeRed: CGFloat { CGFloat((strokeColor >> 24) & 0xFF) / 255.0 }
    var strokeGreen: CGFloat { CGFloat((strokeColor >> 16) & 0xFF) / 255.0 }
    var strokeBlue: CGFloat { CGFloat((strokeColor >> 8) & 0xFF) / 255.0 }
    var strokeAlpha: CGFloat { CGFloat(strokeColor & 0xFF) / 255.0 }

    var fillRed: CGFloat? {
        guard let fill = fillColor else { return nil }
        return CGFloat((fill >> 24) & 0xFF) / 255.0
    }
    var fillGreen: CGFloat? {
        guard let fill = fillColor else { return nil }
        return CGFloat((fill >> 16) & 0xFF) / 255.0
    }
    var fillBlue: CGFloat? {
        guard let fill = fillColor else { return nil }
        return CGFloat((fill >> 8) & 0xFF) / 255.0
    }
    var fillAlpha: CGFloat? {
        guard let fill = fillColor else { return nil }
        return CGFloat(fill & 0xFF) / 255.0
    }

    /// Create RGBA color from components
    static func rgba(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1.0) -> UInt32 {
        let rByte = UInt32(max(0, min(255, r * 255)))
        let gByte = UInt32(max(0, min(255, g * 255)))
        let bByte = UInt32(max(0, min(255, b * 255)))
        let aByte = UInt32(max(0, min(255, a * 255)))
        return (rByte << 24) | (gByte << 16) | (bByte << 8) | aByte
    }

    // MARK: - Preset Styles

    static var defaultRectangle: ShapeStyle {
        ShapeStyle(strokeColor: UInt32(AnnotationColorDefaults.systemAccentRGBA), strokeWidth: 3, fillColor: nil)
    }
    static var defaultEllipse: ShapeStyle {
        ShapeStyle(strokeColor: UInt32(AnnotationColorDefaults.systemAccentRGBA), strokeWidth: 3, fillColor: nil)
    }
    static var defaultArrow: ShapeStyle {
        ShapeStyle(strokeColor: UInt32(AnnotationColorDefaults.systemAccentRGBA), strokeWidth: 3, fillColor: nil)
    }
    static var defaultFreeform: ShapeStyle {
        ShapeStyle(strokeColor: UInt32(AnnotationColorDefaults.systemAccentRGBA), strokeWidth: 4, fillColor: nil)
    }
    static let highlighter = ShapeStyle(strokeColor: 0xFFFF0080, strokeWidth: 20, fillColor: nil)

    // MARK: - Highlighter Presets

    /// Preset highlighter colors (yellow, green, pink, blue, orange)
    static let highlighterPresets: [UInt32] = [
        0xFFFF0080,  // Yellow (default)
        0x00FF0080,  // Green
        0xFF69B480,  // Pink
        0x00BFFF80,  // Blue
        0xFF8C0080,  // Orange
    ]

    /// Create a highlighter style with a custom color (50% alpha applied)
    static func highlighterStyle(color: UInt32) -> ShapeStyle {
        // Take the RGB from the color, apply 50% alpha
        let rgb = color & 0xFFFFFF00
        return ShapeStyle(strokeColor: rgb | 0x80, strokeWidth: 20, fillColor: nil)
    }
}

// MARK: - TextStyle

/// Visual style for text annotations
struct TextStyle: Codable, Equatable {
    var fontSize: CGFloat
    var textColor: UInt32  // RGBA
    var backgroundColor: UInt32?  // nil = transparent
    var fontWeight: FontWeight
    var alignment: TextAlignment
    var strokeColor: UInt32?  // nil = no stroke
    var strokeWidth: CGFloat
    var shadowColor: UInt32?  // nil = no shadow
    var shadowRadius: CGFloat
    var shadowOffset: CGFloat
    var fontFamily: String?  // nil = system font

    init(
        fontSize: CGFloat = 16,
        textColor: UInt32 = 0xFFFFFFFF,
        backgroundColor: UInt32? = 0x00000080,
        fontWeight: FontWeight = .regular,
        alignment: TextAlignment = .left,
        strokeColor: UInt32? = nil,
        strokeWidth: CGFloat = 0,
        shadowColor: UInt32? = nil,
        shadowRadius: CGFloat = 0,
        shadowOffset: CGFloat = 2,
        fontFamily: String? = nil
    ) {
        self.fontSize = fontSize
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.fontWeight = fontWeight
        self.alignment = alignment
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.shadowColor = shadowColor
        self.shadowRadius = shadowRadius
        self.shadowOffset = shadowOffset
        self.fontFamily = fontFamily
    }

    enum FontWeight: String, Codable, CaseIterable {
        case light
        case regular
        case medium
        case semibold
        case bold
    }

    enum TextAlignment: String, Codable, CaseIterable {
        case left
        case center
        case right
    }

    // Custom Codable for backwards compatibility with legacy JSON missing new fields
    enum CodingKeys: String, CodingKey {
        case fontSize, textColor, backgroundColor, fontWeight
        case alignment, strokeColor, strokeWidth
        case shadowColor, shadowRadius, shadowOffset, fontFamily
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try container.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? 16
        textColor = try container.decodeIfPresent(UInt32.self, forKey: .textColor) ?? 0xFFFFFFFF
        backgroundColor = try container.decodeIfPresent(UInt32.self, forKey: .backgroundColor)
        fontWeight = try container.decodeIfPresent(FontWeight.self, forKey: .fontWeight) ?? .regular
        alignment = try container.decodeIfPresent(TextAlignment.self, forKey: .alignment) ?? .left
        strokeColor = try container.decodeIfPresent(UInt32.self, forKey: .strokeColor)
        strokeWidth = try container.decodeIfPresent(CGFloat.self, forKey: .strokeWidth) ?? 0
        shadowColor = try container.decodeIfPresent(UInt32.self, forKey: .shadowColor)
        shadowRadius = try container.decodeIfPresent(CGFloat.self, forKey: .shadowRadius) ?? 0
        shadowOffset = try container.decodeIfPresent(CGFloat.self, forKey: .shadowOffset) ?? 2
        fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily)
    }

    // MARK: - Color Helpers

    var textRed: CGFloat { CGFloat((textColor >> 24) & 0xFF) / 255.0 }
    var textGreen: CGFloat { CGFloat((textColor >> 16) & 0xFF) / 255.0 }
    var textBlue: CGFloat { CGFloat((textColor >> 8) & 0xFF) / 255.0 }
    var textAlpha: CGFloat { CGFloat(textColor & 0xFF) / 255.0 }

    static let `default` = TextStyle()

    // MARK: - Meme Presets

    /// Classic top/bottom meme style (Impact, white with black stroke)
    static let memeClassic = TextStyle(
        fontSize: 48,
        textColor: 0xFFFFFFFF,
        backgroundColor: nil,
        fontWeight: .bold,
        alignment: .center,
        strokeColor: 0x000000FF,
        strokeWidth: 2,
        fontFamily: "Impact"
    )

    /// Modern meme style (bold white with shadow)
    static let memeModern = TextStyle(
        fontSize: 36,
        textColor: 0xFFFFFFFF,
        backgroundColor: nil,
        fontWeight: .bold,
        alignment: .center,
        shadowColor: 0x000000CC,
        shadowRadius: 4,
        shadowOffset: 2
    )

    /// Caption style (smaller, with semi-transparent background)
    static let caption = TextStyle(
        fontSize: 18,
        textColor: 0xFFFFFFFF,
        backgroundColor: 0x000000AA,
        fontWeight: .medium,
        alignment: .center
    )
}

// MARK: - Normalized Geometry

/// Point with normalized coordinates (0-1 range)
struct NormalizedPoint: Codable, Equatable, Hashable {
    var x: CGFloat
    var y: CGFloat

    init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    /// Convert to CGPoint scaled to image size
    func scaled(to size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
    }

    /// Create from CGPoint in image coordinates
    static func normalized(from point: CGPoint, in size: CGSize) -> NormalizedPoint {
        NormalizedPoint(x: point.x / size.width, y: point.y / size.height)
    }

    /// Distance to another point
    func distance(to other: NormalizedPoint) -> CGFloat {
        let dx = x - other.x
        let dy = y - other.y
        return sqrt(dx * dx + dy * dy)
    }

    /// Mirror point horizontally (flip x around 0.5)
    func mirroredHorizontally() -> NormalizedPoint {
        NormalizedPoint(x: 1.0 - x, y: y)
    }

    /// Mirror point vertically (flip y around 0.5)
    func mirroredVertically() -> NormalizedPoint {
        NormalizedPoint(x: x, y: 1.0 - y)
    }
}

/// Rectangle with normalized coordinates (0-1 range)
struct NormalizedRect: Codable, Equatable, Hashable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Create from two corner points
    init(from p1: NormalizedPoint, to p2: NormalizedPoint) {
        self.x = min(p1.x, p2.x)
        self.y = min(p1.y, p2.y)
        self.width = abs(p2.x - p1.x)
        self.height = abs(p2.y - p1.y)
    }

    var origin: NormalizedPoint {
        NormalizedPoint(x: x, y: y)
    }

    var center: NormalizedPoint {
        NormalizedPoint(x: x + width / 2, y: y + height / 2)
    }

    /// Convert to CGRect scaled to image size
    func scaled(to size: CGSize) -> CGRect {
        CGRect(
            x: x * size.width,
            y: y * size.height,
            width: width * size.width,
            height: height * size.height
        )
    }

    /// Create from CGRect in image coordinates
    static func normalized(from rect: CGRect, in size: CGSize) -> NormalizedRect {
        NormalizedRect(
            x: rect.origin.x / size.width,
            y: rect.origin.y / size.height,
            width: rect.width / size.width,
            height: rect.height / size.height
        )
    }

    /// Check if point is within this rect
    func contains(_ point: NormalizedPoint) -> Bool {
        point.x >= x && point.x <= x + width &&
        point.y >= y && point.y <= y + height
    }

    /// Mirror rect horizontally (flip around vertical axis at 0.5)
    func mirroredHorizontally() -> NormalizedRect {
        NormalizedRect(x: 1.0 - x - width, y: y, width: width, height: height)
    }

    /// Mirror rect vertically (flip around horizontal axis at 0.5)
    func mirroredVertically() -> NormalizedRect {
        NormalizedRect(x: x, y: 1.0 - y - height, width: width, height: height)
    }
}

// MARK: - AnnotationRecord (GRDB)

/// Database record for storing annotations
struct AnnotationRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "annotations"

    let id: UUID
    let itemId: UUID
    let mediaFileIndex: Int
    var assetID: UUID?
    var annotationsJSON: String
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        itemId: UUID,
        mediaFileIndex: Int = 0,
        annotationSet: AnnotationSet,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        assetID: UUID? = nil
    ) {
        self.id = id
        self.itemId = itemId
        self.mediaFileIndex = mediaFileIndex
        self.assetID = assetID
        self.annotationsJSON = (try? JSONEncoder().encode(annotationSet))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - GRDB PersistableRecord

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["itemId"] = itemId.uuidString
        container["mediaFileIndex"] = mediaFileIndex
        container["asset_id"] = assetID?.uuidString
        container["annotationsJSON"] = annotationsJSON
        container["createdAt"] = createdAt
        container["updatedAt"] = updatedAt
    }

    // MARK: - GRDB FetchableRecord

    init(row: Row) throws {
        guard let idString: String = row["id"],
              let id = UUID(uuidString: idString) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Invalid or missing UUID in id column"
                )
            )
        }
        guard let itemIdString: String = row["itemId"],
              let itemId = UUID(uuidString: itemIdString) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Invalid or missing UUID in itemId column"
                )
            )
        }
        self.id = id
        self.itemId = itemId
        self.mediaFileIndex = row["mediaFileIndex"]
        self.assetID = (row["asset_id"] as String?).flatMap(UUID.init(uuidString:))
        self.annotationsJSON = row["annotationsJSON"]
        self.createdAt = row["createdAt"]
        self.updatedAt = row["updatedAt"]
    }

    // MARK: - Conversion

    /// Compatibility accessor for legacy read-only callers. Persistence and the
    /// editor must use decodedAnnotationSet() so corrupt data is never replaced.
    func toAnnotationSet() -> AnnotationSet {
        (try? decodedAnnotationSet()) ?? .empty
    }

    /// Decode a stored document without hiding corruption as an empty document.
    func decodedAnnotationSet() throws -> AnnotationSet {
        try JSONDecoder().decode(AnnotationSet.self, from: Data(annotationsJSON.utf8))
    }

    /// Update the annotation set JSON
    mutating func updateAnnotationSet(_ set: AnnotationSet) {
        self.annotationsJSON = (try? JSONEncoder().encode(set))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        self.updatedAt = Date()
    }

    // MARK: - Schema

    static func createTable(in db: Database) throws {
        try db.create(table: databaseTableName, ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("itemId", .text).notNull()
            t.column("mediaFileIndex", .integer).notNull().defaults(to: 0)
            t.column("annotationsJSON", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }

        // Unique constraint on (itemId, mediaFileIndex)
        try db.create(
            index: "idx_annotations_item_file",
            on: databaseTableName,
            columns: ["itemId", "mediaFileIndex"],
            unique: true,
            ifNotExists: true
        )
    }

    // MARK: - Fetch Methods

    /// Fetch annotation for a specific item and file index
    static func fetch(db: Database, itemId: UUID, mediaFileIndex: Int, assetID: UUID? = nil) throws -> AnnotationRecord? {
        try AnnotationRecord.fetchOne(
            db,
            sql: "SELECT * FROM annotations WHERE itemId = ? AND \(assetID == nil ? "mediaFileIndex" : "asset_id") = ? AND association_state = 'attached'",
            arguments: assetID.map { StatementArguments([itemId.uuidString, $0.uuidString]) } ?? StatementArguments([itemId.uuidString as any DatabaseValueConvertible, mediaFileIndex as any DatabaseValueConvertible])
        )
    }

    /// Fetch all annotations for an item (all media files)
    static func fetchAll(db: Database, itemId: UUID) throws -> [AnnotationRecord] {
        try AnnotationRecord.fetchAll(
            db,
            sql: "SELECT * FROM annotations WHERE itemId = ? AND association_state = 'attached' ORDER BY mediaFileIndex",
            arguments: [itemId.uuidString]
        )
    }

    /// Delete all annotations for an item
    static func deleteAll(db: Database, itemId: UUID) throws {
        try db.execute(
            sql: "DELETE FROM annotations WHERE itemId = ?",
            arguments: [itemId.uuidString]
        )
    }

    /// Upsert annotation (insert or update)
    func upsert(db: Database) throws {
        let asset = try ItemAssetStore.prepareWrite(in: db, itemID: itemId, assetID: assetID, index: mediaFileIndex)
        try db.execute(
            sql: """
                INSERT INTO annotations (id, itemId, mediaFileIndex, annotationsJSON, createdAt, updatedAt, asset_id, association_state)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'attached')
                ON CONFLICT(itemId, mediaFileIndex) DO UPDATE SET
                    annotationsJSON = excluded.annotationsJSON,
                    updatedAt = excluded.updatedAt,
                    asset_id = excluded.asset_id, association_state = 'attached'
            """,
            arguments: [id.uuidString, itemId.uuidString, asset.index, annotationsJSON, createdAt, updatedAt, asset.id.uuidString]
        )
    }
}

// MARK: - Annotation Tool

/// Available annotation drawing tools
enum AnnotationTool: String, CaseIterable, Identifiable {
    case select
    case rectangle
    case ellipse
    case arrow
    case freeform
    case text
    case highlighter
    case backgroundRemove  // One-click background removal
    case personSegment     // One-click person isolation
    case subjectSelect     // Click to select specific subject (sniper tool)
    case eraser            // Manual mask brush
    case mirrorH           // Flip horizontal
    case mirrorV           // Flip vertical

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .select: return "Select"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Circle"
        case .arrow: return "Arrow"
        case .freeform: return "Freeform"
        case .text: return "Text"
        case .highlighter: return "Highlighter"
        case .backgroundRemove: return "Remove Background"
        case .personSegment: return "Isolate Person"
        case .subjectSelect: return "Select Subject"
        case .eraser: return "Eraser"
        case .mirrorH: return "Flip Horizontal"
        case .mirrorV: return "Flip Vertical"
        }
    }

    var systemImage: String {
        switch self {
        case .select: return "cursorarrow"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.right"
        case .freeform: return "scribble"
        case .text: return "textformat"
        case .highlighter: return "highlighter"
        case .backgroundRemove: return "person.fill.viewfinder"
        case .personSegment: return "figure.stand"
        case .subjectSelect: return "scope"
        case .eraser: return "eraser"
        // Issue #8: Use simpler icons for mirror tools
        case .mirrorH: return "arrow.left.arrow.right"
        case .mirrorV: return "arrow.up.arrow.down"
        }
    }

    var defaultStyle: ShapeStyle {
        switch self {
        case .select: return .defaultRectangle
        case .rectangle: return .defaultRectangle
        case .ellipse: return .defaultEllipse
        case .arrow: return .defaultArrow
        case .freeform: return .defaultFreeform
        case .text: return .defaultRectangle
        case .highlighter: return .highlighter
        case .backgroundRemove: return .defaultRectangle
        case .personSegment: return .defaultRectangle
        case .subjectSelect: return .defaultRectangle
        case .eraser: return .defaultFreeform
        case .mirrorH: return .defaultRectangle
        case .mirrorV: return .defaultRectangle
        }
    }

    /// Keyboard shortcut key for this tool (shown in tooltip)
    var shortcutKey: String? {
        switch self {
        case .select: return "V"
        case .rectangle: return "R"
        case .ellipse: return "C"  // C for Circle/ellipse
        case .arrow: return "A"
        case .freeform: return "F"
        case .text: return "T"  // T for Text
        case .highlighter: return "H"
        case .backgroundRemove: return "B"
        case .personSegment: return "P"
        case .subjectSelect: return "S"
        case .eraser: return "E"
        case .mirrorH: return nil
        case .mirrorV: return nil
        }
    }

    /// Display name with keyboard shortcut for tooltip
    var displayNameWithShortcut: String {
        if let key = shortcutKey {
            return "\(displayName) (\(key))"
        }
        return displayName
    }
}

// MARK: - Eraser Mode

/// Mode for the eraser brush tool - add to mask (keep area) or remove from mask (erase area)
enum EraserMode: String, CaseIterable, Identifiable {
    case addToMask      // Paint area to KEEP (add to mask)
    case removeFromMask // Paint area to ERASE (remove from mask)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .addToMask: return "Restore (bring back original)"
        case .removeFromMask: return "Erase (remove area)"
        }
    }

    var shortName: String {
        switch self {
        case .addToMask: return "Restore"
        case .removeFromMask: return "Erase"
        }
    }

    var systemImage: String {
        switch self {
        case .addToMask: return "plus.circle"
        case .removeFromMask: return "minus.circle"
        }
    }

    var blendMode: BlendMode {
        switch self {
        case .addToMask: return .maskRestore
        case .removeFromMask: return .maskRemove
        }
    }
}
