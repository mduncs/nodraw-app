import AppKit
import Combine

/// Pure canvas geometry for the native editor. `scale` is display points per source pixel
/// (100% shows one source pixel per point); `origin` is the image's top-left in viewport points.
/// A fitted viewport follows window resizes until the person zooms or pans.
struct EditorViewport: Equatable {
    private(set) var imageSize: CGSize
    private(set) var viewportSize: CGSize
    private(set) var scale: CGFloat
    private(set) var origin: CGPoint
    private(set) var isFitted = true

    static let padding: CGFloat = 28
    /// SwiftUI canvases are sized to the displayed image, so bound the largest display extent.
    static let maximumDisplayDimension: CGFloat = 16_000
    static let zoomSteps: [CGFloat] = [0.05, 0.1, 0.125, 0.25, 1.0 / 3, 0.5, 2.0 / 3, 1, 1.5, 2, 3, 4, 6, 8, 12, 16]

    init(imageSize: CGSize, viewportSize: CGSize) {
        self.imageSize = CGSize(width: max(1, imageSize.width), height: max(1, imageSize.height))
        self.viewportSize = viewportSize
        self.scale = 1
        self.origin = .zero
        fit()
    }

    var displaySize: CGSize { CGSize(width: imageSize.width * scale, height: imageSize.height * scale) }
    var imageFrame: CGRect { CGRect(origin: origin, size: displaySize) }
    var zoomPercent: Int { Int((scale * 100).rounded()) }
    var viewportCenter: CGPoint { CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2) }

    /// Fit never enlarges a small image past 100%, matching the viewer's calm default.
    var fitScale: CGFloat {
        let width = max(1, viewportSize.width - Self.padding * 2)
        let height = max(1, viewportSize.height - Self.padding * 2)
        return min(1, width / imageSize.width, height / imageSize.height)
    }
    var minimumScale: CGFloat { max(0.005, min(fitScale, 1) * 0.25) }
    var maximumScale: CGFloat {
        max(fitScale, min(16, Self.maximumDisplayDimension / max(imageSize.width, imageSize.height)))
    }

    mutating func fit() {
        scale = fitScale
        isFitted = true
        clamp()
    }

    /// Zoom while keeping the image point under `anchor` (viewport points) stationary.
    mutating func zoom(to requested: CGFloat, anchor: CGPoint) {
        let target = min(maximumScale, max(minimumScale, requested))
        guard abs(target - scale) > 0.000_1 else { return }
        let ratio = target / scale
        origin = CGPoint(x: anchor.x - (anchor.x - origin.x) * ratio, y: anchor.y - (anchor.y - origin.y) * ratio)
        scale = target
        isFitted = false
        clamp()
    }

    mutating func zoom(by factor: CGFloat, anchor: CGPoint) {
        guard factor.isFinite, factor > 0 else { return }
        zoom(to: scale * factor, anchor: anchor)
    }

    mutating func stepZoom(in zoomIn: Bool, anchor: CGPoint? = nil) {
        let steps = Self.zoomSteps
        let next = zoomIn ? steps.first { $0 > scale * 1.001 } ?? maximumScale
            : steps.last { $0 < scale * 0.999 } ?? minimumScale
        zoom(to: next, anchor: anchor ?? viewportCenter)
    }

    /// A pan that the clamp fully absorbs (e.g. a fitted image) keeps following window resizes.
    mutating func pan(by delta: CGSize) {
        let previous = origin
        origin.x += delta.width
        origin.y += delta.height
        clamp()
        if origin != previous { isFitted = false }
    }

    /// Frame a normalized document rectangle, e.g. the current selection.
    mutating func zoom(toFit rect: NormalizedRect) {
        let width = max(1, rect.width * imageSize.width), height = max(1, rect.height * imageSize.height)
        let available = CGSize(width: max(1, viewportSize.width - Self.padding * 4),
                               height: max(1, viewportSize.height - Self.padding * 4))
        scale = min(maximumScale, max(minimumScale, min(available.width / width, available.height / height, 4)))
        let center = CGPoint(x: (rect.x + rect.width / 2) * imageSize.width * scale,
                             y: (rect.y + rect.height / 2) * imageSize.height * scale)
        origin = CGPoint(x: viewportCenter.x - center.x, y: viewportCenter.y - center.y)
        isFitted = false
        clamp()
    }

    /// Window/sidebar resizes keep the centered image point stable unless still fitted.
    mutating func resize(viewport size: CGSize) {
        guard size != viewportSize else { return }
        let focus = CGPoint(x: (viewportCenter.x - origin.x) / scale, y: (viewportCenter.y - origin.y) / scale)
        viewportSize = size
        if isFitted { fit(); return }
        origin = CGPoint(x: viewportCenter.x - focus.x * scale, y: viewportCenter.y - focus.y * scale)
        clamp()
    }

    mutating func replaceImageSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != imageSize else { return }
        imageSize = size
        fit()
    }

    func normalizedPoint(atViewport point: CGPoint) -> NormalizedPoint {
        NormalizedPoint(x: (point.x - origin.x) / max(0.0001, displaySize.width),
                        y: (point.y - origin.y) / max(0.0001, displaySize.height))
    }

    /// Small images stay centered; larger ones may pan until an edge meets the padded viewport edge.
    private mutating func clamp() {
        func axis(_ origin: CGFloat, display: CGFloat, viewport: CGFloat) -> CGFloat {
            if display <= viewport - Self.padding * 2 { return (viewport - display) / 2 }
            return min(Self.padding, max(viewport - Self.padding - display, origin))
        }
        let size = displaySize
        origin = CGPoint(x: axis(origin.x, display: size.width, viewport: viewportSize.width),
                         y: axis(origin.y, display: size.height, viewport: viewportSize.height))
    }
}

/// Shared by the canvas, zoom HUD and keyboard routing so every zoom command targets one viewport.
@MainActor
final class EditorViewportModel: ObservableObject {
    @Published private(set) var viewport: EditorViewport?
    /// Holding Space shows the hand cursor until release, focus loss or editor teardown.
    @Published var isSpacePanning = false {
        didSet {
            guard isSpacePanning != oldValue else { return }
            if isSpacePanning { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
    }

    func layout(imageSize: CGSize, viewportSize: CGSize) {
        guard imageSize.width > 0, imageSize.height > 0, viewportSize.width > 0, viewportSize.height > 0 else { return }
        if var current = viewport {
            current.replaceImageSize(imageSize)
            current.resize(viewport: viewportSize)
            if current != viewport { viewport = current }
        } else {
            viewport = EditorViewport(imageSize: imageSize, viewportSize: viewportSize)
        }
    }

    func update(_ change: (inout EditorViewport) -> Void) {
        guard var current = viewport else { return }
        change(&current)
        if current != viewport { viewport = current }
    }

    func zoomIn() { update { $0.stepZoom(in: true) } }
    func zoomOut() { update { $0.stepZoom(in: false) } }
    func fit() { update { $0.fit() } }
    func actualSize() { update { $0.zoom(to: 1, anchor: $0.viewportCenter) } }
    func zoom(toFit rect: NormalizedRect) { update { $0.zoom(toFit: rect) } }
}
