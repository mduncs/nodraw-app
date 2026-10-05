import Foundation

enum MediaTransferSource: String, CaseIterable, Identifiable {
    case displayed, downloaded, context
    var id: Self { self }
    var label: String {
        switch self {
        case .displayed: "Displayed"
        case .downloaded: "Downloaded originals"
        case .context: "Context image"
        }
    }
}

struct MediaTransferPlan {
    struct File: Equatable {
        let itemID: UUID
        let url: URL
        var assetID: UUID? = nil
    }
    let itemIDs: [UUID]
    let source: MediaTransferSource
    let files: [File]
}

enum MediaTransferError: LocalizedError {
    case unavailable(String, MediaTransferSource)
    case missing(URL)
    case invalidDisplayedAsset(URL)
    case empty
    case malformedProvider(Int)

    var errorDescription: String? {
        switch self {
        case .unavailable(let name, let source): "\(name) has no \(source.label.lowercased())."
        case .missing(let url): "Cannot transfer \(url.lastPathComponent): the file is missing or unreadable."
        case .invalidDisplayedAsset: "The displayed file no longer belongs to this item. Refresh the item and try again."
        case .empty: "Select an item with a local media file."
        case .malformedProvider(let position): "Drop item \(position) could not be read. Nothing was added; try dragging again."
        }
    }
}

/// Resolves the full immutable operation before any pasteboard or destination
/// mutation. Missing members fail the whole plan; metadata is never a fallback
/// for missing media. Real source URLs require no partial temporary directory.
enum MediaTransferResolver {
    static func orderedTargets(items: [MediaItem], selected: Set<UUID>, clicked: MediaItem) -> [MediaItem] {
        guard selected.contains(clicked.id) else { return [clicked] }
        return items.filter { selected.contains($0.id) }
    }

    static func resolve(
        items: [MediaItem], source: MediaTransferSource = .displayed,
        displayedURLs: [UUID: URL] = [:],
        displayedAssetIDs: [UUID: UUID] = [:],
        isReadable: (URL) -> Bool = { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
            return url.isFileURL && values?.isRegularFile == true && values?.isReadable == true
        }
    ) throws -> MediaTransferPlan {
        guard !items.isEmpty else { throw MediaTransferError.empty }
        var seenItems = Set<UUID>()
        var seenPaths = Set<String>()
        var ids: [UUID] = []
        var files: [MediaTransferPlan.File] = []
        for item in items where seenItems.insert(item.id).inserted {
            ids.append(item.id)
            let assets = item.assets.sorted { $0.order == $1.order ? $0.assetID.uuidString < $1.assetID.uuidString : $0.order < $1.order }
            let urls: [URL]
            switch source {
            case .displayed:
                if let id = displayedAssetIDs[item.id] {
                    guard let asset = assets.first(where: { $0.assetID == id }) else {
                        throw ItemAssetStore.AssociationError.staleAsset
                    }
                    urls = [asset.url]
                } else if let active = displayedURLs[item.id] {
                    let members = assets.isEmpty ? item.mediaFiles + (item.contextImage.map { [$0] } ?? []) : assets.map(\.url)
                    guard members.contains(where: { canonicalPath($0) == canonicalPath(active) }) else {
                        throw MediaTransferError.invalidDisplayedAsset(active)
                    }
                    urls = [active]
                } else {
                    urls = item.preferredDisplaySource.map { [$0] } ?? []
                }
            case .downloaded: urls = assets.isEmpty ? item.mediaFiles : assets.filter { $0.role == .media }.map(\.url)
            case .context: urls = assets.isEmpty ? item.contextImage.map { [$0] } ?? [] : assets.filter { $0.role == .context }.map(\.url)
            }
            guard !urls.isEmpty else {
                throw MediaTransferError.unavailable(item.metadataFile.deletingPathExtension().lastPathComponent, source)
            }
            for url in urls.map(\.standardizedFileURL) {
                let matching = assets.filter { canonicalPath($0.url) == canonicalPath(url) }
                if !assets.isEmpty {
                    guard !matching.isEmpty else { throw MediaTransferError.invalidDisplayedAsset(url) }
                    guard !matching.contains(where: { $0.availability == "ambiguous" }) else {
                        throw ItemAssetStore.AssociationError.ambiguousAsset
                    }
                }
                guard isReadable(url) else { throw MediaTransferError.missing(url) }
                if seenPaths.insert(canonicalPath(url)).inserted {
                    let identity = source == .displayed ? displayedAssetIDs[item.id] ?? matching.first?.assetID : matching.first?.assetID
                    files.append(.init(itemID: item.id, url: url, assetID: identity))
                }
            }
        }
        return MediaTransferPlan(itemIDs: ids, source: source, files: files)
    }

    private static func canonicalPath(_ url: URL) -> String {
        ItemAssetStore.canonicalPath(url.path)
    }
}
