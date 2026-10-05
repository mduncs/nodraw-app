import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable

// MARK: - Tag drag type

/// Canonical drag type identifier for moving a tag within the hierarchy.
/// Distinct from `kNoDrawItemTypeIdentifier` (media items) so tag-on-tag drops
/// (reparent / reorder) can be told apart from media-on-tag drops (apply tag).
let kNoDrawTagTypeIdentifier = "com.nodraw.tag"

extension UTType {
    /// Custom UTType for dragging a tag row within the tag tree.
    static let nodrawTag = UTType(exportedAs: kNoDrawTagTypeIdentifier)
}

/// Payload carried when a tag row is dragged.
struct TagDragData: Codable, Transferable {
    let tagId: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .nodrawTag)
    }
}

/// Build an NSItemProvider for dragging a tag. Uses the raw identifier and
/// `.ownProcess` visibility -- this is an intra-app reorganization gesture, not
/// something other apps should receive.
func makeTagDragProvider(tagId: UUID) -> NSItemProvider {
    let provider = NSItemProvider()
    let data = (try? JSONEncoder().encode(TagDragData(tagId: tagId))) ?? Data()
    provider.registerDataRepresentation(
        forTypeIdentifier: kNoDrawTagTypeIdentifier,
        visibility: .ownProcess
    ) { completion in
        completion(data, nil)
        return nil
    }
    return provider
}

/// Load a dragged tag id from a provider, if present.
func loadTagDragData(from provider: NSItemProvider, completion: @escaping (UUID?) -> Void) {
    guard provider.hasItemConformingToTypeIdentifier(kNoDrawTagTypeIdentifier) else {
        completion(nil)
        return
    }
    _ = provider.loadDataRepresentation(forTypeIdentifier: kNoDrawTagTypeIdentifier) { data, _ in
        if let data, let decoded = try? JSONDecoder().decode(TagDragData.self, from: data) {
            completion(decoded.tagId)
        } else {
            completion(nil)
        }
    }
}

// MARK: - Drop zones

/// Where within a row a tag drop landed.
/// `.into` nests the dragged tag under the row (reparent); `.before`/`.after`
/// reorder it as a sibling of the row.
enum TagDropZone: Equatable {
    case before
    case into
    case after
}

/// Which row + zone is currently showing a drop affordance.
struct TagDropIndicator: Equatable {
    let tagId: UUID
    let zone: TagDropZone
}

extension View {
    /// Make a row draggable as a tag only when it has a real tag id
    /// (the synthetic "untagged" row passes nil and stays non-draggable).
    @ViewBuilder
    func draggableTag(_ tagId: UUID?) -> some View {
        if let tagId {
            self.onDrag { makeTagDragProvider(tagId: tagId) }
        } else {
            self
        }
    }
}

// MARK: - Row height preference (for zone thresholds)

/// Collects per-row heights so a drop delegate can map pointer-Y to a zone.
struct TagRowHeightPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] { [:] }
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// MARK: - Drop delegate

/// Drop delegate for a single sidebar tag row. Handles two payload kinds:
/// - `.nodrawTag`  -> reorder / reparent the dragged tag (drives `indicator`)
/// - media items   -> existing "apply this tag to the dropped items" behavior
struct TagRowDropDelegate: DropDelegate {
    /// The row's tag id. `nil` for the synthetic "untagged" row, which accepts
    /// media drops but is never a tag-move target and is not draggable.
    let rowTagId: UUID?
    let rowName: String
    let rowHeight: CGFloat

    @Binding var indicator: TagDropIndicator?
    @Binding var mediaDropTargetTag: String?

    let isCollapsedParent: (UUID) -> Bool
    let onSpringLoadHover: (UUID?) -> Void
    let performTagMove: (_ movedId: UUID, _ targetRowId: UUID, _ zone: TagDropZone) -> Void
    let performMediaDrop: (_ providers: [NSItemProvider], _ tag: String) -> Void

    private func zone(for info: DropInfo) -> TagDropZone {
        guard rowTagId != nil, rowHeight > 0 else { return .into }
        let y = info.location.y
        if y < rowHeight * 0.30 { return .before }
        if y > rowHeight * 0.70 { return .after }
        return .into
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.nodrawTag])
            || info.hasItemsConforming(to: [.mediaViewerItem, .data])
    }

    func dropEntered(info: DropInfo) {
        _ = dropUpdated(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if info.hasItemsConforming(to: [.nodrawTag]) {
            if let id = rowTagId {
                let z = zone(for: info)
                let next = TagDropIndicator(tagId: id, zone: z)
                if indicator != next { indicator = next }
                onSpringLoadHover(z == .into && isCollapsedParent(id) ? id : nil)
            }
            return DropProposal(operation: .move)
        }
        // Media drop -> highlight the row as a tag target.
        if let _ = rowTagId { mediaDropTargetTag = rowName }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        if let id = rowTagId, indicator?.tagId == id { indicator = nil }
        onSpringLoadHover(nil)
        if mediaDropTargetTag == rowName { mediaDropTargetTag = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        onSpringLoadHover(nil)
        let clear = {
            if let id = rowTagId, indicator?.tagId == id { indicator = nil }
            if mediaDropTargetTag == rowName { mediaDropTargetTag = nil }
        }

        // Tag move takes priority.
        if let provider = info.itemProviders(for: [.nodrawTag]).first, let targetId = rowTagId {
            let z = zone(for: info)
            loadTagDragData(from: provider) { movedId in
                guard let movedId else { return }
                Task { @MainActor in
                    performTagMove(movedId, targetId, z)
                }
            }
            clear()
            return true
        }

        // Otherwise, media drop -> apply the tag.
        let providers = info.itemProviders(for: [.mediaViewerItem, .data])
        if !providers.isEmpty {
            performMediaDrop(providers, rowName)
            clear()
            return true
        }

        clear()
        return false
    }
}
