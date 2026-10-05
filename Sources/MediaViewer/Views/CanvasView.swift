import SwiftUI
import Combine
import UniformTypeIdentifiers
import AppKit

// MARK: - CanvasView

/// PureRef-style infinite canvas with zoom, pan, and item dragging.
/// Uses viewport-based virtualization to only render visible items.
struct CanvasView: View {
    @ObservedObject var viewModel: CanvasViewModel
    let onItemSelected: (UUID) -> Void
    let onItemDoubleClicked: (UUID) -> Void

    // Gesture state
    @State private var currentDrag: CGSize = .zero
    @State private var isPanning = false
    @State private var draggedItemId: UUID?

    // Track drag start positions to fix cumulative drag bug
    @State private var dragStartPositions: [UUID: CGPoint] = [:]

    // Scroll wheel zoom event monitor
    @State private var scrollMonitor: Any?
    @State private var keyboardMonitor: Any?  // Issue #4: Keyboard shortcuts

    // Animation
    @State private var animateZoom = false

    // Issue #10: Selection rectangle drag state
    @State private var isDrawingSelectionRect = false
    @State private var selectionRectStart: CGPoint = .zero

    // Issue #9: Pan cursor state
    @State private var isPanningWithCursor = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Issue #9: Background with dot grid pattern
                canvasBackground(viewportSize: geometry.size)

                // Canvas content layer
                canvasContent(viewportSize: geometry.size)

                // Selection rectangle (if dragging to select)
                if let selectionRect = viewModel.selectionRect {
                    selectionRectangle(selectionRect)
                }

                // Issue #8: Empty canvas onboarding
                if viewModel.totalPlacements == 0 && !viewModel.isLoading {
                    emptyCanvasPlaceholder
                } else if viewModel.hasOnlyOffscreenPlacements && !viewModel.isLoading {
                    offscreenCanvasPlaceholder
                }

