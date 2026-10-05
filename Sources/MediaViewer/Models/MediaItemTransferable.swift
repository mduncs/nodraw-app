import Foundation
import UniformTypeIdentifiers
import CoreTransferable

// MARK: - Custom UTType for NoDraw Items

/// Canonical drag type identifier for NoDraw items.
let kNoDrawItemTypeIdentifier = "com.nodraw.item"

/// Legacy drag type identifier used by older MediaViewer builds.
let kLegacyMediaViewerItemTypeIdentifier = "com.mediaviewer.item"

/// Preferred runtime identifier used throughout the app.
/// Kept on the old symbol name to avoid a broad rename through the codebase.
let kMediaViewerItemTypeIdentifier = kNoDrawItemTypeIdentifier

/// All supported drag type identifiers, ordered by preference.
let kSupportedMediaItemTypeIdentifiers = [
    kMediaViewerItemTypeIdentifier,
    kLegacyMediaViewerItemTypeIdentifier
]

extension UTType {
    /// Custom UTType for dragging media items within the app.
    /// Note: Use kMediaViewerItemTypeIdentifier for runtime checks as this
    /// dynamic type may not resolve correctly in all build configurations.
    static let mediaViewerItem = UTType(exportedAs: kNoDrawItemTypeIdentifier)
}

// MARK: - Drag Data

/// Data transferred during drag operations.
/// Contains item IDs that can be resolved to full MediaItems on drop.
struct MediaItemDragData: Codable, Transferable, Equatable {
    /// IDs of items being dragged
    let itemIds: [UUID]

    /// Single-item convenience initializer
    init(itemId: UUID) {
        self.itemIds = [itemId]
    }

    /// Multi-item initializer
    init(itemIds: [UUID]) {
        self.itemIds = itemIds
    }

    // MARK: - Transferable

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .mediaViewerItem)
    }
}

// MARK: - NSItemProvider Support for onDrag

/// Helper class to bridge MediaItemDragData to NSItemProvider for .onDrag()
/// This is needed because NSItemProvider requires NSItemProviderWriting conformance.
///
/// IMPORTANT: Uses kMediaViewerItemTypeIdentifier (raw string) instead of
/// UTType.mediaViewerItem.identifier to avoid issues with exported types
/// not being recognized at runtime.
final class MediaItemDragProvider: NSObject, NSItemProviderWriting {
    let dragData: MediaItemDragData

    init(dragData: MediaItemDragData) {
        self.dragData = dragData
    }

    // MARK: - NSItemProviderWriting

    static var writableTypeIdentifiersForItemProvider: [String] {
        // Use raw string identifier for reliable type matching
        // Also register as public.data for fallback compatibility
        kSupportedMediaItemTypeIdentifiers + [UTType.data.identifier]
    }

    func loadData(
        withTypeIdentifier typeIdentifier: String,
        forItemProviderCompletionHandler completionHandler: @escaping (Data?, Error?) -> Void
    ) -> Progress? {
        let progress = Progress(totalUnitCount: 1)

        logInfo("DRAG-PROVIDER: loadData called with typeIdentifier: \(typeIdentifier)")

        do {
            let data = try JSONEncoder().encode(dragData)
            progress.completedUnitCount = 1
            logInfo("DRAG-PROVIDER: Encoded \(dragData.itemIds.count) items (\(data.count) bytes)")
            completionHandler(data, nil)
        } catch {
            logInfo("DRAG-PROVIDER: Encode error: \(error)")
            completionHandler(nil, error)
        }

        return progress
    }
}

// MARK: - Drop Handler Helpers

enum MediaDropClassification {
    static func externalFileProviders(in providers: [NSItemProvider]) -> [NSItemProvider] {
        // File companions belong to the same internal drag, not new imports.
        guard !providers.contains(where: { provider in
            kSupportedMediaItemTypeIdentifiers.contains {
                provider.registeredTypeIdentifiers.contains($0) || provider.hasItemConformingToTypeIdentifier($0)
            }
        }) else { return [] }
        return providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    }
}

