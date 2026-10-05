import CoreGraphics
import Foundation

/// Pure geometry for the hold-to-tag wheels.
///
/// The old wheel drew every tag in the tree at once, so a few hundred hierarchical
/// tags turned into slivers with no labels. This layout is bounded instead:
/// - **Sunburst** shows one level of the tree (the focus) in the inner ring, its
///   children in the outer ring, and a thin rim that marks deeper subtrees.
/// - **Radial** shows only the focus level, in one wide ring plus the rim.
///
/// Each ring has a minimum segment width (about one label line), so a ring can hold
/// only so many segments. Siblings that do not fit collapse into one "+N" segment.
/// Activating it pages to the next siblings (inner ring) or drills into that parent
/// (outer ring). Coordinates are relative to the wheel centre. Angles are degrees,
/// clockwise from 12 o'clock at -90 through to 270.
struct TagWheelLayout {
    enum Style: Equatable {
        case sunburst
        case radial
    }

    /// The tree level shown in the inner ring. `offset` skips siblings shown on earlier pages.
    struct Focus: Hashable {
        var parentID: UUID?
        var offset: Int = 0

        static let root = Focus(parentID: nil)
    }

    struct Ring: Equatable {
        let inner: CGFloat
        let outer: CGFloat

        var mid: CGFloat { (inner + outer) / 2 }
        var width: CGFloat { outer - inner }
    }

    struct Metrics: Equatable {
        let radius: CGFloat
        let hubRadius: CGFloat
        let rings: [Ring]
        let rim: Ring

        /// The narrowest a segment may be, measured across the middle of its ring.
        /// This is enough for one line of label text and for a reliable hover target.
        static let minSegmentThickness: CGFloat = 14
        /// No ring shows more than this many segments, however large the wheel is.
        static let maxSegmentsPerRing = 72

        init(style: Style, diameter: CGFloat) {
            let r = diameter / 2
            radius = r
            switch style {
            case .sunburst:
                hubRadius = r * 0.27
                rings = [Ring(inner: r * 0.28, outer: r * 0.585), Ring(inner: r * 0.595, outer: r * 0.90)]
            case .radial:
                hubRadius = r * 0.29
                rings = [Ring(inner: r * 0.30, outer: r * 0.90)]
            }
            rim = Ring(inner: r * 0.91, outer: r * 0.97)
        }

        func minDegrees(ring index: Int) -> Double {
            let ring = rings[index]
            let byThickness = Double(Self.minSegmentThickness / ring.mid) * 180 / .pi
            return max(byThickness, 360 / Double(Self.maxSegmentsPerRing))
        }

        /// How many segments fit in `span` degrees of the given ring.
        func capacity(ring index: Int, span: Double) -> Int {
            Int((span / minDegrees(ring: index)) + 1e-9)
        }
    }

    enum Kind: Equatable {
        case tag(TagDefinition)
        /// Siblings that did not fit. Activating the segment pushes `focus`.
        case more(count: Int, focus: Focus)
        /// Rim marker for a tag whose children are off screen. Activating it drills in.
        case drill(TagDefinition)
    }

    enum LabelOrientation: Equatable {
        /// Text runs along the ring (wide, short segments).
        case tangential
        /// Text runs outward along the radius (narrow segments).
        case radial
    }

    struct Label: Equatable {
        let text: String
        let orientation: LabelOrientation
        /// Label centre, relative to the wheel centre.
        let center: CGPoint
        /// Rotation that keeps the text upright (never upside down).
        let rotationDegrees: Double
        /// Room available along the text direction. Longer names truncate.
        let maxLength: CGFloat
        let fontSize: CGFloat
    }

    struct Segment: Identifiable, Equatable {
        let id: String
        let kind: Kind
        /// Index into `metrics.rings`; `metrics.rings.count` means the rim.
        let ring: Int
        let inner: CGFloat
        let outer: CGFloat
        let startDegrees: Double
        let endDegrees: Double
        let label: Label?

        var span: Double { endDegrees - startDegrees }
        var midDegrees: Double { (startDegrees + endDegrees) / 2 }

        var tag: TagDefinition? {
            switch kind {
            case .tag(let tag), .drill(let tag): return tag
            case .more: return nil
            }
        }
    }

    static let startDegrees: Double = -90

    let style: Style
    let focus: Focus
    let metrics: Metrics
    let segments: [Segment]