                // Issue #13: Persistent zoom controls in corner
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        canvasZoomControls
                    }
                }
                .padding()

                // Zoom indicator (transient, shown on scroll/pinch)
                if viewModel.showZoomIndicator {
                    zoomIndicator
                }

                // Item count warning
                if viewModel.showItemCountWarning {
                    itemCountWarning
                }
            }
            .clipped()
            .onAppear {
                viewModel.setViewportSize(geometry.size)
                setupScrollWheelZoom()
                setupKeyboardShortcuts()  // Issue #4
            }
            .onDisappear {
                removeScrollWheelZoom()
                removeKeyboardShortcuts()
            }
            .onChange(of: geometry.size) { _, newSize in
                viewModel.setViewportSize(newSize)
            }
        }
        .background(Color(hex: 0x1a1a1a))
        // Magnification gesture for zoom
        .gesture(magnificationGesture)
        // Issue #1: Drop support for adding items to canvas
        .onDrop(of: [.mediaViewerItem, .data], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        // Keyboard shortcuts (via notification center to work with app-wide keyboard handling)
        .onReceive(NotificationCenter.default.publisher(for: .canvasResetView)) { _ in
            viewModel.resetView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .canvasZoomToFit)) { _ in
            viewModel.zoomToFit()
        }
        .onReceive(NotificationCenter.default.publisher(for: .canvasZoomActualSize)) { _ in
            viewModel.setZoom(1.0)
        }
        // GAP #6 fix: Clear layout manager state when canvas is deleted elsewhere
        .onReceive(NotificationCenter.default.publisher(for: .canvasDidDelete)) { notification in
            guard let deletedId = notification.userInfo?["canvasId"] as? UUID,
                  let manager = viewModel.layoutManager else { return }
            Task {
                await manager.invalidateIfCurrent(canvasId: deletedId)
            }
        }
        .focusable()
        // Issue #9: Cursor change during pan
        .onContinuousHover { phase in
            if case .active = phase, isPanningWithCursor {
                NSCursor.closedHand.set()
            }
        }
    }

    // MARK: - Scroll Wheel Zoom

    private func setupScrollWheelZoom() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [self] event in
            // Option + scroll wheel = zoom
            if event.modifierFlags.contains(.option) {
                let zoomDelta = event.scrollingDeltaY * 0.01
                viewModel.zoomBy(1.0 + zoomDelta)
                return nil  // consume event
            }
            return event
        }
    }

    private func removeScrollWheelZoom() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    // MARK: - Issue #4: Keyboard Shortcuts

    private func setupKeyboardShortcuts() {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Arrow keys for pan
            let panAmount: CGFloat = event.modifierFlags.contains(.shift) ? 100 : 20

            switch event.keyCode {
            case 123: // Left arrow
                viewModel.panBy(CGPoint(x: -panAmount, y: 0))
                return nil
            case 124: // Right arrow
                viewModel.panBy(CGPoint(x: panAmount, y: 0))
                return nil
            case 125: // Down arrow
                viewModel.panBy(CGPoint(x: 0, y: panAmount))
                return nil
            case 126: // Up arrow
                viewModel.panBy(CGPoint(x: 0, y: -panAmount))
                return nil
            case 24, 69: // + or keypad +
                viewModel.zoomIn()
                return nil
            case 27, 78: // - or keypad -
                viewModel.zoomOut()
                return nil
            case 19: // 0 key - reset zoom to 100%
                if event.modifierFlags.contains(.command) {
                    viewModel.setZoom(1.0)
                    return nil
                }
            case 3: // F key - fit to view
                if event.modifierFlags.contains(.command) {
                    viewModel.zoomToFit()
                    return nil
                }
            default:
                break
            }
            return event
        }
    }

    private func removeKeyboardShortcuts() {
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
            keyboardMonitor = nil
        }
    }

    // MARK: - Issue #1: Drop Handler

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }

        loadMediaItemDragData(from: providers) { dragData in
            guard let dragData = dragData else {
                logInfo("CANVAS-DROP: Failed to load drag data")
                return
            }

            logInfo("CANVAS-DROP: Adding \(dragData.itemIds.count) items to canvas")
            Task { @MainActor in
                await viewModel.addItemsToCanvas(itemIds: dragData.itemIds)
            }
        }
        return true
    }

    // MARK: - Background

    @ViewBuilder
    private func canvasBackground(viewportSize: CGSize) -> some View {
        // Issue #9: Dot grid background that moves with pan
        Canvas { context, size in
            let gridSpacing: CGFloat = 40 * viewModel.zoomLevel
            let dotRadius: CGFloat = 1.5

            // Calculate offset based on viewport position
            let offsetX = (-viewModel.viewportCenter.x * viewModel.zoomLevel).truncatingRemainder(dividingBy: gridSpacing)
            let offsetY = (-viewModel.viewportCenter.y * viewModel.zoomLevel).truncatingRemainder(dividingBy: gridSpacing)

            let dotColor = Color(white: 0.25)

            for x in stride(from: offsetX, to: size.width + gridSpacing, by: gridSpacing) {
                for y in stride(from: offsetY, to: size.height + gridSpacing, by: gridSpacing) {
                    let rect = CGRect(x: x - dotRadius, y: y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                    context.fill(Circle().path(in: rect), with: .color(dotColor))
                }
            }
        }
        .background(Color(hex: 0x1a1a1a))
        .contentShape(Rectangle())
        .gesture(backgroundGesture(viewportSize: viewportSize))
        .onTapGesture {
            viewModel.clearSelection()
        }
    }

    // Issue #10: Combined pan and selection rect gesture
    private func backgroundGesture(viewportSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let isShiftHeld = NSEvent.modifierFlags.contains(.shift)

                if isShiftHeld {
                    // Issue #10: Selection rectangle mode
                    if !isDrawingSelectionRect {
                        isDrawingSelectionRect = true
                        selectionRectStart = value.startLocation
                    }
                    let rect = CGRect(
                        x: min(selectionRectStart.x, value.location.x),
                        y: min(selectionRectStart.y, value.location.y),
                        width: abs(value.location.x - selectionRectStart.x),
                        height: abs(value.location.y - selectionRectStart.y)
                    )
                    viewModel.selectionRect = rect
                } else {
                    // Pan mode
                    isPanningWithCursor = true
                    NSCursor.closedHand.set()

                    let delta = CGPoint(
                        x: value.translation.width / viewModel.zoomLevel,
                        y: value.translation.height / viewModel.zoomLevel
                    )
                    viewModel.panBy(delta)
                    currentDrag = value.translation
                }
            }
            .onEnded { value in
                if isDrawingSelectionRect {
                    // Issue #10: Complete selection rectangle
                    isDrawingSelectionRect = false
                    if let rect = viewModel.selectionRect {
                        viewModel.selectItemsInRect(rect, viewportSize: viewportSize)
                    }
                    viewModel.selectionRect = nil
                } else {
                    isPanningWithCursor = false
                    NSCursor.arrow.set()
                    currentDrag = .zero
                    viewModel.endPan()
                }
            }
    }

    // MARK: - Canvas Content

    @ViewBuilder
    private func canvasContent(viewportSize: CGSize) -> some View {
        // Offset content by viewport position, scaled by zoom
        let offsetX = -viewModel.viewportCenter.x * viewModel.zoomLevel + viewportSize.width / 2
        let offsetY = -viewModel.viewportCenter.y * viewModel.zoomLevel + viewportSize.height / 2

        ForEach(viewModel.visiblePlacements) { placement in
            CanvasItemView(
                placement: placement,
                mediaItem: viewModel.mediaItem(for: placement.mediaItemId),
                lod: viewModel.currentLOD,
                zoomLevel: viewModel.zoomLevel,
                isSelected: viewModel.selectedIds.contains(placement.mediaItemId),
                onSelect: { modifiers in
                    // Issue #3: Multi-select with Cmd-click
                    if modifiers.contains(.command) {
                        viewModel.toggleSelection(placement.mediaItemId)
                    } else {
                        onItemSelected(placement.mediaItemId)
                        viewModel.select(placement.mediaItemId)
                    }
                },
                onDoubleClick: {
                    onItemDoubleClicked(placement.mediaItemId)
                },
                onDragChanged: { translation in
                    handleItemDrag(placement.mediaItemId, translation: translation)
                },
                onDragEnded: {
                    handleItemDragEnded(placement.mediaItemId)
                },
                onResizeChanged: { newSize in
                    // Issue #2: Resize support
                    viewModel.resizeItem(placement.mediaItemId, to: newSize)
                },
                onResizeEnded: {
                    viewModel.commitItemResize(placement.mediaItemId)
                },
                onRotationChanged: { angle in
                    // Issue #11: Rotation support
                    viewModel.rotateItem(placement.mediaItemId, to: angle)
                },
                onRotationEnded: {
                    viewModel.commitItemRotation(placement.mediaItemId)
                }
            )
            .position(
                x: placement.x * viewModel.zoomLevel + offsetX + (placement.width * viewModel.zoomLevel) / 2,
                y: placement.y * viewModel.zoomLevel + offsetY + (placement.height * viewModel.zoomLevel) / 2
            )
        }
    }

    // MARK: - Selection Rectangle

    private func selectionRectangle(_ rect: CGRect) -> some View {
        Rectangle()
            .fill(Color.accentColor.opacity(0.1))
            .overlay(
                Rectangle()
                    .stroke(Color.accentColor, lineWidth: 1)
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    // MARK: - Issue #8: Empty Canvas Placeholder

    private var emptyCanvasPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Empty Canvas")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Drag items here from the grid or use\n\"Add to Canvas\" from the context menu")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var offscreenCanvasPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "viewfinder.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Items Are Off-Screen")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("\(viewModel.totalPlacements) item(s) exist on this canvas, but none are in the current viewport.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            if viewModel.hasIndexMismatch {
                Text("Index health: \(viewModel.indexedPlacements) indexed of \(viewModel.totalPlacements) total")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.yellow.opacity(0.12))
                    )
            }

            HStack(spacing: 10) {
                Button("Zoom to Fit") {
                    viewModel.zoomToFit()
                }
                .buttonStyle(.borderedProminent)

                Button("Reset View") {
                    viewModel.resetView()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(hex: 0x202020).opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Issue #13: Persistent Zoom Controls

    private var canvasZoomControls: some View {
        HStack(spacing: 0) {
            // Zoom out
            Button {
                viewModel.zoomOut()
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(CanvasZoomButtonStyle())
            .help("Zoom out (-)")

            Divider()
                .frame(height: 16)
                .background(Color.white.opacity(0.2))

            // Zoom percentage
            Text("\(Int(viewModel.zoomLevel * 100))%")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 44, alignment: .center)

            Divider()
                .frame(height: 16)
                .background(Color.white.opacity(0.2))

            // Zoom in
            Button {
                viewModel.zoomIn()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(CanvasZoomButtonStyle())
            .help("Zoom in (+)")

            Divider()
                .frame(height: 16)
                .background(Color.white.opacity(0.2))

            // Fit to view
            Button {
                viewModel.zoomToFit()
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(CanvasZoomButtonStyle())
            .help("Fit to view (Cmd+F)")

            Divider()
                .frame(height: 16)
                .background(Color.white.opacity(0.2))

            // 100%
            Button {
                viewModel.setZoom(1.0)
            } label: {
                Text("1:1")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(CanvasZoomButtonStyle())
            .help("Actual size (Cmd+0)")
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.7))
        )
    }

    // MARK: - Zoom Indicator

    private var zoomIndicator: some View {
        VStack {
            HStack {
                Text("\(Int(viewModel.zoomLevel * 100))%")
                    .font(.system(size: 24, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(hex: 0x2a2a2a).opacity(0.9))
                    )
            }
            Spacer()
        }
        .padding(.top, 60)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.2), value: viewModel.showZoomIndicator)
    }

    // MARK: - Item Count Warning

    private var itemCountWarning: some View {
        VStack {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("\(viewModel.itemCount) items - performance may be affected")
                    .font(.system(size: 13))
                Spacer()
                Button("Dismiss") {
                    viewModel.dismissWarning()
                }
                .buttonStyle(.borderless)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: 0x2a2a2a))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.yellow.opacity(0.3), lineWidth: 1)
                    )
            )
            .padding()
            Spacer()
        }
    }

    // MARK: - Gestures

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                // Pan the viewport
                let delta = CGPoint(
                    x: value.translation.width / viewModel.zoomLevel,
                    y: value.translation.height / viewModel.zoomLevel
                )
                viewModel.panBy(delta)
                currentDrag = value.translation
            }
            .onEnded { _ in
                currentDrag = .zero
                viewModel.endPan()
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                viewModel.zoomBy(scale)
            }
            .onEnded { _ in
                viewModel.endZoom()
            }
    }

    // MARK: - Item Drag Handling

    /// Called when item drag starts - capture initial position
    private func handleItemDragStart(_ itemId: UUID) {
        // Issue #14: Capture state for undo before moving
        viewModel.captureUndoState(for: itemId)

        if let placement = viewModel.visiblePlacements.first(where: { $0.mediaItemId == itemId }) {
            dragStartPositions[itemId] = placement.position
        }
    }

    /// Called during drag - use absolute position from start, not cumulative delta
    private func handleItemDrag(_ itemId: UUID, translation: CGSize) {
        // Capture start position on first drag event
        if dragStartPositions[itemId] == nil {
            handleItemDragStart(itemId)
        }

        draggedItemId = itemId

        // Calculate absolute position from drag start, not cumulative delta
        guard let startPos = dragStartPositions[itemId] else { return }

        // Issue #6: Grid snap
        var newPos = CGPoint(
            x: startPos.x + translation.width / viewModel.zoomLevel,
            y: startPos.y + translation.height / viewModel.zoomLevel
        )

        if viewModel.snapToGrid {
            newPos = viewModel.snappedPosition(newPos)
        }

        viewModel.setItemPosition(itemId, to: newPos)
    }

    /// Called when item drag ends
    private func handleItemDragEnded(_ itemId: UUID) {
        dragStartPositions.removeValue(forKey: itemId)
        draggedItemId = nil
        viewModel.commitItemPosition(itemId)
    }
}

