import AppKit
import QuartzCore

/// Native, aspect-fit subject preview with optional hover, selection, lift and drag interaction.
///
/// All view-space points use AppKit's unflipped, bottom-left coordinate convention, matching
/// the normalized Vision contours. Interaction is opt-in; existing highlight-only consumers
/// retain control of `highlightedSubjects` and still receive `onSubjectTapped`.
///
/// Enable `isSubjectInteractionEnabled`, observe `onSelectionChanged`, and handle
/// `onSubjectLiftRequested` to insert/extract the selected instance IDs in the host editor.
/// Hover previews never change the committed selection. Shift/Command-click toggles subjects.
public final class SubjectHighlightView: NSView, NSDraggingSource {
    /// The source image to display.
    public var image: NSImage? {
        didSet {
            guard image !== oldValue else { return }
            lastContentRect = .null
            imageLayer.contents = image
            highlightLayer.contents = image
            needsLayout = true
        }
    }

    /// Reassigning the same immutable result snapshot does not restart glow or clear selection.
    /// A different result clears selection because Vision instance IDs are local to each result.
    public var isolationResult: IsolationResult? {
        didSet {
            guard !Self.sameSnapshot(oldValue, isolationResult) else { return }
            lastContentRect = .null
            hitTestMasks.removeAll()
            hoveredSubjectIndex = nil
            dragStartPoint = nil
            deferredSelectionPoint = nil
            let hadSelection = !highlightedSubjects.isEmpty
            setHighlightedSubjects([], animated: false)
            updateHighlight(animated: false)
            if hadSelection { onSelectionChanged?([]) }
            needsLayout = true
        }
    }

    /// Committed subject IDs (Vision IDs are 1-based). Invalid IDs never render or export.
    /// This original property remains available for highlight-only integrations.
    public var highlightedSubjects: IndexSet = [] {
        didSet {
            guard highlightedSubjects != oldValue else { return }
            updateHighlight(animated: highlightedSubjectsAnimationEnabled)
        }
    }

    /// Alias for the committed selection, distinct from the transient hover preview.
    /// Programmatic assignment does not emit `onSelectionChanged`.
    public var selectedSubjects: IndexSet {
        get { highlightedSubjects }
        set { highlightedSubjects = newValue }
    }

    /// Hide only the base image when overlaying this view on a host's composited preview.
    /// The masked subject image remains available for native hover/lift previews.
    public var showsSourceImage = true {
        didSet { imageLayer.isHidden = !showsSourceImage }
    }

    /// Opt in to built-in hover and click selection. Default false preserves legacy behavior.
    public var isSubjectInteractionEnabled = false {
        didSet {
            guard isSubjectInteractionEnabled != oldValue else { return }
            if !isSubjectInteractionEnabled {
                previewSubject(at: nil)
                dragStartPoint = nil
                deferredSelectionPoint = nil
            }
            updateTrackingAreas()
        }
    }
    public var allowsMultipleSelection = true
    /// Separately opt in to native cutout dragging. No files or global clipboard are used.
    public var allowsSubjectDragging = false
    public private(set) var hoveredSubjectIndex: Int?
    public var dimmingAlpha: CGFloat = 0.4 {
        didSet { maskManager.updateDimmingAlpha(dimmingAlpha) }
    }
    public var onSubjectTapped: ((Int?) -> Void)?
    /// Called for selection gestures and result invalidation, not hover or selection assignment.
    public var onSelectionChanged: ((IndexSet) -> Void)?
    /// A host action request, never triggered by mere hover or single click.
    public var onSubjectLiftRequested: ((IndexSet) -> Void)?
    public var isGlowActive: Bool { glowLayer.isActive }

