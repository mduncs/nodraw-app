import SwiftUI
import AppKit

/// Geometry adapters for existing shape cases; edit previews never mutate the session.
enum EditorShapeGeometry {
    static func symbol(_ shape: AnnotationShape) -> String {
        switch shape {
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .freeform: return "scribble"
        case .text: return "textformat"
        case .mask: return "circle.lefthalf.filled"
        case .extractedSubject: return "photo"
        }
    }

    static func bounds(of shape: AnnotationShape, imageSize: CGSize) -> NormalizedRect {
        switch shape {
        case .arrow(_, let from, let to, _):
            return pointBounds([from, to])
        case .freeform(_, let points, _):
            return pointBounds(points)
        case .text(_, let position, let content, let style):
            let size = AnnotationRenderer.textLayout(content: content, style: style).size
            return NormalizedRect(x: position.x, y: position.y,
                                  width: max(0.005, size.width / max(1, imageSize.width)),
                                  height: max(0.005, size.height / max(1, imageSize.height)))
        default:
            return shape.boundingRect
        }
    }

    static func union(_ rects: [NormalizedRect]) -> NormalizedRect? {
        guard let first = rects.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.x + first.width, maxY = first.y + first.height
        for rect in rects.dropFirst() {
            minX = min(minX, rect.x); minY = min(minY, rect.y)
            maxX = max(maxX, rect.x + rect.width); maxY = max(maxY, rect.y + rect.height)
        }
        return NormalizedRect(x: minX, y: minY, width: max(0.005, maxX - minX), height: max(0.005, maxY - minY))
    }

    static func moved(_ shape: AnnotationShape, by delta: NormalizedPoint) -> AnnotationShape {
        func point(_ p: NormalizedPoint) -> NormalizedPoint { NormalizedPoint(x: p.x + delta.x, y: p.y + delta.y) }
        func rect(_ r: NormalizedRect) -> NormalizedRect { NormalizedRect(x: r.x + delta.x, y: r.y + delta.y, width: r.width, height: r.height) }
        switch shape {
        case .rectangle(let id, let r, let style): return .rectangle(id: id, rect: rect(r), style: style)
        case .ellipse(let id, let r, let style): return .ellipse(id: id, rect: rect(r), style: style)
        case .arrow(let id, let from, let to, let style): return .arrow(id: id, from: point(from), to: point(to), style: style)
        case .freeform(let id, let points, let style): return .freeform(id: id, points: points.map(point), style: style)
        case .text(let id, let position, let content, let style): return .text(id: id, position: point(position), content: content, style: style)
        case .mask(let id, let data, let bounds, let blend, let opacity, let feather):
            return .mask(id: id, maskData: data, bounds: rect(bounds), blendMode: blend, opacity: opacity, featherRadius: feather)
        case .extractedSubject(let id, let key, let bounds, let opacity, var transform, let source):
            transform.offset = point(transform.offset)
            return .extractedSubject(id: id, assetKey: key, bounds: bounds, opacity: opacity, transform: transform, sourceSubjectId: source)
        }
    }

    /// Resize from a shared selection frame. This preserves relative placement for multi-selection.
    static func resized(_ shape: AnnotationShape, from original: NormalizedRect, to target: NormalizedRect) -> AnnotationShape {
        let sx = target.width / max(0.0001, original.width)
        let sy = target.height / max(0.0001, original.height)
        func point(_ p: NormalizedPoint) -> NormalizedPoint {
            NormalizedPoint(x: target.x + (p.x - original.x) * sx, y: target.y + (p.y - original.y) * sy)
        }
        func rect(_ r: NormalizedRect) -> NormalizedRect {
            let origin = point(NormalizedPoint(x: r.x, y: r.y))
            return NormalizedRect(x: origin.x, y: origin.y, width: r.width * sx, height: r.height * sy)
        }
        switch shape {
        case .rectangle(let id, let r, let style): return .rectangle(id: id, rect: rect(r), style: style)
        case .ellipse(let id, let r, let style): return .ellipse(id: id, rect: rect(r), style: style)
        case .arrow(let id, let from, let to, let style): return .arrow(id: id, from: point(from), to: point(to), style: style)
        case .freeform(let id, let points, let style): return .freeform(id: id, points: points.map(point), style: style)
        case .text(let id, let position, let content, var style):
            style.fontSize = max(4, min(1000, style.fontSize * min(sx, sy)))
            return .text(id: id, position: point(position), content: content, style: style)
        case .mask(let id, let data, let bounds, let blend, let opacity, let feather):
            return .mask(id: id, maskData: data, bounds: rect(bounds), blendMode: blend, opacity: opacity, featherRadius: feather)
        case .extractedSubject(let id, let key, _, let opacity, let transform, let source):
            let visible = rect(shape.boundingRect)
            let scale = max(0.0001, transform.scale)
            let resizedBounds = NormalizedRect(x: visible.x - transform.offset.x, y: visible.y - transform.offset.y,
                                               width: visible.width / scale, height: visible.height / scale)
            return .extractedSubject(id: id, assetKey: key, bounds: resizedBounds, opacity: opacity, transform: transform, sourceSubjectId: source)
        }
    }