// MARK: - CanvasZoomButtonStyle

private struct CanvasZoomButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isEnabled ? .white.opacity(configuration.isPressed ? 0.6 : 0.9) : .white.opacity(0.3))
            .contentShape(Rectangle())
    }
}

// MARK: - CanvasViewModel

/// ViewModel for CanvasView - manages state and coordinates with CanvasLayoutManager.
@MainActor
class CanvasViewModel: ObservableObject {
    @Published var visiblePlacements: [CanvasItemPlacement] = []
    @Published var displayOrderedItemIDs: [UUID] = []
    @Published var totalPlacements: Int = 0
    @Published var indexedPlacements: Int = 0
    @Published var viewportCenter: CGPoint = .zero
    @Published var zoomLevel: CGFloat = 1.0
    @Published var selectedIds: Set<UUID> = []
    @Published var selectionRect: CGRect?
    @Published var showZoomIndicator = false
    @Published var showItemCountWarning = false
    @Published var isLoading = false

    // Issue #6: Grid snap toggle
    @Published var snapToGrid: Bool = SettingsStore.shared.canvasSnapToGrid {
        didSet { SettingsStore.shared.canvasSnapToGrid = snapToGrid }
    }
    private let gridSize: CGFloat = 20

    private var viewportSize: CGSize = .zero
    private var canvas: CanvasDocument?
    private var mediaItems: [UUID: MediaItem] = [:]
    private(set) var layoutManager: CanvasLayoutManager?
    private var zoomIndicatorTask: Task<Void, Never>?
    private var warningDismissed = false

