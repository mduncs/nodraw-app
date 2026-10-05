import AppKit
import Foundation

/// An invocation snapshot, not another browsing state owner. Every surface uses
/// this same ordered target/asset policy; execution resolves again before writing.
struct MediaActionContext {
    let items: [MediaItem]
    var displayedURLs: [UUID: URL] = [:]
    var displayedAssetIDs: [UUID: UUID] = [:]

    func resolve(_ source: MediaTransferSource = .displayed) throws -> MediaTransferPlan {
        try MediaTransferResolver.resolve(items: items, source: source,
            displayedURLs: displayedURLs, displayedAssetIDs: displayedAssetIDs)
    }

    var canCopyImage: Bool {
        guard let plan = try? resolve(), plan.files.count == 1, let file = plan.files.first else { return false }
        return Self.isImage(file.url)
    }

    func isEnabled(_ action: MediaFileAction, source: MediaTransferSource) -> Bool {
        guard let plan = try? resolve(source) else { return false }
        return action != .exportMetadata || plan.files.contains { Self.isMetadataExportable($0.url) }
    }

    /// Adapt the resolved source set to the existing EXIF/IPTC exporter. These
    /// are immutable export inputs, never installed into the browsing corpus.
    func exportItems(source: MediaTransferSource) throws -> [MediaItem] {
        let plan = try resolve(source)
        var seen = Set<UUID>()
        return items.compactMap { item in
            guard seen.insert(item.id).inserted else { return nil }
            var input = item
            input.mediaFiles = plan.files.filter { $0.itemID == item.id && Self.isMetadataExportable($0.url) }.map(\.url)
            return input.mediaFiles.isEmpty ? nil : input
        }
    }

    /// Item folders in target order, each once. Folders are item-level, so this does
    /// not go through the file transfer plan (and is not a `MediaFileAction` case,
    /// whose `allCases` feed the shared transfer menu and command registry).
    var folderPaths: [String] {
        var seen = Set<String>()
        return items.map(\.basePath.path).filter { seen.insert($0).inserted }
    }

    @MainActor
    func copyFolderPaths() {
        let paths = folderPaths
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string) else {
            MediaTransferFeedback.shared.report(CocoaError(.fileWriteUnknown))
            return
        }
    }

    static func isImage(_ url: URL) -> Bool {
        ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp"].contains(url.pathExtension.lowercased())
    }

    private static func isMetadataExportable(_ url: URL) -> Bool {
        // Keep the existing MetadataInjector input contract; BMP may be copied
        // as an image but must not advertise an export the engine skips.
        isImage(url) && url.pathExtension.lowercased() != "bmp"
    }
}

enum MediaFileAction: String, CaseIterable {
    case copyFiles, copyPaths, reveal, exportMetadata
    var title: String {
        switch self {
        case .copyFiles: "Copy Files"
        case .copyPaths: "Copy File Paths"
        case .reveal: "Reveal in Finder"
        case .exportMetadata: "Export with Metadata…"
        }
    }

    @MainActor
    func perform(context: MediaActionContext, source: MediaTransferSource = .displayed, appState: AppState) {
        do {
            let plan = try context.resolve(source)
            switch self {
            case .copyFiles:
                let writers = try MediaFilePasteboardWriter.writers(for: plan)
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.writeObjects(writers) else { throw CocoaError(.fileWriteUnknown) }
            case .copyPaths:
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(plan.files.map { $0.url.path }.joined(separator: "\n"), forType: .string) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            case .reveal:
                NSWorkspace.shared.activateFileViewerSelecting(plan.files.map(\.url))
            case .exportMetadata:
                guard try !context.exportItems(source: source).isEmpty else { throw MediaTransferError.empty }
                appState.mediaExportRequest = MediaExportRequest(context: context, source: source)
            }
        } catch { MediaTransferFeedback.shared.report(error) }
    }
}

struct MediaExportRequest: Identifiable {
    let id = UUID()
    let context: MediaActionContext
    let source: MediaTransferSource
}

@MainActor
extension AppState {
    var mediaActionContext: MediaActionContext {
        if let focusedItem {
            return MediaActionContext(items: [focusedItem],
                displayedURLs: mediaSelectionStore.activeDetailURL.map { [focusedItem.id: $0] } ?? [:],
                displayedAssetIDs: mediaSelectionStore.activeDetailAssetID.map { [focusedItem.id: $0] } ?? [:])
        }
        return MediaActionContext(items: orderedSelectedItemIDs.compactMap { mediaSelectionStore.item(for: $0) })
    }

    func copyDisplayedImage() {
        let context = mediaActionContext
        guard context.canCopyImage else { return }
        // Focus owns annotation/subject composition; keep its existing renderer.
        if focusedItem != nil {
            NotificationCenter.default.post(name: .copyImageToClipboard, object: nil)
            return
        }
        do {
            guard let url = try context.resolve().files.first?.url,
                  let image = NSImage(contentsOf: url) else { throw MediaTransferError.empty }
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.writeObjects([image]) else { throw CocoaError(.fileWriteUnknown) }
        } catch { MediaTransferFeedback.shared.report(error) }
    }
}