    /// - Parameters:
    ///   - focusParentName: name of the focused parent, used to shorten inner labels.
    ///   - children: ordered children of a parent (nil = root tags).
    init(style: Style, diameter: CGFloat, focus: Focus, focusParentName: String? = nil,
         children: (UUID?) -> [TagDefinition]) {
        self.focus = focus
        let level = Array(children(focus.parentID).dropFirst(max(0, focus.offset)))
        // A level with nothing below it has no second ring to fill; use the wide single ring.
        let style: Style = style == .sunburst && level.contains(where: { !children($0.id).isEmpty }) ? .sunburst : .radial
        self.style = style
        let metrics = Metrics(style: style, diameter: diameter)
        self.metrics = metrics

        guard !level.isEmpty else {
            segments = []
            return
        }

        var segments: [Segment] = []
        let innerRing = metrics.rings[0]

        // Inner ring: the focus level, paged when it does not fit.
        let capacity = metrics.capacity(ring: 0, span: 360)
        let shown: [TagDefinition]
        let overflow: Int
        if level.count > capacity {
            shown = Array(level.prefix(capacity - 1))
            overflow = level.count - shown.count
        } else {
            shown = level
            overflow = 0
        }

        // Angles: every segment gets the ring minimum. In a sunburst the rest is shared
        // by child count, so parents with many children get room for them outside.
        let childLists = shown.map { children($0.id) }
        var weights: [Double] = childLists.map { style == .sunburst ? Double($0.count) + 1 : 1 }
        if overflow > 0 { weights.append(1) }
        let minDegrees = metrics.minDegrees(ring: 0)
        let spare = max(0, 360 - minDegrees * Double(weights.count))
        let totalWeight = weights.reduce(0, +)
        let spans = weights.map { minDegrees + spare * $0 / totalWeight }

        var angle = Self.startDegrees
        for (index, tag) in shown.enumerated() {
            let start = angle
            let end = index == weights.count - 1 ? Self.startDegrees + 360 : angle + spans[index]
            angle = end
            segments.append(Self.segment(
                id: "0-\(tag.id.uuidString)", kind: .tag(tag), ring: 0, band: innerRing,
                start: start, end: end, text: Self.shortName(tag.name, under: focusParentName), fontSize: 11
            ))

            let childList = childLists[index]
            guard !childList.isEmpty else { continue }
            switch style {
            case .radial:
                segments.append(Self.rimSegment(for: tag, metrics: metrics, start: start, end: end))
            case .sunburst:
                segments.append(contentsOf: Self.childSegments(
                    of: tag, children: childList, start: start, end: end,
                    metrics: metrics, grandchildren: children
                ))
            }
        }

        if overflow > 0 {
            let nextFocus = Focus(parentID: focus.parentID, offset: max(0, focus.offset) + shown.count)
            segments.append(Self.segment(
                id: "more-0-\(focus.parentID?.uuidString ?? "root")-\(nextFocus.offset)",
                kind: .more(count: overflow, focus: nextFocus), ring: 0, band: innerRing,
                start: angle, end: Self.startDegrees + 360, text: "+\(overflow)", fontSize: 11
            ))
        }

        self.segments = segments
    }

    /// Outer sunburst ring for one inner segment, equal slices inside the parent's span.
    private static func childSegments(
        of parent: TagDefinition,
        children childList: [TagDefinition],
        start: Double,
        end: Double,
        metrics: Metrics,
        grandchildren: (UUID?) -> [TagDefinition]
    ) -> [Segment] {
        let band = metrics.rings[1]
        let capacity = metrics.capacity(ring: 1, span: end - start)
        let drillIntoParent = Focus(parentID: parent.id)

        guard capacity >= 2 || childList.count <= max(capacity, 1) else {
            // Not even two slices fit: one "+N" segment opens the parent.
            return [segment(
                id: "more-1-\(parent.id.uuidString)", kind: .more(count: childList.count, focus: drillIntoParent),
                ring: 1, band: band, start: start, end: end, text: "+\(childList.count)", fontSize: 10
            )]
        }

        let shown = childList.count > capacity ? Array(childList.prefix(capacity - 1)) : childList
        let overflow = childList.count - shown.count
        let slices = shown.count + (overflow > 0 ? 1 : 0)
        let step = (end - start) / Double(slices)

        var result: [Segment] = []
        for (index, child) in shown.enumerated() {
            let childStart = start + step * Double(index)
            let childEnd = index == slices - 1 ? end : childStart + step
            result.append(segment(
                id: "1-\(child.id.uuidString)", kind: .tag(child), ring: 1, band: band,
                start: childStart, end: childEnd, text: shortName(child.name, under: parent.name), fontSize: 10
            ))
            if !grandchildren(child.id).isEmpty {
                result.append(rimSegment(for: child, metrics: metrics, start: childStart, end: childEnd))
            }
        }
        if overflow > 0 {
            result.append(segment(
                id: "more-1-\(parent.id.uuidString)", kind: .more(count: overflow, focus: drillIntoParent),
                ring: 1, band: band, start: start + step * Double(shown.count), end: end,
                text: "+\(overflow)", fontSize: 10
            ))
        }
        return result
    }