    // Issue #14: Undo support
    private var undoStates: [UUID: (position: CGPoint, size: CGSize, rotation: Double)] = [:]
    var undoStack: UndoStack?

    // Zoom constraints
    private let minZoom: CGFloat = 0.05
    private let maxZoom: CGFloat = 4.0
    private let zoomStep: CGFloat = 0.25

    // Pre-zoom state for gesture (use explicit flag instead of checking gestureStartZoom == 1.0)
    private var isZoomGestureActive = false
    private var gestureStartZoom: CGFloat = 1.0
    private var gestureStartCenter: CGPoint = .zero

    var currentLOD: CanvasLOD {
        CanvasLOD.forScale(zoomLevel)
    }

    var itemCount: Int {
        totalPlacements
    }

    var visiblePlacementCount: Int {
        visiblePlacements.count
    }

    var offscreenPlacementCount: Int {
        max(totalPlacements - visiblePlacements.count, 0)
    }

    var hasOnlyOffscreenPlacements: Bool {
        totalPlacements > 0 && visiblePlacements.isEmpty
    }

    var hasIndexMismatch: Bool {
        indexedPlacements != totalPlacements
    }

    // MARK: - Initialization

    func configure(layoutManager: CanvasLayoutManager, mediaStore: MediaStore) {
        self.layoutManager = layoutManager
    }

