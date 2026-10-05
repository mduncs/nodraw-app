import SwiftUI
import AppKit

enum ContextMenuPlacement {
    static func origin(for point: CGPoint, menuSize: CGSize, containerSize: CGSize, inset: CGFloat = 8) -> CGPoint {
        let maxX = max(inset, containerSize.width - menuSize.width - inset)
        let maxY = max(inset, containerSize.height - menuSize.height - inset)
        return CGPoint(
            x: min(max(point.x, inset), maxX),
            y: min(max(point.y, inset), maxY)
        )
    }

    static func viewportSize(menuSize: CGSize, containerSize: CGSize, inset: CGFloat = 8) -> CGSize {
        CGSize(
            width: max(1, min(menuSize.width, containerSize.width - inset * 2)),
            height: max(1, min(menuSize.height, containerSize.height - inset * 2))
        )
    }
}

struct ContextMenuSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

// MARK: - Focus Context Menu Data

/// Actions available in the focus view context menu.
/// All closures are pre-wired by SingleFocusView so the menu just calls them.
struct FocusContextMenuActions {
    // Navigate
    let onPrevItem: (() -> Void)?
    let onNextItem: (() -> Void)?
    let onPrevInSet: (() -> Void)?  // nil at the first page
    let onNextInSet: (() -> Void)?  // nil at the last page
    let hasMultiplePages: Bool  // media files plus the context page
    let isMultiFile: Bool

    // Organize
    let isStarred: Bool
    let onToggleStar: () -> Void
    let onAddTag: () -> Void
    let onAddToBoard: () -> Void
    let onAddToRediscover: () -> Void

    // Clipboard & Export
    let onCopyImage: () -> Void
    let onCopyFilePath: () -> Void
    let onCopySourceURL: () -> Void
    let onQuickExport: () -> Void
    let hasAnnotations: Bool
    let onExportAnnotated: (() -> Void)?

    // File
    let onRevealInFinder: () -> Void
    let onOpenSource: () -> Void
    let isVideo: Bool
    let onTrimVideo: (() -> Void)?
    let hasOCR: Bool
    let showingOCROverlay: Bool
    let onToggleOCR: (() -> Void)?
    let onReprocessOCR: (() -> Void)?

    // View
    let showingMetadataPanel: Bool
    let onToggleMetadataPanel: () -> Void
    let showingRelatedPanel: Bool
    let onToggleRelatedPanel: () -> Void

    // Destructive
    let onDeleteCurrentFile: (() -> Void)?
    let onDeleteWholeItem: (() -> Void)?  // nil if single-file
    var transferContext: MediaActionContext? = nil
}

// MARK: - FocusContextMenuView

/// Custom context menu for the focus/detail view.
/// Matches the visual style of CustomContextMenu in MasonryGrid.swift.
struct FocusContextMenuView: View {
    @EnvironmentObject private var appState: AppState
    let actions: FocusContextMenuActions
    let onDismiss: () -> Void

    @State private var hoveredItem: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // NAVIGATE
            sectionLabel("Navigate")
            menuItem(id: "prev", label: AppCommandCatalog.previousResult.title, icon: "chevron.left", shortcut: "P") {
                actions.onPrevItem?()
            }
            .disabled(actions.onPrevItem == nil)
            menuItem(id: "next", label: AppCommandCatalog.nextResult.title, icon: "chevron.right", shortcut: "N") {
                actions.onNextItem?()
            }
            .disabled(actions.onNextItem == nil)
            if actions.hasMultiplePages {
                menuItem(id: "prevSet", label: AppCommandCatalog.previousAsset.title, icon: "chevron.left.2", shortcut: "[") {
                    actions.onPrevInSet?()
                }
                .disabled(actions.onPrevInSet == nil)
                menuItem(id: "nextSet", label: AppCommandCatalog.nextAsset.title, icon: "chevron.right.2", shortcut: "]") {
                    actions.onNextInSet?()
                }
                .disabled(actions.onNextInSet == nil)
            }

            divider

            // ORGANIZE
            sectionLabel("Organize")
            menuItem(
                id: "star",
                label: actions.isStarred ? "Unstar" : "Star",
                icon: actions.isStarred ? "star.slash" : "star.fill",
                shortcut: "S",
                action: actions.onToggleStar
            )
            menuItem(id: "tag", label: "Add Tag...", icon: "tag", action: actions.onAddTag)
            if FeatureFlags.boards {
                menuItem(id: "board", label: "Add to Board...", icon: "rectangle.stack", shortcut: "B", action: actions.onAddToBoard)
            }
            if FeatureFlags.rediscover {
                menuItem(id: "rediscover", label: "Add to Rediscover", icon: "arrow.clockwise.circle", shortcut: "R", action: actions.onAddToRediscover)
            }

