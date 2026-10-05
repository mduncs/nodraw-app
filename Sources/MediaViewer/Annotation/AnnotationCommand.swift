import Foundation

// MARK: - AnnotationCommand

/// All possible annotation edit operations expressed as value types.
/// Commands are the single entry point for mutating AnnotationSet state.
/// Each command is reversible — `apply` returns an inverse command for undo.
enum AnnotationCommand: Equatable {

    // MARK: - Shape Operations

    /// Add a shape to the active layer (or a specific layer)
    case addShape(shape: AnnotationShape, layerId: UUID?)

    /// Remove a shape by ID (from whichever layer contains it)
    case removeShape(shapeId: UUID)

    /// Replace a shape with a new version (same ID, different content)
    case replaceShape(shapeId: UUID, newShape: AnnotationShape)

    /// Update a shape's transform (for extracted subjects)
    case translateShape(shapeId: UUID, delta: NormalizedPoint)

    /// Resize a shape to new bounding rect
    case resizeShape(shapeId: UUID, newRect: NormalizedRect)

    // MARK: - Layer Operations

    /// Add a new layer
    case addLayer(name: String, id: UUID = UUID())

    /// Remove a layer by ID
    case removeLayer(layerId: UUID)

    /// Set the active layer
    case setActiveLayer(layerId: UUID)

    /// Toggle layer visibility
    case toggleLayerVisibility(layerId: UUID)

    /// Set layer opacity
    case setLayerOpacity(layerId: UUID, opacity: CGFloat)

    /// Set layer blend mode
    case setLayerBlendMode(layerId: UUID, blendMode: LayerBlendMode)

    /// Rename a layer
    case renameLayer(layerId: UUID, name: String)

    /// Reorder layer
    case moveLayer(fromIndex: Int, toIndex: Int)

    /// Lock/unlock layer
    case setLayerLocked(layerId: UUID, locked: Bool)

    /// Solo layer (show only this layer)
    case soloLayer(layerId: UUID)

    /// Unsolo (restore all visibility)
    case unsoloLayers(previousVisibility: [UUID: Bool])

    /// Duplicate a layer
    case duplicateLayer(layerId: UUID, newLayerId: UUID)

    /// Merge layer down
    case mergeLayerDown(layerId: UUID)

    /// Flatten all layers into one
    case flattenLayers

    // MARK: - Canvas Operations

    /// Mirror all shapes horizontally
    case mirrorAllHorizontally

    /// Mirror all shapes vertically
    case mirrorAllVertically

    /// Set crop region
    case setCropRegion(NormalizedRect?)

    /// Clear all annotations
    case clearAll

    // MARK: - Multi-Select Operations

    /// Move multiple shapes by delta
    case moveShapes(shapeIds: [UUID], delta: NormalizedPoint)

    /// Delete multiple shapes
    case deleteShapes(shapeIds: [UUID])

    /// Duplicate shapes (with new IDs)
    case duplicateShapes(shapeIds: [UUID], newShapes: [AnnotationShape])

    // MARK: - Arrange Operations

    /// Bring shape forward in its layer
    case bringForward(shapeId: UUID)

    /// Send shape backward in its layer
    case sendBackward(shapeId: UUID)

    /// Bring shape to front of its layer
    case bringToFront(shapeId: UUID)

    /// Send shape to back of its layer
    case sendToBack(shapeId: UUID)

    // MARK: - Photo Adjustments

    /// Set photo adjustments
    case setAdjustments(PhotoAdjustments?)

    // MARK: - Batch / Group

    /// Apply multiple commands as an atomic group (for undo as single step)
    case group([AnnotationCommand])

    /// Exact inverse state, including order, active layer, settings, crop and adjustments.
    /// Used by undo/redo; intentionally bypasses edit locks when restoring history.
    case restoreSnapshot(AnnotationSet)
}

// MARK: - AnnotationCommandResult

/// Result of applying a command, including the inverse command for undo.
struct AnnotationCommandResult {
    /// The inverse command that will undo this operation
    let inverse: AnnotationCommand

    /// Whether the command actually changed anything
    let didChange: Bool

    static let noChange = AnnotationCommandResult(inverse: .group([]), didChange: false)
}

// MARK: - Command Application

extension AnnotationSet {