    // MARK: - Canvas Loading

    func loadCanvas(_ canvas: CanvasDocument, items: [MediaItem]) async {
        self.canvas = canvas
        self.viewportCenter = canvas.viewport
        self.zoomLevel = canvas.zoomLevel

        // Build item lookup
        mediaItems = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

        // Load placements
        await refreshVisiblePlacements()

        // Check for warning
        if let manager = layoutManager {
            let count = await manager.itemCount
            if count > CanvasLayoutManager.itemCountWarning && !warningDismissed {
                showItemCountWarning = true
            }
        }
    }

    func mediaItem(for id: UUID) -> MediaItem? {
        mediaItems[id]
    }

    // MARK: - Issue #1: Add Items to Canvas

    func addItemsToCanvas(itemIds: [UUID]) async {
        guard let manager = layoutManager, let canvas = canvas else { return }

        // Get MediaItems for the IDs
        let items = itemIds.compactMap { mediaItems[$0] }
        guard !items.isEmpty else { return }

        do {
            let count = try await manager.addItemsToCanvas(
                items: items,
                canvasId: canvas.id,
                startPosition: CGPoint(x: viewportCenter.x - 200, y: viewportCenter.y - 200)
            )
            logInfo("Added \(count) items to canvas")
            await refreshVisiblePlacements()
        } catch {
            logError("Failed to add items to canvas: \(error.localizedDescription)")
        }
    }

    // MARK: - Viewport Management

    func setViewportSize(_ size: CGSize) {
        viewportSize = size
        Task {
            await refreshVisiblePlacements()
        }
    }

    func refreshVisiblePlacements() async {
        guard let manager = layoutManager else { return }

        let viewport = currentViewportRect
        let state = await manager.visibilityState(in: viewport, buffer: 500)
        let allPlacements = await manager.allPlacements()
        visiblePlacements = state.visiblePlacements
        displayOrderedItemIDs = allPlacements.map(\.mediaItemId)
        totalPlacements = state.totalCount
        indexedPlacements = state.indexedCount
    }

    private var currentViewportRect: CGRect {
        let halfWidth = viewportSize.width / (2 * zoomLevel)
        let halfHeight = viewportSize.height / (2 * zoomLevel)
        return CGRect(
            x: viewportCenter.x - halfWidth,
            y: viewportCenter.y - halfHeight,
            width: halfWidth * 2,
            height: halfHeight * 2
        )
    }

    // MARK: - Pan

    func panBy(_ delta: CGPoint) {
        viewportCenter = CGPoint(
            x: viewportCenter.x - delta.x,
            y: viewportCenter.y - delta.y
        )
        Task {
            await refreshVisiblePlacements()
        }
    }

    func endPan() {
        // Save viewport state
        guard let canvas = canvas, let manager = layoutManager else { return }
        Task {
            try? await manager.saveViewport(
                canvasId: canvas.id,
                viewport: viewportCenter,
                zoomLevel: zoomLevel
            )
        }
    }

    // MARK: - Zoom

    func zoomBy(_ scale: CGFloat) {
        // Use explicit flag to track gesture state (fixes bug when zoomLevel == 1.0)
        if !isZoomGestureActive {
            isZoomGestureActive = true
            gestureStartZoom = zoomLevel
            gestureStartCenter = viewportCenter
        }

        let newZoom = (gestureStartZoom * scale).clamped(to: minZoom...maxZoom)
        zoomLevel = newZoom

        showZoomIndicator = true
        zoomIndicatorTask?.cancel()

        Task {
            await refreshVisiblePlacements()
        }
    }

    func endZoom() {
        isZoomGestureActive = false
        gestureStartZoom = 1.0

        // Hide indicator after delay
        zoomIndicatorTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled {
                showZoomIndicator = false
            }
        }