            divider

            // CLIPBOARD & EXPORT
            sectionLabel("Clipboard")
            menuItem(id: "copyImage", label: "Copy Image", icon: "doc.on.doc", shortcut: "\u{2318}C", action: actions.onCopyImage)
                .disabled(actions.transferContext?.canCopyImage != true)
            menuItem(id: "copyPath", label: "Copy File Path", icon: "doc.on.clipboard", action: actions.onCopyFilePath)
                .disabled(actions.transferContext?.isEnabled(.copyPaths, source: .displayed) != true)
            menuItem(id: "copyURL", label: "Copy Source URL", icon: "link", action: actions.onCopySourceURL)
            menuItem(id: "export", label: "Quick Export", icon: "square.and.arrow.up", shortcut: "\u{2318}E", action: actions.onQuickExport)
                .disabled(actions.transferContext?.isEnabled(.exportMetadata, source: .downloaded) != true)
            if FeatureFlags.annotate, actions.hasAnnotations, let onExportAnnotated = actions.onExportAnnotated {
                menuItem(id: "exportAnnotated", label: "Export Annotated", icon: "square.and.arrow.up.on.square", shortcut: "\u{2318}\u{21E7}E", action: onExportAnnotated)
            }

            divider

            // FILE
            sectionLabel("File")
            menuItem(id: "reveal", label: "Reveal in Finder", icon: "folder", action: actions.onRevealInFinder)
                .disabled(actions.transferContext?.isEnabled(.reveal, source: .displayed) != true)
            if let context = actions.transferContext {
                menuItem(id: "transfer", label: "Transfer Source…", icon: "arrow.up.doc") {
                    MediaTransferMenuPresenter.present(context: context, appState: appState)
                }
                .disabled(MediaTransferSource.allCases.allSatisfy { (try? context.resolve($0)) == nil })
            }
            menuItem(id: "openSource", label: "Open Source", icon: "safari", shortcut: "O", action: actions.onOpenSource)
            if actions.isVideo, let onTrim = actions.onTrimVideo {
                menuItem(id: "trim", label: "Trim Video...", icon: "scissors", shortcut: "T", action: onTrim)
            }
            if actions.hasOCR {
                menuItem(
                    id: "toggleOCR",
                    label: actions.showingOCROverlay ? "Hide OCR Overlay" : "Show OCR Overlay",
                    icon: "text.viewfinder",
                    action: { actions.onToggleOCR?() }
                )
                menuItem(id: "reprocessOCR", label: "Reprocess OCR", icon: "arrow.triangle.2.circlepath", action: { actions.onReprocessOCR?() })
            }

            divider

            // VIEW
            sectionLabel("View")
            menuItem(
                id: "metadata",
                label: actions.showingMetadataPanel ? "Hide Metadata Panel" : "Show Metadata Panel",
                icon: "sidebar.right",
                shortcut: "\u{2318}I",
                action: actions.onToggleMetadataPanel
            )
            menuItem(
                id: "related",
                label: actions.showingRelatedPanel ? "Hide Related Panel" : "Show Related Panel",
                icon: "sidebar.left",
                action: actions.onToggleRelatedPanel
            )

            divider

            // DESTRUCTIVE
            if let onDeleteCurrentFile = actions.onDeleteCurrentFile {
                menuItem(
                    id: "delete",
                    label: actions.isMultiFile ? "Delete Current File" : "Delete Item",
                    icon: "trash",
                    shortcut: "\u{232B}",
                    isDestructive: true,
                    action: onDeleteCurrentFile
                )
            }
            if let onDeleteWhole = actions.onDeleteWholeItem {
                menuItem(
                    id: "deleteAll",
                    label: actions.isMultiFile ? "Delete Entire Item" : "Delete Item",
                    icon: "trash.fill",
                    shortcut: "\u{2318}\u{232B}",
                    isDestructive: true,
                    action: onDeleteWhole
                )
            }
        }
        .padding(.vertical, 6)
        .frame(width: 220)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: 0x1a1a1a).opacity(0.98))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 6)
        .keyboardMenu(selected: $hoveredItem, dismiss: onDismiss)
    }

    // MARK: - Divider

    private var divider: some View {
        Divider()
            .background(Color.white.opacity(0.1))
            .padding(.vertical, 4)
    }

    // MARK: - Section Label

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.35))
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }

    // MARK: - Menu Item

    @ViewBuilder
    private func menuItem(
        id: String,
        label: String,
        icon: String,
        shortcut: String? = nil,
        isSelected: Bool = false,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            KeyboardMenuFocus.release()
            onDismiss()
            DispatchQueue.main.async { action() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 16)
                    .foregroundStyle(
                        isDestructive ? Color.red : (hoveredItem == id ? .white : Color.white.opacity(0.85))
                    )

                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(
                        isDestructive ? Color.red : (hoveredItem == id ? .white : Color.white.opacity(0.85))
                    )

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }

                if let shortcut = shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(hoveredItem == id ? Color.white.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardMenuItem(id) {
            onDismiss()
            DispatchQueue.main.async { action() }
        }
        .onHover { isHovered in
            if isHovered { hoveredItem = id }
        }
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}