    private static func rimSegment(for tag: TagDefinition, metrics: Metrics, start: Double, end: Double) -> Segment {
        Segment(
            id: "rim-\(tag.id.uuidString)", kind: .drill(tag), ring: metrics.rings.count,
            inner: metrics.rim.inner, outer: metrics.rim.outer,
            startDegrees: start, endDegrees: end, label: nil
        )
    }

    private static func segment(
        id: String, kind: Kind, ring: Int, band: Ring,
        start: Double, end: Double, text: String, fontSize: CGFloat
    ) -> Segment {
        Segment(
            id: id, kind: kind, ring: ring, inner: band.inner, outer: band.outer,
            startDegrees: start, endDegrees: end,
            label: label(text: text, inner: band.inner, outer: band.outer, start: start, end: end, fontSize: fontSize)
        )
    }

    // MARK: - Labels

    /// Label text for a tag drawn next to its parent: "music 1980s" under "music"
    /// reads "1980s". The hub and hover still show the full name.
    static func shortName(_ name: String, under parentName: String?) -> String {
        guard let parentName, !parentName.isEmpty,
              let range = name.range(of: parentName, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) else {
            return name
        }
        let rest = name[range.upperBound...].drop { " -_/:·›>".contains($0) }
        return rest.isEmpty || rest.count == name[range.upperBound...].count ? name : String(rest)
    }

    /// Shortest room worth drawing a label in; hovering still names the tag in the hub.
    static let minLabelLength: CGFloat = 18

    /// Fit a label inside a ring segment. It runs along the ring or outward along the
    /// radius, whichever leaves more room, and is dropped when neither can hold a line
    /// of text. Labels stay inside their own segment, so they cannot collide.
    static func label(text: String, inner: CGFloat, outer: CGFloat, start: Double, end: Double, fontSize: CGFloat) -> Label? {
        let mid = (start + end) / 2
        let midRadius = (inner + outer) / 2
        let arcLength = CGFloat((end - start) * .pi / 180) * midRadius
        let radialLength = outer - inner - 8
        let lineThickness = fontSize + 3

        // Along the ring the straight text also cuts across the curve, so keep it short.
        let tangentialLength = radialLength >= lineThickness ? min(arcLength - 8, midRadius * 1.1) : 0
        let radialRoom = arcLength >= lineThickness ? radialLength : 0
        let orientation: LabelOrientation = tangentialLength >= radialRoom ? .tangential : .radial
        let length = max(tangentialLength, radialRoom)
        guard length >= minLabelLength else { return nil }

        let radians = mid * .pi / 180
        let center = CGPoint(x: cos(radians) * midRadius, y: sin(radians) * midRadius)
        return Label(
            text: text,
            orientation: orientation,
            center: center,
            rotationDegrees: uprightRotation(midDegrees: mid, orientation: orientation),
            maxLength: length,
            fontSize: fontSize
        )
    }

    /// Rotation for text at `midDegrees`, flipped where it would read upside down.
    static func uprightRotation(midDegrees: Double, orientation: LabelOrientation) -> Double {
        var degrees = orientation == .tangential ? midDegrees + 90 : midDegrees
        degrees = normalizedSigned(degrees)
        if degrees > 90 || degrees < -90 {
            degrees = normalizedSigned(degrees + 180)
        }
        return degrees
    }

    private static func normalizedSigned(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value <= -180 { value += 360 }
        return value
    }

    // MARK: - Hit testing

    /// The segment under `point`, which is relative to the wheel centre.
    func segment(at point: CGPoint) -> Segment? {
        let distance = hypot(point.x, point.y)
        guard distance >= metrics.hubRadius, distance <= metrics.rim.outer else { return nil }
        var angle = atan2(Double(point.y), Double(point.x)) * 180 / .pi
        if angle < Self.startDegrees { angle += 360 }
        return segments.first { segment in
            distance >= segment.inner && distance <= segment.outer
                && angle >= segment.startDegrees && angle < segment.endDegrees
        }
    }

    func isInsideHub(_ point: CGPoint) -> Bool {
        hypot(point.x, point.y) < metrics.hubRadius
    }
}