        // Save viewport state
        guard let canvas = canvas, let manager = layoutManager else { return }
        Task {
            try? await manager.saveViewport(
                canvasId: canvas.id,
                viewport: viewportCenter,
                zoomLevel: zoomLevel
            )
        }
    }

    // Issue #4: Zoom in/out methods for keyboard shortcuts
    func zoomIn() {
        setZoom(zoomLevel + zoomStep)
    }

    func zoomOut() {
        setZoom(zoomLevel - zoomStep)
    }

    func setZoom(_ zoom: CGFloat) {
        zoomLevel = zoom.clamped(to: minZoom...maxZoom)
        showZoomIndicator = true

        zoomIndicatorTask?.cancel()
        zoomIndicatorTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled {
                showZoomIndicator = false
            }
        }

        Task {
            await refreshVisiblePlacements()
        }
    }

    func zoomToFit() {
        guard let manager = layoutManager else { return }

        Task {
            let (center, zoom) = await manager.zoomToFit(viewportSize: viewportSize)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.3)) {
                    viewportCenter = center
                    zoomLevel = zoom
                }
            }
            await refreshVisiblePlacements()
        }
    }

    func resetView() {
        withAnimation(.easeInOut(duration: 0.3)) {
            viewportCenter = .zero
            zoomLevel = 1.0
        }
        Task {
            await refreshVisiblePlacements()
        }
    }

    // MARK: - Selection

    func select(_ itemId: UUID) {
        selectedIds = [itemId]
    }

    func toggleSelection(_ itemId: UUID) {
        if selectedIds.contains(itemId) {
            selectedIds.remove(itemId)
        } else {
            selectedIds.insert(itemId)
        }
    }

    func clearSelection() {
        selectedIds.removeAll()
    }

    // Issue #10: Select items in rectangle
    func selectItemsInRect(_ rect: CGRect, viewportSize: CGSize) {
        let offsetX = -viewportCenter.x * zoomLevel + viewportSize.width / 2
        let offsetY = -viewportCenter.y * zoomLevel + viewportSize.height / 2

        var newSelection = Set<UUID>()
        for placement in visiblePlacements {
            let itemRect = CGRect(
                x: placement.x * zoomLevel + offsetX,
                y: placement.y * zoomLevel + offsetY,
                width: placement.width * zoomLevel,
                height: placement.height * zoomLevel
            )
            if rect.intersects(itemRect) {
                newSelection.insert(placement.mediaItemId)
            }
        }
        selectedIds = newSelection
    }

    // MARK: - Issue #6: Grid Snap

    func snappedPosition(_ position: CGPoint) -> CGPoint {
        CGPoint(
            x: round(position.x / gridSize) * gridSize,
            y: round(position.y / gridSize) * gridSize
        )
    }

    // MARK: - Issue #14: Undo Support

    func captureUndoState(for itemId: UUID) {
        guard let placement = visiblePlacements.first(where: { $0.mediaItemId == itemId }) else { return }
        undoStates[itemId] = (position: placement.position, size: placement.size, rotation: placement.rotation)
    }

    // MARK: - Item Movement

    /// Set item position to an absolute position (used for drag with start tracking)
    func setItemPosition(_ itemId: UUID, to position: CGPoint) {
        guard let manager = layoutManager else { return }

        Task {
            await manager.updatePosition(itemId: itemId, position: position)
            await refreshVisiblePlacements()
        }
    }

    /// Commit item position after drag ends (brings to front, triggers save)
    func commitItemPosition(_ itemId: UUID) {
        guard let manager = layoutManager else { return }

        // Issue #14: Push undo action
        if let previousState = undoStates.removeValue(forKey: itemId) {
            let action = CanvasMoveUndoAction(
                itemId: itemId,
                previousPosition: previousState.position,
                layoutManager: manager
            )
            undoStack?.pushForUndo(action)
        }

        Task {
            try? await manager.bringToFront(itemId: itemId)
            await refreshVisiblePlacements()
        }
    }

    /// Move item by delta (legacy method, kept for compatibility)
    func moveItem(_ itemId: UUID, by delta: CGPoint) {
        guard let manager = layoutManager else { return }

        Task {
            if let placement = await manager.placement(for: itemId) {
                let newPosition = CGPoint(
                    x: placement.x + delta.x,
                    y: placement.y + delta.y
                )
                await manager.updatePosition(itemId: itemId, position: newPosition)
            }
            await refreshVisiblePlacements()
        }
    }

    func endItemMove(_ itemId: UUID) {
        // Bring to front
        guard let manager = layoutManager else { return }
        Task {
            try? await manager.bringToFront(itemId: itemId)
            await refreshVisiblePlacements()
        }
    }

    // MARK: - Issue #2: Item Resize

    func resizeItem(_ itemId: UUID, to size: CGSize) {
        guard let manager = layoutManager else { return }
        Task {
            await manager.updateSize(itemId: itemId, size: size)
            await refreshVisiblePlacements()
        }
    }

    func commitItemResize(_ itemId: UUID) {
        guard let manager = layoutManager else { return }

        // Issue #14: Push undo action
        if let previousState = undoStates.removeValue(forKey: itemId) {
            let action = CanvasResizeUndoAction(
                itemId: itemId,
                previousSize: previousState.size,
                layoutManager: manager
            )
            undoStack?.pushForUndo(action)
        }

        Task {
            try? await manager.bringToFront(itemId: itemId)
            await refreshVisiblePlacements()
        }
    }

    // MARK: - Issue #11: Item Rotation

    func rotateItem(_ itemId: UUID, to angle: Double) {
        guard let manager = layoutManager else { return }
        Task {
            await manager.updateRotation(itemId: itemId, rotation: angle)
            await refreshVisiblePlacements()
        }
    }

    func commitItemRotation(_ itemId: UUID) {
        guard let manager = layoutManager else { return }
        Task {
            try? await manager.bringToFront(itemId: itemId)
            await refreshVisiblePlacements()
        }
    }

    // MARK: - Warning

    func dismissWarning() {
        warningDismissed = true
        showItemCountWarning = false
    }
}