    private static func pointBounds(_ points: [NormalizedPoint]) -> NormalizedRect {
        let minX = points.map(\.x).min() ?? 0, maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0, maxY = points.map(\.y).max() ?? 0
        return NormalizedRect(x: minX, y: minY, width: max(0.005, maxX - minX), height: max(0.005, maxY - minY))
    }
}

/// Eight native resize handles. The original frame is captured once; each completed drag is one undo step.
struct SelectionHandles: View {
    let rect: NormalizedRect
    let displaySize: CGSize
    var onBegin: () -> Void
    var onResize: (NormalizedRect) -> Void
    var onEnd: () -> Void
    @State private var initialRect: NormalizedRect?

    private struct Handle: Identifiable {
        let x: CGFloat
        let y: CGFloat
        var id: String { "\(x)-\(y)" }
    }
    private let handles = [Handle(x: 0, y: 0), Handle(x: 0.5, y: 0), Handle(x: 1, y: 0),
                           Handle(x: 0, y: 0.5), Handle(x: 1, y: 0.5),
                           Handle(x: 0, y: 1), Handle(x: 0.5, y: 1), Handle(x: 1, y: 1)]
    var body: some View {
        let frame = rect.scaled(to: displaySize)
        ZStack {
            Rectangle().stroke(Color.accentOrange, lineWidth: 1)
                .frame(width: max(1, frame.width), height: max(1, frame.height))
                .position(x: frame.midX, y: frame.midY)
                .allowsHitTesting(false)
            ForEach(handles) { handle in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(hex: 0x252525))
                    .overlay(RoundedRectangle(cornerRadius: 1.5).stroke(Color.accentOrange, lineWidth: 1.3))
                    .frame(width: 7, height: 7)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
                    .position(x: frame.minX + frame.width * handle.x, y: frame.minY + frame.height * handle.y)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("annotationCanvas"))
                        .onChanged { value in
                            if initialRect == nil { initialRect = rect; onBegin() }
                            guard let original = initialRect else { return }
                            onResize(resized(original, handle: handle, translation: value.translation))
                        }
                        .onEnded { _ in onEnd(); initialRect = nil })
                    .help("Resize · hold Shift to preserve proportions")
            }
        }
    }

    private func resized(_ original: NormalizedRect, handle: Handle, translation: CGSize) -> NormalizedRect {
        let dx = translation.width / max(1, displaySize.width), dy = translation.height / max(1, displaySize.height)
        var left = original.x, top = original.y
        var right = original.x + original.width, bottom = original.y + original.height
        if handle.x == 0 { left = min(right - 0.005, left + dx) }
        if handle.x == 1 { right = max(left + 0.005, right + dx) }
        if handle.y == 0 { top = min(bottom - 0.005, top + dy) }
        if handle.y == 1 { bottom = max(top + 0.005, bottom + dy) }
        if NSEvent.modifierFlags.contains(.shift), handle.x != 0.5, handle.y != 0.5 {
            let height = (right - left) * original.height / max(0.005, original.width)
            if handle.y == 0 { top = bottom - height } else { bottom = top + height }
        }
        return NormalizedRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