struct FocusContextMenuOverlay: View {
    let position: CGPoint
    let actions: FocusContextMenuActions
    let onDismiss: () -> Void
    @State private var menuSize = CGSize(width: 220, height: 320)

    var body: some View {
        GeometryReader { geometry in
            let viewportSize = ContextMenuPlacement.viewportSize(
                menuSize: menuSize,
                containerSize: geometry.size
            )
            let origin = ContextMenuPlacement.origin(
                for: position,
                menuSize: viewportSize,
                containerSize: geometry.size
            )
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)

                ScrollView([.horizontal, .vertical]) {
                    FocusContextMenuView(actions: actions, onDismiss: onDismiss)
                        .fixedSize(horizontal: true, vertical: true)
                        .background {
                            GeometryReader { menuGeometry in
                                Color.clear.preference(key: ContextMenuSizeKey.self, value: menuGeometry.size)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .frame(width: viewportSize.width, height: viewportSize.height, alignment: .topLeading)
                    .offset(x: origin.x, y: origin.y)
            }
            .onPreferenceChange(ContextMenuSizeKey.self) { menuSize = $0 }
        }
        .onExitCommand(perform: onDismiss)
    }
}

// MARK: - Right-Click Detector

/// NSViewRepresentable that detects right-clicks via a local event monitor.
/// Returns nil from hitTest so it never blocks left-clicks, drag, scroll, etc.
/// The event monitor converts window coordinates to this view's SwiftUI coordinate space.
struct FocusRightClickDetector: NSViewRepresentable {
    let onRightClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> FocusRightClickNSView {
        let view = FocusRightClickNSView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: FocusRightClickNSView, context: Context) {
        nsView.onRightClick = onRightClick
    }
}

/// Pure hit test for the focus right-click monitor, kept separate so it is testable without a window.
enum FocusRightClickHitTest {
    /// Returns the click in SwiftUI (top-left origin) coordinates, or nil when it lands outside
    /// the visible portion of the view.
    static func menuPoint(forLocalPoint point: CGPoint, bounds: CGRect, visibleRect: CGRect, isFlipped: Bool) -> CGPoint? {
        guard bounds.width > 1, bounds.height > 1,
              !visibleRect.isEmpty, visibleRect.contains(point) else { return nil }
        let y = isFlipped ? point.y - bounds.minY : bounds.maxY - point.y
        return CGPoint(x: point.x - bounds.minX, y: y)
    }
}

class FocusRightClickNSView: NSView {
    var onRightClick: ((CGPoint) -> Void)?
    private var rightClickMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startMonitoring()
        } else {
            stopMonitoring()
        }
    }

    private func startMonitoring() {
        guard rightClickMonitor == nil else { return }
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self = self, let window = self.window, event.window === window else {
                return event
            }
            let isContextClick = event.type == .rightMouseDown ||
                (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            guard isContextClick else { return event }
            // Same rule as the grid: only clicks inside this view's visible media area count.
            // A zero-sized or detached overlay passes the event through untouched.
            guard let point = FocusRightClickHitTest.menuPoint(
                forLocalPoint: self.convert(event.locationInWindow, from: nil),
                bounds: self.bounds,
                visibleRect: self.visibleRect,
                isFlipped: self.isFlipped
            ) else { return event }
            self.onRightClick?(point)
            return nil
        }
    }

    private func stopMonitoring() {
        if let monitor = rightClickMonitor {
            NSEvent.removeMonitor(monitor)
            rightClickMonitor = nil
        }
    }

    deinit {
        stopMonitoring()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil  // Fully transparent to all mouse interactions
    }
}