// MARK: - Issue #14: Canvas Undo Actions

struct CanvasMoveUndoAction: UndoableAction {
    let itemId: UUID
    let previousPosition: CGPoint
    let layoutManager: CanvasLayoutManager

    var description: String { "Move canvas item" }

    func execute() async throws {
        // Already executed by the drag
    }

    func undo() async throws {
        await layoutManager.updatePosition(itemId: itemId, position: previousPosition)
    }
}

struct CanvasResizeUndoAction: UndoableAction {
    let itemId: UUID
    let previousSize: CGSize
    let layoutManager: CanvasLayoutManager

    var description: String { "Resize canvas item" }

    func execute() async throws {
        // Already executed by the resize
    }

    func undo() async throws {
        await layoutManager.updateSize(itemId: itemId, size: previousSize)
    }
}

// MARK: - Clamped Extension

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - CanvasViewContainer

/// Container view that handles loading a canvas by ID and providing the necessary context.
struct CanvasViewContainer: View {
    let canvasId: UUID
    let onItemSelected: (UUID) -> Void
    let onItemDoubleClicked: (UUID) -> Void

    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = CanvasViewModel()
    @State private var layoutManager: CanvasLayoutManager?
    @State private var isLoading = true
    @State private var errorMessage: String?

    // Issue #7: Export state
    @State private var showingExportSheet = false