    private let imageLayer = CALayer()
    private let highlightContainer = CALayer()
    private let highlightLayer = CALayer()
    private let glowLayer = GlowLayer()
    private var maskManager: SubjectMaskLayer!
    private var lastContentRect: CGRect = .null
    private var highlightedSubjectsAnimationEnabled = true
    private var hoverTrackingArea: NSTrackingArea?
    private var dragStartPoint: CGPoint?
    private var deferredSelectionPoint: CGPoint?
    private struct MaskPixels {
        let width: Int
        let height: Int
        let bytes: Data
    }
    private var hitTestMasks: [Int: MaskPixels] = [:]
    private var accessibilityObserver: NSObjectProtocol?
    /// Internal override enables deterministic tests without changing system preferences.
    internal var reduceMotionOverride: Bool? {
        didSet { updateHighlight(animated: false) }
    }
    private var reduceMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    deinit {
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        maskManager = SubjectMaskLayer(dimmingAlpha: dimmingAlpha)
        imageLayer.contentsGravity = .resizeAspect
        highlightLayer.contentsGravity = .resizeAspect
        highlightLayer.mask = maskManager.maskShapeLayer
        highlightContainer.opacity = 0
        highlightContainer.allowsGroupOpacity = true
        highlightContainer.shadowColor = NSColor.black.cgColor
        highlightContainer.shadowOpacity = 0
        highlightContainer.shadowRadius = 8
        highlightContainer.shadowOffset = CGSize(width: 0, height: -3)
        highlightContainer.addSublayer(highlightLayer)
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(maskManager.colorLayer)
        layer?.addSublayer(highlightContainer)
        layer?.addSublayer(glowLayer)
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.updateHighlight(animated: false) }
    }

    public override func layout() {
        super.layout()
        let contentRect = imageContentRect
        let changed = contentRect != lastContentRect
        lastContentRect = contentRect
        // Use bounds-space throughout, including when the NSView has a nonzero bounds origin.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in [imageLayer, highlightContainer, glowLayer] {
            item.bounds = bounds
            item.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        highlightLayer.bounds = bounds
        highlightLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        maskManager.layout(bounds: bounds)
        maskManager.maskShapeLayer.bounds = bounds
        maskManager.maskShapeLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        glowLayer.layoutToFit(bounds: bounds)
        CATransaction.commit()
        if changed { updateHighlight(animated: false) }
    }

    /// The actual aspect-fit image rectangle; letterbox regions never hit a subject.
    public var imageContentRect: CGRect {
        let size = isolationResult?.imageSize ?? image?.size ?? .zero
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
            return .zero
        }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    /// Full contours (including holes) decide hits, not bounding boxes or outer-only outlines.
    public func subjectIndex(at point: CGPoint) -> Int? {
        let rect = imageContentRect
        guard let result = isolationResult, rect.width > 0, rect.height > 0,
              rect.contains(point) else { return nil }
        let normalized = CGPoint(x: (point.x - rect.minX) / rect.width,
                                 y: (point.y - rect.minY) / rect.height)
        for subject in result.subjects where subject.index > 0 {
            if let contour = subject.contourPath {
                if contour.contains(normalized, using: .evenOdd) { return subject.index }
            } else if maskContains(normalized, subject: subject) {
                return subject.index
            }
        }
        return nil
    }

    /// Optional contour generation may fail while Vision's real mask remains usable.
    /// Decode once, then hit the foreground pixels; never substitute a bounding-box hit.
    private func maskContains(_ point: CGPoint, subject: SubjectInstance) -> Bool {
        if hitTestMasks[subject.index] == nil {
            let mask = subject.mask
            guard let context = CGContext(data: nil, width: mask.width, height: mask.height,
                                          bitsPerComponent: 8, bytesPerRow: mask.width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(mask, in: CGRect(x: 0, y: 0, width: mask.width, height: mask.height))
            guard let bytes = context.data else { return false }
            hitTestMasks[subject.index] = MaskPixels(width: mask.width, height: mask.height,
                                                    bytes: Data(bytes: bytes, count: mask.width * mask.height))
        }
        guard let pixels = hitTestMasks[subject.index] else { return false }
        let x = min(pixels.width - 1, max(0, Int(point.x * CGFloat(pixels.width))))
        let y = min(pixels.height - 1, max(0, Int((1 - point.y) * CGFloat(pixels.height))))
        return pixels.bytes[y * pixels.width + x] > 127
    }

    /// Update a transient preview from a point, or clear it with nil. Does not commit selection.
    public func previewSubject(at point: CGPoint?) {
        let index = point.flatMap { subjectIndex(at: $0) }
        guard hoveredSubjectIndex != index else { return }
        hoveredSubjectIndex = index
        updateHighlight(animated: true)
    }

    /// Commit a point selection. Extension toggles membership; background clears unless extending.
    public func selectSubject(at point: CGPoint, extendingSelection: Bool = false) {
        let index = subjectIndex(at: point)
        var next = validSelectedSubjects
        if extendingSelection && allowsMultipleSelection {
            if let index {
                if next.contains(index) { next.remove(index) } else { next.insert(index) }
            }
        } else {
            next = index.map { IndexSet(integer: $0) } ?? []
        }
        guard next != highlightedSubjects else { return }
        highlightedSubjects = next
        onSelectionChanged?(next)
    }

    /// Explicitly request lifting the committed selection. Returns false for an empty selection.
    /// The host owns the resulting edit; this view only previews and sends actual instance IDs.
    @discardableResult
    public func requestLift(animated: Bool = true) -> Bool {
        let indexes = validSelectedSubjects
        guard !indexes.isEmpty else { return false }
        if animated && !reduceMotion {
            let animation = CAKeyframeAnimation(keyPath: "transform")
            animation.values = [NSValue(caTransform3D: restingTransform),
                                NSValue(caTransform3D: liftedTransform(scale: 1.035, offset: 7)),
                                NSValue(caTransform3D: restingTransform)]
            animation.keyTimes = [0, 0.45, 1]
            animation.duration = 0.42
            animation.timingFunctions = [CAMediaTimingFunction(name: .easeOut),
                                         CAMediaTimingFunction(name: .easeInEaseOut)]
            highlightContainer.add(animation, forKey: "subjectLift")
            glowLayer.add(animation, forKey: "subjectLift")
        }
        onSubjectLiftRequested?(indexes)
        return true
    }

    public func beginGlow(for subjects: IndexSet, animated: Bool = true) {
        setHighlightedSubjects(subjects, animated: animated)
    }
    public func endGlow(animated: Bool = true) {
        setHighlightedSubjects([], animated: animated)
    }

    /// Export only committed subjects, never a hover-only preview. Does not change the clipboard.
    public func copyHighlightedSubjects() -> NSImage? {
        guard let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let result = isolationResult else { return nil }
        let masks = result.subjects.filter { validSelectedSubjects.contains($0.index) }.map(\.mask)
        guard let mask = MaskProcessor.shared.combineMasks(masks),
              let cutout = MaskProcessor.shared.applyMask(image: cgImage, mask: mask) else { return nil }
        return NSImage(cgImage: cutout, size: NSSize(width: cutout.width, height: cutout.height))
    }

    // MARK: Native input

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        hoverTrackingArea = nil
        guard isSubjectInteractionEnabled else { return }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }
    public override func mouseEntered(with event: NSEvent) {
        guard isSubjectInteractionEnabled else { return }
        previewSubject(at: convert(event.locationInWindow, from: nil))
    }
    public override func mouseMoved(with event: NSEvent) {
        guard isSubjectInteractionEnabled else { return }
        previewSubject(at: convert(event.locationInWindow, from: nil))
    }
    public override func mouseExited(with event: NSEvent) {
        previewSubject(at: nil)
    }
    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = subjectIndex(at: point)
        if isSubjectInteractionEnabled {
            let extending = !event.modifierFlags.intersection([.shift, .command]).isEmpty
            // Keep an existing multi-selection intact when beginning a drag of one member.
            if !(allowsSubjectDragging && !extending && index.map { validSelectedSubjects.contains($0) } == true) {
                selectSubject(at: point, extendingSelection: extending)
                deferredSelectionPoint = nil
            } else {
                deferredSelectionPoint = point
            }
            dragStartPoint = index.map { _ in point }
            if event.clickCount == 2 { requestLift() }
        }
        onSubjectTapped?(index)
    }
    public override func mouseUp(with event: NSEvent) {
        if let deferredSelectionPoint, isSubjectInteractionEnabled {
            selectSubject(at: deferredSelectionPoint)
        }
        deferredSelectionPoint = nil
        dragStartPoint = nil
    }
    public override func mouseDragged(with event: NSEvent) {
        guard isSubjectInteractionEnabled, allowsSubjectDragging, let start = dragStartPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
        dragStartPoint = nil
        deferredSelectionPoint = nil
        guard let cutout = copyHighlightedSubjects(), let item = makeDragPasteboardItem(for: cutout) else { return }
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(imageContentRect, contents: cutout)
        previewSubject(at: nil)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }
    public func draggingSession(_ session: NSDraggingSession,
                                sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                                operation: NSDragOperation) {
        dragStartPoint = nil
        previewSubject(at: nil)
    }
    /// Eager in-memory data keeps the drag independent of file cleanup or lazy provider lifetime.
    internal func makeDragPasteboardItem(for image: NSImage) -> NSPasteboardItem? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { return nil }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = image.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        return item
    }

    // MARK: Rendering

    private var validSelectedSubjects: IndexSet {
        guard let result = isolationResult else { return [] }
        return IndexSet(result.subjects.lazy.map(\.index).filter { $0 > 0 && self.highlightedSubjects.contains($0) })
    }
    private var renderedSubjects: [SubjectInstance] {
        guard let result = isolationResult else { return [] }
        var indexes = validSelectedSubjects
        if let hoveredSubjectIndex { indexes.insert(hoveredSubjectIndex) }
        return result.subjects.filter { indexes.contains($0.index) && ($0.outerContourPath ?? $0.contourPath) != nil }
    }
    private var restingTransform: CATransform3D {
        !reduceMotion && hoveredSubjectIndex != nil ? liftedTransform(scale: 1.008, offset: 2) : CATransform3DIdentity
    }
    private func liftedTransform(scale: CGFloat, offset: CGFloat) -> CATransform3D {
        let subjectRect = renderedSubjects.reduce(CGRect.null) { rect, subject in
            guard let path = subject.contourPath ?? subject.outerContourPath else { return rect }
            return rect.union(PathUtilities.transformPath(path, to: imageContentRect).boundingBoxOfPath)
        }
        let center = subjectRect.isNull ? CGPoint(x: bounds.midX, y: bounds.midY)
            : CGPoint(x: subjectRect.midX, y: subjectRect.midY)
        // Keep the selected subject's center fixed while scaling, rather than the canvas center.
        let dx = (1 - scale) * (center.x - bounds.midX)
        let dy = offset + (1 - scale) * (center.y - bounds.midY)
        return CATransform3DScale(CATransform3DMakeTranslation(dx, dy, 0), scale, scale, 1)
    }
    private func setHighlightedSubjects(_ subjects: IndexSet, animated: Bool) {
        highlightedSubjectsAnimationEnabled = animated
        highlightedSubjects = subjects
        highlightedSubjectsAnimationEnabled = true
    }
    private func updateHighlight(animated: Bool) {
        guard maskManager != nil else { return }
        let animate = animated && !reduceMotion
        let subjects = renderedSubjects
        let active = !subjects.isEmpty
        maskManager.setDimming(active: active, animated: animate)
        animateLayer(highlightContainer, keyPath: "opacity", to: active ? Float(1) : Float(0), animated: animate)
        let transform = NSValue(caTransform3D: restingTransform)
        for item in [highlightContainer, glowLayer] {
            if reduceMotion { item.removeAllAnimations() }
            animateLayer(item, keyPath: "transform", to: transform, animated: animate)
        }
        animateLayer(highlightContainer, keyPath: "shadowOpacity", to: hoveredSubjectIndex == nil ? Float(0) : Float(0.22), animated: animate)
        guard active else {
            glowLayer.stopAllAnimations(animated: animate)
            if !animate { maskManager.updateMask(path: nil, animated: false) }
            return
        }
        let combined = CGMutablePath()
        let rect = imageContentRect
        let ids = IndexSet(subjects.map(\.index))
        glowLayer.removeAnimations(except: ids, animated: animate)
        for (offset, subject) in subjects.enumerated() {
            guard let path = subject.outerContourPath ?? subject.contourPath else { continue }
            let viewPath = PathUtilities.transformPath(path, to: rect)
            // Use the full contour for the image mask so holes never reveal background pixels.
            combined.addPath(PathUtilities.transformPath(subject.contourPath ?? path, to: rect))
            glowLayer.beginAnimation(path: viewPath, subjectIndex: subject.index,
                                     viewScale: max(rect.width, rect.height) / 500,
                                     screenScale: window?.backingScaleFactor ?? 2,
                                     totalSubjects: subjects.count, subjectOffset: offset,
                                     animated: animate, reduceMotion: reduceMotion)
        }
        // Morphing unrelated contour topology produces artifacts; animate opacity/lift, not paths.
        maskManager.updateMask(path: combined, animated: false)
    }
    private func animateLayer(_ layer: CALayer, keyPath: String, to target: Any, animated: Bool) {
        let current = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        layer.removeAnimation(forKey: keyPath)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(target, forKeyPath: keyPath)
        CATransaction.commit()
        if animated {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = current
            animation.toValue = target
            animation.duration = 0.22
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(animation, forKey: keyPath)
        }
    }
    private static func sameSnapshot(_ lhs: IsolationResult?, _ rhs: IsolationResult?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?):
            return lhs.imageSize == rhs.imageSize && lhs.subjects.count == rhs.subjects.count
                && zip(lhs.subjects, rhs.subjects).allSatisfy { a, b in
                    a.index == b.index && a.mask === b.mask && a.boundingBox == b.boundingBox
                        && a.contourPath == b.contourPath && a.outerContourPath == b.outerContourPath
                }
        default: return false
        }
    }
}