    /// Apply an edit and capture its exact inverse. Swift value semantics keep
    /// unchanged layer arrays and mask data shared until they are mutated.
    @discardableResult
    mutating func apply(_ command: AnnotationCommand) -> AnnotationCommandResult {
        let previous = self
        switch command {
        case .addShape(let shape, let layerId):
            guard self.shape(id: shape.id) == nil else { return .noChange }
            if let layerId {
                addShape(shape, toLayerId: layerId)
            } else {
                addShape(shape)
            }

        case .removeShape(let shapeId):
            removeShape(id: shapeId)

        case .replaceShape(let shapeId, let newShape):
            guard newShape.id == shapeId else { return .noChange }
            replaceShape(id: shapeId, with: newShape)

        case .translateShape(let shapeId, let delta):
            translateShape(id: shapeId, delta: delta)

        case .resizeShape(let shapeId, let newRect):
            guard let oldShape = shape(id: shapeId) else { return .noChange }
            replaceShape(id: shapeId, with: oldShape.withBoundingRect(newRect))

        case .addLayer(let name, let id):
            guard !layers.contains(where: { $0.id == id }) else { return .noChange }
            layers.append(AnnotationLayer(id: id, name: name))
            activeLayerId = id

        case .removeLayer(let layerId):
            removeLayer(id: layerId)

        case .setActiveLayer(let layerId):
            guard layers.contains(where: { $0.id == layerId }) else { return .noChange }
            activeLayerId = layerId

        case .toggleLayerVisibility(let layerId):
            guard let index = layers.firstIndex(where: { $0.id == layerId }) else { return .noChange }
            layers[index].isVisible.toggle()

        case .setLayerOpacity(let layerId, let opacity):
            guard let index = editableLayerIndex(id: layerId), opacity.isFinite else { return .noChange }
            layers[index].opacity = min(1, max(0, opacity))

        case .setLayerBlendMode(let layerId, let blendMode):
            guard let index = editableLayerIndex(id: layerId) else { return .noChange }
            layers[index].blendMode = blendMode

        case .renameLayer(let layerId, let name):
            guard let index = layers.firstIndex(where: { $0.id == layerId }) else { return .noChange }
            layers[index].name = name

        case .moveLayer(let fromIndex, let toIndex):
            moveLayer(from: fromIndex, to: toIndex)

        case .setLayerLocked(let layerId, let locked):
            guard let index = layers.firstIndex(where: { $0.id == layerId }) else { return .noChange }
            layers[index].isLocked = locked

        case .soloLayer(let layerId):
            guard layers.contains(where: { $0.id == layerId }) else { return .noChange }
            for index in layers.indices {
                layers[index].isVisible = layers[index].id == layerId
            }

        case .unsoloLayers(let visibility):
            for index in layers.indices {
                if let isVisible = visibility[layers[index].id] {
                    layers[index].isVisible = isVisible
                }
            }

        case .duplicateLayer(let layerId, let newLayerId):
            guard let index = layers.firstIndex(where: { $0.id == layerId }),
                  !layers.contains(where: { $0.id == newLayerId }) else { return .noChange }
            var duplicate = layers[index]
            duplicate.id = newLayerId
            duplicate.name += " Copy"
            duplicate.shapes = duplicate.shapes.map { $0.duplicated(offset: 0) }
            layers.insert(duplicate, at: index + 1)

        case .mergeLayerDown(let layerId):
            guard let index = editableLayerIndex(id: layerId), index > 0,
                  !layers[index - 1].isLocked else { return .noChange }
            layers[index - 1].shapes.append(contentsOf: layers[index].shapes)
            if activeLayerId == layerId { activeLayerId = layers[index - 1].id }
            layers.remove(at: index)

        case .flattenLayers:
            guard layers.count > 1, !layers.contains(where: \.isLocked) else { return .noChange }
            let flattened = AnnotationLayer(name: "Flattened", shapes: shapes)
            layers = [flattened]
            activeLayerId = flattened.id

        case .mirrorAllHorizontally:
            mirrorAllHorizontally()

        case .mirrorAllVertically:
            mirrorAllVertically()

        case .setCropRegion(let region):
            cropRegion = region

        case .clearAll:
            guard !layers.contains(where: \.isLocked) else { return .noChange }
            self = .empty

        case .moveShapes(let shapeIds, let delta):
            for id in Set(shapeIds) { translateShape(id: id, delta: delta) }

        case .deleteShapes(let shapeIds):
            for id in Set(shapeIds) { removeShape(id: id) }

        case .duplicateShapes(let sourceIds, let newShapes):
            guard sourceIds.count == newShapes.count else { return .noChange }
            for (sourceId, shape) in zip(sourceIds, newShapes) {
                guard editableShapeLocation(id: sourceId) != nil, self.shape(id: shape.id) == nil else { continue }
                addShape(shape)
            }

        case .bringForward(let shapeId):
            guard let location = editableShapeLocation(id: shapeId),
                  location.shapeIndex < layers[location.layerIndex].shapes.count - 1 else { return .noChange }
            layers[location.layerIndex].shapes.swapAt(location.shapeIndex, location.shapeIndex + 1)

        case .sendBackward(let shapeId):
            guard let location = editableShapeLocation(id: shapeId), location.shapeIndex > 0 else { return .noChange }
            layers[location.layerIndex].shapes.swapAt(location.shapeIndex, location.shapeIndex - 1)

        case .bringToFront(let shapeId):
            guard let location = editableShapeLocation(id: shapeId) else { return .noChange }
            let shape = layers[location.layerIndex].shapes.remove(at: location.shapeIndex)
            layers[location.layerIndex].shapes.append(shape)

        case .sendToBack(let shapeId):
            guard let location = editableShapeLocation(id: shapeId) else { return .noChange }
            let shape = layers[location.layerIndex].shapes.remove(at: location.shapeIndex)
            layers[location.layerIndex].shapes.insert(shape, at: 0)

        case .setAdjustments(let adjustments):
            self.adjustments = adjustments

        case .group(let commands):
            for command in commands { apply(command) }

        case .restoreSnapshot(let snapshot):
            self = snapshot
        }
        guard self != previous else { return .noChange }
        return AnnotationCommandResult(inverse: .restoreSnapshot(previous), didChange: true)
    }

    private func editableLayerIndex(id: UUID) -> Int? {
        layers.firstIndex { $0.id == id && !$0.isLocked }
    }

    private func editableShapeLocation(id: UUID) -> (layerIndex: Int, shapeIndex: Int)? {
        guard let location = shapeLocation(id: id), !layers[location.layerIndex].isLocked else { return nil }
        return location
    }
}