    var body: some View {
        VStack(spacing: 0) {
            // Header with controls
            canvasHeader

            ZStack {
                if isLoading {
                    ProgressView("Loading canvas...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(hex: 0x1a1a1a))
                } else if let error = errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text("Failed to load canvas")
                            .font(.headline)
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(hex: 0x1a1a1a))
                } else {
                    CanvasView(
                        viewModel: viewModel,
                        onItemSelected: handleItemSelected,
                        onItemDoubleClicked: handleItemDoubleClicked
                    )
                }
            }
        }
        .background(Color(hex: 0x1a1a1a))
        .task {
            await loadCanvas()
        }
        .sheet(isPresented: $showingExportSheet) {
            CanvasExportSheet(viewModel: viewModel)
        }
        .onChange(of: viewModel.selectedIds) { _ in
            syncDisplayContext()
        }
        .onChange(of: viewModel.displayOrderedItemIDs) { _ in
            syncDisplayContext()
        }
    }

    // MARK: - Header

    private var canvasHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.3x3")
                .foregroundStyle(.cyan)
            Text("Canvas")
                .font(.headline)

            if !isLoading {
                canvasStatsBadge
            }

            if viewModel.hasIndexMismatch {
                indexHealthBadge
            }

            Spacer()

            if viewModel.hasOnlyOffscreenPlacements {
                Button("Show All") {
                    viewModel.zoomToFit()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Zoom to fit all canvas items")
            }

            // Issue #6: Grid snap toggle
            Toggle(isOn: $viewModel.snapToGrid) {
                Image(systemName: "grid")
            }
            .toggleStyle(.button)
            .help("Snap to grid")

            // Issue #7: Export button
            Button {
                showingExportSheet = true
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .help("Export canvas as image")

            Button {
                appState.commitLibraryDestinationChange(.allMedia)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close canvas")
        }
        .padding()
        .background(Color(hex: 0x1f1f1f))
    }

    private var canvasStatsBadge: some View {
        Text(canvasStatsText)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.06))
            )
    }

    private var indexHealthBadge: some View {
        Text("index \(viewModel.indexedPlacements)/\(viewModel.totalPlacements)")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.yellow)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color.yellow.opacity(0.12))
            )
            .help("Canvas spatial index is being reconciled")
    }

    private var canvasStatsText: String {
        if viewModel.totalPlacements == 0 {
            return "0 items"
        }

        return "\(viewModel.visiblePlacementCount) visible / \(viewModel.totalPlacements) total"
    }

    private func loadCanvas() async {
        guard let store = appState.mediaStore else {
            errorMessage = "Media store not available"
            isLoading = false
            return
        }

        let manager = CanvasLayoutManager()
        self.layoutManager = manager

        do {
            // Load canvas document
            guard let canvas = try await manager.fetchCanvas(id: canvasId) else {
                errorMessage = "Canvas not found"
                isLoading = false
                return
            }

            // Load canvas placements
            try await manager.loadCanvas(canvasId)

            // Only this canvas's members, without OCR/transcript/ML payloads.
            let memberIDs = await manager.allPlacements().map(\.mediaItemId)
            let items = try await store.fetchItems(ids: memberIDs,
                includeMLAttributes: false, includePerFileOCR: false,
                includeVideoSegments: false, includeTranscriptSegments: false)
            guard !Task.isCancelled else { return }

            // Configure view model
            viewModel.configure(layoutManager: manager, mediaStore: store)
            viewModel.undoStack = appState.undoStack  // Issue #14
            await viewModel.loadCanvas(canvas, items: items)
            syncDisplayContext()

            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func handleItemSelected(_ itemId: UUID) {
        syncDisplayContext(selectedIDs: [itemId], anchorID: itemId)
        onItemSelected(itemId)
    }

    private func handleItemDoubleClicked(_ itemId: UUID) {
        syncDisplayContext(selectedIDs: [itemId], anchorID: itemId)
        onItemDoubleClicked(itemId)
    }

    private func syncDisplayContext(
        selectedIDs: Set<UUID>? = nil,
        anchorID: UUID? = nil
    ) {
        let orderedItems = canvasDisplayItems()
        let visibleIDs = Set(orderedItems.map(\.id))
        let resolvedSelectedIDs = (selectedIDs ?? viewModel.selectedIds).intersection(visibleIDs)
        let resolvedAnchorID = [anchorID, resolvedSelectedIDs.first]
            .compactMap { $0 }
            .first { visibleIDs.contains($0) }

        appState.setDisplayContext(
            surface: .canvas,
            items: orderedItems,
            selectedIDs: resolvedSelectedIDs,
            anchorID: resolvedAnchorID
        )
    }

    private func canvasDisplayItems() -> [MediaItem] {
        viewModel.displayOrderedItemIDs.compactMap { itemID in
            viewModel.mediaItem(for: itemID)
        }
    }
}

// MARK: - Issue #7: Canvas Export Sheet

struct CanvasExportSheet: View {
    @ObservedObject var viewModel: CanvasViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var exportScale: CGFloat = 2.0
    @State private var isExporting = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Export Canvas")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Scale: \(Int(exportScale))x")
                    .font(.subheadline)
                Slider(value: $exportScale, in: 1...4, step: 1)
            }
            .padding(.horizontal)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Export") {
                    exportCanvas()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isExporting)
            }

            if isExporting {
                ProgressView("Exporting...")
            }
        }
        .padding()
        .frame(width: 300)
    }

    private func exportCanvas() {
        isExporting = true

        Task { @MainActor in
            guard let manager = viewModel.layoutManager else {
                isExporting = false
                return
            }

            // Get all placements
            let placements = await manager.allPlacements()
            guard !placements.isEmpty else {
                isExporting = false
                return
            }

            // Calculate bounds
            let bounds = await manager.contentBounds()

            // Create image
            let size = CGSize(
                width: bounds.width * exportScale,
                height: bounds.height * exportScale
            )

            let renderer = ImageRenderer(content:
                CanvasExportView(
                    placements: placements,
                    mediaItems: { id in viewModel.mediaItem(for: id) },
                    bounds: bounds,
                    scale: exportScale
                )
                .frame(width: size.width, height: size.height)
            )
            renderer.scale = exportScale

            if let image = renderer.nsImage {
                // Save dialog
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.nameFieldStringValue = "canvas-export.png"

                if panel.runModal() == .OK, let url = panel.url {
                    if let tiffData = image.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiffData),
                       let pngData = bitmap.representation(using: .png, properties: [:]) {
                        try? pngData.write(to: url)
                    }
                }
            }

            isExporting = false
            dismiss()
        }
    }
}

// MARK: - Canvas Export View (for ImageRenderer)

struct CanvasExportView: View {
    let placements: [CanvasItemPlacement]
    let mediaItems: (UUID) -> MediaItem?
    let bounds: CGRect
    let scale: CGFloat

    var body: some View {
        ZStack {
            Color(hex: 0x1a1a1a)

            ForEach(placements) { placement in
                if let item = mediaItems(placement.mediaItemId) {
                    CachedImageView(item: item, size: .medium, contentMode: .fill)
                        .frame(
                            width: placement.width * scale,
                            height: placement.height * scale
                        )
                        .rotationEffect(.degrees(placement.rotation))
                        .position(
                            x: (placement.x - bounds.minX + placement.width / 2) * scale,
                            y: (placement.y - bounds.minY + placement.height / 2) * scale
                        )
                }
            }
        }
    }
}
