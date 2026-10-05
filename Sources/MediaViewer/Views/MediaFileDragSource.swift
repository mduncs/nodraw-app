import SwiftUI
import AppKit

/// One pasteboard item per real file. Every item carries the app marker so a
/// file companion remains an internal drag when a drop target filters providers.
final class MediaFilePasteboardWriter: NSObject, NSPasteboardWriting {
    let url: URL
    let internalData: Data

    convenience init(url: URL, itemIDs: [UUID]) throws {
        self.init(url: url, internalData: try JSONEncoder().encode(MediaItemDragData(itemIds: itemIDs)))
    }

    private init(url: URL, internalData: Data) {
        self.url = url
        self.internalData = internalData
    }

    static func writers(for plan: MediaTransferPlan) throws -> [MediaFilePasteboardWriter] {
        let data = try JSONEncoder().encode(MediaItemDragData(itemIds: plan.itemIDs))
        return plan.files.map { MediaFilePasteboardWriter(url: $0.url, internalData: data) }
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.fileURL] + kSupportedMediaItemTypeIdentifiers.map { NSPasteboard.PasteboardType($0) }
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .fileURL { return url.absoluteString }
        if kSupportedMediaItemTypeIdentifiers.contains(type.rawValue) { return internalData }
        return nil
    }
}

struct MediaDragGestureCapture {
    private var start: NSPoint?
    private var plan: Result<MediaTransferPlan, Error>?
    mutating func mouseDown(at point: NSPoint, resolve: () throws -> MediaTransferPlan) {
        start = point
        plan = Result(catching: resolve)
    }
    mutating func cancel() { start = nil; plan = nil }
    mutating func takePlan(at point: NSPoint) -> Result<MediaTransferPlan, Error>? {
        guard let start, hypot(point.x - start.x, point.y - start.y) >= 5 else { return nil }
        let captured = plan
        cancel()
        return captured
    }
}

struct MediaFileDragSource: NSViewRepresentable {
    #if DEBUG
    // The combined router owns the monitor, including drag-only anchors.
    static var eventMonitorCount: Int { 0 }
    #endif
    var enabled: () -> Bool = { true }
    let plan: () throws -> MediaTransferPlan
    let onFailure: (Error) -> Void
    var onRightClick: ((CGPoint) -> Void)? = nil

    func makeNSView(context: Context) -> DragView { DragView(onRightClick: onRightClick) }
    func updateNSView(_ view: DragView, context: Context) {
        view.isDragEnabled = enabled
        view.resolve = plan
        view.onFailure = onFailure
        view.onRightClick = onRightClick
    }

    class DragView: RightClickView, NSDraggingSource {
        var isDragEnabled: () -> Bool = { true }
        var resolve: (() throws -> MediaTransferPlan)?
        var onFailure: ((Error) -> Void)?
        private var capture = MediaDragGestureCapture()
        private var writers: [MediaFilePasteboardWriter] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            capture.cancel()
            super.viewDidMoveToWindow()
        }

        func captureMouseDown(_ event: NSEvent) {
            capture.cancel()
            let point = convert(event.locationInWindow, from: nil)
            // Capture before the native row/cell changes selection. A
            // click stays silent; resolution errors surface only on drag.
            capture.mouseDown(at: point) {
                guard let resolve else { throw MediaTransferError.empty }
                return try resolve()
            }
        }

        func cancelDragCapture() { capture.cancel() }

        func routeDrag(_ event: NSEvent) -> NSEvent? {
            let point = convert(event.locationInWindow, from: nil)
            guard let captured = capture.takePlan(at: point) else { return event }
            do {
                let plan = try captured.get()
                try begin(plan, event: event, point: point)
            } catch {
                onFailure?(error)
            }
            return nil
        }

        func begin(_ plan: MediaTransferPlan, event: NSEvent, point: NSPoint) throws {
            guard !plan.files.isEmpty else { throw MediaTransferError.empty }
            // Revalidate at invocation: a context-menu plan may outlive a moved file.
            for file in plan.files {
                guard FileManager.default.isReadableFile(atPath: file.url.path) else {
                    throw MediaTransferError.missing(file.url)
                }
            }
            writers = try MediaFilePasteboardWriter.writers(for: plan)
            let items = zip(plan.files, writers).enumerated().map { index, pair in
                let item = NSDraggingItem(pasteboardWriter: pair.1)
                let icon = NSWorkspace.shared.icon(forFile: pair.0.url.path)
                let offset = CGFloat(min(index, 4)) * 3
                item.setDraggingFrame(NSRect(x: point.x + offset, y: point.y - offset, width: 48, height: 48), contents: icon)
                return item
            }
            let session = beginDraggingSession(with: items, event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
            session.draggingFormation = .pile
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            writers = []
            capture.cancel()
        }
        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    }
}

extension View {
    func mediaFileDrag(enabled: @escaping () -> Bool = { true }, onRightClick: ((CGPoint) -> Void)? = nil, plan: @escaping () throws -> MediaTransferPlan) -> some View {
        overlay(MediaFileDragSource(enabled: enabled, plan: plan,
            onFailure: { MediaTransferFeedback.shared.report($0) }, onRightClick: onRightClick))
    }
}