/// Attempts to load MediaItemDragData from an NSItemProvider.
/// Tries multiple type identifiers for compatibility.
func loadMediaItemDragData(
    from provider: NSItemProvider,
    completion: @escaping (MediaItemDragData?) -> Void
) {
    logInfo("DROP-HELPER: Provider types: \(provider.registeredTypeIdentifiers)")

    // Try our custom types first, preferring the current identifier.
    for typeIdentifier in kSupportedMediaItemTypeIdentifiers where provider.hasItemConformingToTypeIdentifier(typeIdentifier) {
        logInfo("DROP-HELPER: Has custom type '\(typeIdentifier)', loading...")
        _ = provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
            if let data = data, let dragData = try? JSONDecoder().decode(MediaItemDragData.self, from: data) {
                logInfo("DROP-HELPER: Decoded \(dragData.itemIds.count) items from custom type '\(typeIdentifier)'")
                completion(dragData)
            } else {
                logInfo("DROP-HELPER: Custom type '\(typeIdentifier)' decode failed: \(error?.localizedDescription ?? "nil data")")
                completion(nil)
            }
        }
        return
    }

    // Fallback to public.data
    if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
        logInfo("DROP-HELPER: Falling back to public.data...")
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.data.identifier) { data, error in
            if let data = data, let dragData = try? JSONDecoder().decode(MediaItemDragData.self, from: data) {
                logInfo("DROP-HELPER: Decoded \(dragData.itemIds.count) items from public.data")
                completion(dragData)
            } else {
                logInfo("DROP-HELPER: public.data decode failed: \(error?.localizedDescription ?? "nil data")")
                completion(nil)
            }
        }
        return
    }

    logInfo("DROP-HELPER: No compatible type found")
    completion(nil)
}

// MARK: - Drag Provider Factory

/// Decode every internal provider in order before applying any mutation. File
/// providers that accompany internal payloads are representations, not
/// additional archives. Malformed internal data fails the complete drop.
@discardableResult
func loadMediaItemDragData(
    from providers: [NSItemProvider],
    completion: @escaping (MediaItemDragData?) -> Void
) -> Task<Void, Never> {
    let internalProviders = providers.filter { provider in
        kSupportedMediaItemTypeIdentifiers.contains { provider.hasItemConformingToTypeIdentifier($0) }
        || (provider.hasItemConformingToTypeIdentifier(UTType.data.identifier)
            && !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
    }
    return Task { @MainActor in
        var ids: [UUID] = []
        var seen = Set<UUID>()
        for (index, provider) in internalProviders.enumerated() {
            let value: MediaItemDragData
            do {
                try Task.checkCancellation()
                value = try await CancellableMediaProviderLoad.load(provider)
                try Task.checkCancellation()
            } catch is CancellationError {
                completion(nil)
                return
            } catch {
                MediaTransferFeedback.shared.report(MediaTransferError.malformedProvider(index + 1))
                completion(nil)
                return
            }
            guard !value.itemIds.isEmpty else {
                MediaTransferFeedback.shared.report(MediaTransferError.malformedProvider(index + 1))
                completion(nil)
                return
            }
            for id in value.itemIds where seen.insert(id).inserted { ids.append(id) }
        }
        guard !ids.isEmpty else {
            MediaTransferFeedback.shared.report(MediaTransferError.empty)
            completion(nil)
            return
        }
        completion(MediaItemDragData(itemIds: ids))
    }
}

/// NSItemProvider callbacks can arrive after cancellation (or not arrive at
/// all). Resume exactly once and cancel its Progress without waiting for them.
private final class CancellableMediaProviderLoad: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MediaItemDragData, Error>?
    private var progress: Progress?
    private var cancelled = false
    private var finished = false

    static func load(_ provider: NSItemProvider) async throws -> MediaItemDragData {
        let state = CancellableMediaProviderLoad()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.start(provider, continuation: continuation)
            }
        } onCancel: { state.cancel() }
    }

    private func start(_ provider: NSItemProvider, continuation: CheckedContinuation<MediaItemDragData, Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
        let type = kSupportedMediaItemTypeIdentifiers.first { provider.hasItemConformingToTypeIdentifier($0) } ?? UTType.data.identifier
        let progress = provider.loadDataRepresentation(forTypeIdentifier: type) { [self] data, error in
            let result: Result<MediaItemDragData, Error> = Result {
                if let error { throw error }
                guard let data else { throw MediaTransferError.empty }
                return try JSONDecoder().decode(MediaItemDragData.self, from: data)
            }
            finish(result)
        }
        lock.lock()
        let cancelProgress = cancelled
        if !finished { self.progress = progress }
        lock.unlock()
        if cancelProgress { progress.cancel() }
    }

    private func finish(_ result: Result<MediaItemDragData, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        progress = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let progress = self.progress
        lock.unlock()
        finish(.failure(CancellationError()))
        progress?.cancel()
    }
}

/// Build a drag item provider that supports:
/// - Internal app drops via `MediaItemDragData`
/// - External drops (Finder/Desktop/apps) via file URLs when available
func makeMediaItemDragItemProviders(
    dragData: MediaItemDragData,
    externalFileURLs: [URL]
) throws -> [NSItemProvider] {
    guard !externalFileURLs.isEmpty else { throw MediaTransferError.empty }
    for url in externalFileURLs {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
        guard url.isFileURL, values?.isRegularFile == true, values?.isReadable == true else {
            throw MediaTransferError.missing(url)
        }
    }
    let data = try JSONEncoder().encode(dragData)
    return externalFileURLs.map { url in
        let provider = NSItemProvider(object: url as NSURL)
        for typeIdentifier in kSupportedMediaItemTypeIdentifiers {
            provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
        }
        return provider
    }
}
