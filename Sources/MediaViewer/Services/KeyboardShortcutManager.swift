import Foundation
import AppKit
import Combine

// MARK: - KeyboardShortcutManager

/// Central keyboard handling for the app.
/// Uses NSEvent.addLocalMonitorForEvents for app-level keyboard capture.
/// Handles conflicts, modifier combinations, and context-dependent actions.
///
/// ## Routing (three routes; see cludge map shell H2)
/// Shortcuts reach the app through:
/// 1. **Menu bar commands** (MediaViewerApp.swift) - SwiftUI `.keyboardShortcut()`.
///    These now include some *unmodified* keys too (s, t, b, r, o, n, p, [, ], /,
///    PageUp/Down, Home, End), not only Cmd/Shift combinations.
/// 2. **KeyboardShortcutManager** (this file) - a local `NSEvent` keyDown monitor with
///    context-dependent bindings (grid / detail / annotation / global), the Escape
///    priority chain, and viewport-navigation deferral. It also registers several of
///    the same unmodified keys as the menus, plus some modified ones (for example
///    Cmd+Delete in the grid).
/// 3. **SingleFocusKeyHandler** - an NSViewRepresentable kept for held-modifier
///    tracking (`flagsChanged`) behind the tag overlay.
///
/// Because the local monitor runs before menu key equivalents, a key bound in both
/// routes is decided by this manager whenever it handles the event in the current
/// context; otherwise the menu gets it. `CommandRegistry` documents every route.
///
/// ## Future: Shortcut Customization (Issue #13)
/// To implement custom shortcuts:
/// 1. Add a ShortcutBindings model stored in UserDefaults
/// 2. Load bindings in registerDefaultShortcuts() instead of hardcoding
/// 3. Add Settings > Shortcuts panel for rebinding
/// 4. Validate no conflicts when user changes a binding
@MainActor
final class KeyboardShortcutManager: ObservableObject {
    // MARK: - Published State

    /// Whether the tag input popover should be shown
    @Published var showTagInput: Bool = false

    /// Whether delete confirmation should be shown
    @Published var showDeleteConfirmation: Bool = false

    /// Items pending deletion (for confirmation)
    @Published var itemsPendingDeletion: [UUID] = []

    // MARK: - Private State

    private var localMonitor: Any?
    private var mouseMonitor: Any?
    private var registeredShortcuts: [GlobalShortcut] = []
    private weak var appState: AppState?

    // MARK: - Initialization

    init() {}

    deinit {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Setup

    /// Configure the manager with app state and start monitoring
    func configure(with appState: AppState) {
        self.appState = appState
        registerDefaultShortcuts()
        startMonitoring()
    }

    /// Register the default keyboard shortcuts from SPEC.md
    ///
    /// ## Issue #1: Avoiding Duplicate Handling
    /// Menu bar commands handle all Cmd+key shortcuts. This manager only handles:
    /// - No-modifier keys (S, T, B, R, O, J, K, H, L, N, P, etc.)
    /// - Special keys (Space, Enter, Escape, Delete, arrows, brackets)
    /// - Context-dependent shortcuts (annotation mode overrides)
    ///
    /// DO NOT add Cmd+Z, Cmd+K, Cmd+F, Cmd+I, Cmd+E, Cmd+A, Cmd+D, Cmd+C here.
    /// Those are handled by menu commands in MediaViewerApp.swift.
    private func registerDefaultShortcuts() {
        registeredShortcuts = [
            // MARK: - No-Modifier Shortcuts (menus can't have these)

            // T: Trim video in detail view (must be before addTag to take priority)
            GlobalShortcut(
                keyCode: 17, // T key
                modifiers: [],
                action: .trimVideo,
                context: .detail
            ),

            // Grid view shortcuts - no modifiers
            GlobalShortcut(
                key: "/",
                modifiers: [],
                action: .focusFilterBar,
                context: .grid
            ),
            GlobalShortcut(
                key: "s",
                modifiers: [],
                action: .toggleStar,
                context: .gridOrDetail
            ),
            GlobalShortcut(
                key: "t",
                modifiers: [],
                action: .addTag,
                context: .grid  // T in detail goes to trimVideo
            ),

            // Vim-style navigation (grid only)
            GlobalShortcut(
                key: "j",
                modifiers: [],
                action: .navigateDown,
                context: .grid
            ),
            GlobalShortcut(
                key: "k",
                modifiers: [],
                action: .navigateUp,
                context: .grid
            ),
            GlobalShortcut(
                key: "h",
                modifiers: [],
                action: .navigateLeft,
                context: .grid
            ),
            GlobalShortcut(
                key: "l",
                modifiers: [],
                action: .navigateRight,
                context: .grid
            ),

            // MARK: - Special Keys

            // Space for preview toggle (grid)
            GlobalShortcut(
                keyCode: 49, // Space
                modifiers: [],
                action: .togglePreview,
                context: .grid
            ),

            // Space for play/pause (detail view)
            GlobalShortcut(
                keyCode: 49, // Space
                modifiers: [],
                action: .togglePlayPause,
                context: .detail
            ),

            // M for mute/unmute video in detail view
            GlobalShortcut(
                key: "m",
                modifiers: [],
                action: .toggleVideoMute,
                context: .detail
            ),

            // Enter for detail view (grid)
            GlobalShortcut(
                keyCode: 36, // Enter
                modifiers: [],
                action: .openDetail,
                context: .grid
            ),

            // Escape - complex priority chain handled in handleEscape()
            GlobalShortcut(
                keyCode: 53, // Escape
                modifiers: [],
                action: .escape,
                context: .global
            ),

            // Delete/Backspace for deletion (grid)
            GlobalShortcut(
                keyCode: 51, // Delete/Backspace
                modifiers: [],
                action: .deleteSelected,
                context: .grid
            ),

            // Forward Delete for deletion (grid, full keyboards / Fn+Delete)
            GlobalShortcut(
                keyCode: 117, // Forward Delete
                modifiers: [],
                action: .deleteSelected,
                context: .grid
            ),

            // Cmd+Delete for deletion (grid)
            GlobalShortcut(
                keyCode: 51, // Delete/Backspace
                modifiers: [.command],
                action: .deleteSelected,
                context: .grid
            ),

            // Cmd+Forward Delete for deletion (grid)
            GlobalShortcut(
                keyCode: 117, // Forward Delete
                modifiers: [.command],
                action: .deleteSelected,
                context: .grid
            ),

            // Delete/Backspace for deletion (detail/focus view)
            GlobalShortcut(
                keyCode: 51, // Delete/Backspace
                modifiers: [],
                action: .deleteFocused,
                context: .detail
            ),

            // Forward Delete for deletion (detail/focus view)
            GlobalShortcut(
                keyCode: 117, // Forward Delete
                modifiers: [],
                action: .deleteFocused,
                context: .detail
            ),

            // Cmd+Delete for whole-item deletion (detail/focus view)
            GlobalShortcut(
                keyCode: 51, // Delete/Backspace
                modifiers: [.command],
                action: .deleteWholeItem,
                context: .detail
            ),

            // Cmd+Forward Delete for whole-item deletion (detail/focus view)
            GlobalShortcut(
                keyCode: 117, // Forward Delete
                modifiers: [.command],
                action: .deleteWholeItem,
                context: .detail
            ),

            // Arrow keys for grid navigation
            GlobalShortcut(
                keyCode: 125, // Down arrow
                modifiers: [],
                action: .navigateDown,
                context: .grid
            ),
            GlobalShortcut(
                keyCode: 126, // Up arrow
                modifiers: [],
                action: .navigateUp,
                context: .grid
            ),
            GlobalShortcut(
                keyCode: 123, // Left arrow
                modifiers: [],
                action: .navigateLeft,
                context: .grid
            ),
            GlobalShortcut(
                keyCode: 124, // Right arrow
                modifiers: [],
                action: .navigateRight,
                context: .grid
            ),
            GlobalShortcut(
                keyCode: 125, // Shift+Down arrow
                modifiers: [.shift],
                action: .extendSelectionDown,
                context: .grid
            ),
            GlobalShortcut(
                keyCode: 126, // Shift+Up arrow
                modifiers: [.shift],
                action: .extendSelectionUp,
                context: .grid
            ),
            GlobalShortcut(
                keyCode: 123, // Shift+Left arrow
                modifiers: [.shift],
                action: .extendSelectionLeft,
                context: .grid
            ),
            GlobalShortcut(
                keyCode: 124, // Shift+Right arrow
                modifiers: [.shift],
                action: .extendSelectionRight,
                context: .grid
            ),

            // Native library viewport navigation. Space remains the grid preview shortcut, so
            // Shift-Space is intentionally not introduced as a second page-navigation model.
            GlobalShortcut(
                keyCode: 116, // Page Up (also Fn+Up)
                modifiers: [],
                action: .pageUp,
                context: .grid
            ),
            GlobalShortcut(
                keyCode: 121, // Page Down (also Fn+Down)
                modifiers: [],
                action: .pageDown,
                context: .grid
            ),
            GlobalShortcut(
                keyCode: 115, // Home (also Fn+Left)
                modifiers: [],
                action: .firstItem,
                context: .grid
            ),
            GlobalShortcut(
                keyCode: 119, // End (also Fn+Right)
                modifiers: [],
                action: .lastItem,
                context: .grid
            ),

            // MARK: - Item Actions (no modifiers)

            // B: Add to board
            GlobalShortcut(
                key: "b",
                modifiers: [],
                action: .addToBoard,
                context: .gridOrDetail
            ),

            // N: Next item in detail view
            GlobalShortcut(
                key: "n",
                modifiers: [],
                action: .nextItem,
                context: .detail
            ),

            // P: Previous item in detail view
            GlobalShortcut(
                key: "p",
                modifiers: [],
                action: .previousItem,
                context: .detail
            ),

            // [: Previous sub-image in carousel (keyCode 33)
            GlobalShortcut(
                keyCode: 33, // [ key
                modifiers: [],
                action: .prevSubImage,
                context: .detail
            ),

            // ]: Next sub-image in carousel (keyCode 30)
            GlobalShortcut(
                keyCode: 30, // ] key
                modifiers: [],
                action: .nextSubImage,
                context: .detail
            ),

            // O: Open source URL
            GlobalShortcut(
                key: "o",
                modifiers: [],
                action: .openSource,
                context: .gridOrDetail
            ),

            // MARK: - Annotation Shortcuts (feature-gated)
            // A: Toggle annotation mode + all annotation tool shortcuts
            // Only registered when FeatureFlags.annotate is enabled

            // MARK: - Grid View Specific

            // [: Decrease grid density (keyCode 33) - grid context
            GlobalShortcut(
                keyCode: 33, // [ key
                modifiers: [],
                action: .decreaseDensity,
                context: .grid
            ),

            // ]: Increase grid density (keyCode 30) - grid context
            GlobalShortcut(
                keyCode: 30, // ] key
                modifiers: [],
                action: .increaseDensity,
                context: .grid
            ),
        ]

        // Rediscover shortcut is feature-gated
        if FeatureFlags.rediscover {
            registeredShortcuts.append(
                // R: Add to rediscover queue
                GlobalShortcut(
                    key: "r",
                    modifiers: [],
                    action: .addToRediscover,
                    context: .gridOrDetail
                )
            )
        }

        // Annotation shortcuts are feature-gated
        if FeatureFlags.annotate {
            registeredShortcuts.append(contentsOf: [
                // A: Toggle annotation mode in detail view
                GlobalShortcut(
                    key: "a",
                    modifiers: [],
                    action: .toggleAnnotation,
                    context: .detail
                ),

                // MARK: - Annotation Mode Shortcuts (context: annotationMode)
                // These OVERRIDE normal shortcuts when annotation mode is active

                // V: Select tool
                GlobalShortcut(
                    key: "v",
                    modifiers: [],
                    action: .annotationToolSelect,
                    context: .annotationMode
                ),

                // S: Subject select (sniper) tool - overrides star toggle
                GlobalShortcut(
                    key: "s",
                    modifiers: [],
                    action: .annotationToolSniper,
                    context: .annotationMode
                ),

                // R: Rectangle tool - overrides rediscover
                GlobalShortcut(
                    key: "r",
                    modifiers: [],
                    action: .annotationToolRectangle,
                    context: .annotationMode
                ),

                // A: Arrow tool - overrides toggle annotation (already in annotation mode)
                GlobalShortcut(
                    key: "a",
                    modifiers: [],
                    action: .annotationToolArrow,
                    context: .annotationMode
                ),

                // L: Line/freeform tool
                GlobalShortcut(
                    key: "l",
                    modifiers: [],
                    action: .annotationToolLine,
                    context: .annotationMode
                ),

                // F: Freeform/pen tool
                GlobalShortcut(
                    key: "f",
                    modifiers: [],
                    action: .annotationToolFreeform,
                    context: .annotationMode
                ),

                // H: Highlighter tool
                GlobalShortcut(
                    key: "h",
                    modifiers: [],
                    action: .annotationToolHighlighter,
                    context: .annotationMode
                ),

                // E: Eraser tool
                GlobalShortcut(
                    key: "e",
                    modifiers: [],
                    action: .annotationToolEraser,
                    context: .annotationMode
                ),

                // B: Background remove - overrides add to board
                GlobalShortcut(
                    key: "b",
                    modifiers: [],
                    action: .annotationToolBgRemove,
                    context: .annotationMode
                ),

                // P: Person isolate - overrides previous item
                GlobalShortcut(
                    key: "p",
                    modifiers: [],
                    action: .annotationToolPerson,
                    context: .annotationMode
                ),

                // [: Decrease eraser brush size (keyCode 33)
                GlobalShortcut(
                    keyCode: 33, // [ key
                    modifiers: [],
                    action: .annotationBrushSizeDecrease,
                    context: .annotationMode
                ),

                // ]: Increase eraser brush size (keyCode 30)
                GlobalShortcut(
                    keyCode: 30, // ] key
                    modifiers: [],
                    action: .annotationBrushSizeIncrease,
                    context: .annotationMode
                ),
            ])
        }
    }

    // MARK: - Event Monitoring

    private func startMonitoring() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            // Use MainActor.assumeIsolated since this callback runs on main thread
            return MainActor.assumeIsolated {
                if KeyboardMenuFocus.handle(event) { return nil }
                // The palette keeps its search field as first responder and
                // routes only navigation keys through its own scoped handler.
                if self.appState?.showCommandPalette == true { return event }
                // Skip if a text field is first responder (let it handle input)
                if self.isTextFieldFirstResponder() {
                    // But still handle escape to dismiss/clear
                    if event.keyCode == 53 {
                        return self.handleEscapeInTextField(event)
                    }
                    return event
                }

                // Try to handle the event
                if self.handleKeyEvent(event) {
                    return nil // Consumed
                }

                return event // Pass through
            }
        }

        // Mouse button monitoring for back/forward navigation
        // Button numbers: 0=left, 1=right, 2=middle, 3=button4 (back), 4=button5 (forward)
        // Note: actual button numbers can vary by mouse manufacturer
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self = self else { return event }

            return MainActor.assumeIsolated {
                if self.handleMouseEvent(event) {
                    return nil // Consumed
                }
                return event // Pass through
            }
        }
    }

    private func handleMouseEvent(_ event: NSEvent) -> Bool {
        guard let appState = appState else { return false }

        // Button 3 = back (mouse button 4). Detail and browse transitions share one command.
        if event.buttonNumber == 3 {
            return appState.navigateBack()
        }

        // Button 4 = forward (mouse button 5)
        // In library view: re-open last focused item
        if event.buttonNumber == 4 {
            if !appState.isShowingSingleFocus && appState.lastFocusedItem != nil {
                appState.reopenLastFocusedItem()
                return true
            }
            return false
        }

        return false
    }

    private func isTextFieldFirstResponder() -> Bool {
        guard let window = NSApp.keyWindow,
              let firstResponder = window.firstResponder else {
            return false
        }

        // Check if it's actually a text editing view (field editor)
        // The field editor is an NSTextView that appears when editing text fields
        if let textView = firstResponder as? NSTextView {
            // Only block shortcuts when this is actually a field editor for text input
            if textView.isFieldEditor {
                return true
            }
            // Catch SwiftUI TextEditor (standalone editable NSTextView, not a field editor)
            if textView.isEditable {
                return true
            }
        }

        // Direct NSTextField (though usually the field editor becomes first responder)
        if firstResponder is NSTextField {
            return true
        }

        // Check class names for SwiftUI text input controls
        // Be more specific - only match actual text input, not container views
        let className = firstResponder.className
        return className.contains("NSSearchField") ||
               className.contains("SecureTextField") ||
               (className.contains("TextField") && className.contains("Cell"))
    }

    /// Check whether a native sidebar list or library table currently has focus. These controls
    /// already implement arrows, range selection, Page Up/Down, Home, and End correctly, so the
    /// app-wide monitor must leave their responder-chain behavior intact.
    private func isNativeCollectionFocused() -> Bool {
        guard let window = NSApp.keyWindow,
              let firstResponder = window.firstResponder else {
            return false
        }

        // SwiftUI List uses NSTableView internally
        // Check if focus is on a table-related view (sidebar list)
        let className = firstResponder.className
        return className.contains("NSTableView") ||
               className.contains("NSTableRowView") ||
               className.contains("NSOutlineView") ||
               className.contains("SwiftUIListRow") ||
               className.contains("ListRowContentView")
    }

    /// Check if the action should remain on the focused native collection responder chain.
    private func isNavigationAction(_ action: ShortcutAction) -> Bool {
        switch action {
        case .navigateDown, .navigateUp, .navigateLeft, .navigateRight,
             .extendSelectionDown, .extendSelectionUp,
             .extendSelectionLeft, .extendSelectionRight,
             .openDetail, .togglePreview:
            return true
        default:
            return false
        }
    }

    private func handleEscapeInTextField(_ event: NSEvent) -> NSEvent? {
        guard let appState = appState else { return event }
        if appState.isAnnotationModeActive { return event }

        // Tagging mode now has inline tag creation. Let the focused control receive Escape so its
        // onExitCommand can cancel editing without clearing an unrelated library query or popping
        // the tag tree. With no text focus, the existing tagging Escape shortcut is unchanged.
        if appState.taggingQueue?.isActive == true {
            return event
        }

        // Clear filter if filter bar has focus
        if appState.isFilterBarFocused || !appState.filterText.isEmpty {
            CrashTelemetry.leave("escape-clear-filter was=\(appState.filterText.prefix(20))")
            appState.commitSearchText("")
            appState.isFilterBarFocused = false
            // Resign first responder
            NSApp.keyWindow?.makeFirstResponder(nil)
            return nil
        }

        return event
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        // The mounted editor owns selection, undo/clipboard, nudging and save-aware
        // Escape. Let its window-scoped monitor handle these before global actions.
        if appState?.isAnnotationModeActive == true {
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if [51, 117, 53, 123, 124, 125, 126].contains(event.keyCode) ||
                (modifiers.contains(.command) && ["z", "c", "x", "v", "a", "d"].contains(key)) {
                return false
            }
        }
        // Batch tagging mode intercept -- when active, route keys to the tagging queue
        // before any other shortcut matching
        if appState?.isAnnotationModeActive != true, let queue = appState?.taggingQueue, queue.isActive {
            if handleTaggingKey(event, queue: queue) {
                return true
            }
        }

        let currentContext = determineContext()

        // Find matching shortcut
        for shortcut in registeredShortcuts {
            if shortcut.matches(event: event, currentContext: currentContext) {
                // Page/Home/End belong to the primary library only. Let text controls, sidebars,
                // embedded media/web surfaces, popovers, sheets, and modal overlays keep their
                // native key handling.
                if shortcut.action.isLibraryViewportNavigation,
                   shouldDeferLibraryViewportNavigation() {
                    return false
                }

                // Sidebar lists and the native table own their navigation while focused.
                if isNativeCollectionFocused() && isNavigationAction(shortcut.action) {
                    return false
                }

                executeAction(shortcut.action)
                return true
            }
        }

        return false
    }

    private func shouldDeferLibraryViewportNavigation() -> Bool {
        guard let appState,
              LibraryViewportCommandRouter.isAvailable(in: appState) else {
            return true
        }

        if showTagInput || showDeleteConfirmation ||
            appState.showTagInput || appState.showCommandPalette ||
            appState.showKeyboardShortcutsHelp || appState.showDuplicateReview ||
            appState.showRediscoverSession || appState.taggingQueue?.isActive == true {
            return true
        }

        guard let keyWindow = NSApp.keyWindow,
              keyWindow.attachedSheet == nil,
              keyWindow.sheetParent == nil,
              NSApp.modalWindow == nil,
              !keyWindow.className.localizedCaseInsensitiveContains("popover"),
              windowContainsLibraryViewportBridge(keyWindow) else {
            return true
        }

        if isNativeCollectionFocused() || firstResponderUsesEmbeddedNavigation(in: keyWindow) {
            return true
        }

        return false
    }

    private func windowContainsLibraryViewportBridge(_ window: NSWindow) -> Bool {
        guard let contentView = window.contentView else { return false }
        var pending: [NSView] = [contentView]
        while let view = pending.popLast() {
            if view is LibraryViewportCommandView { return true }
            pending.append(contentsOf: view.subviews)
        }
        return false
    }

    private func firstResponderUsesEmbeddedNavigation(in window: NSWindow) -> Bool {
        guard var view = window.firstResponder as? NSView else { return false }
        let embeddedMarkers = ["WK", "WebKit", "AVPlayer", "PDFView", "QuickLook"]

        while true {
            if embeddedMarkers.contains(where: { view.className.contains($0) }) {
                return true
            }
            guard let parent = view.superview else { return false }
            view = parent
        }
    }

    /// Handle key events during batch tagging mode.
    /// Returns true if the key was consumed by the tagging queue.
    private func handleTaggingKey(_ event: NSEvent, queue: TaggingQueueViewModel) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasShift = flags.contains(.shift)
        let hasCommand = flags.contains(.command)
        let hasControl = flags.contains(.control)
        let hasOption = flags.contains(.option)

        // H5: Cmd+Z to undo last tagging action
        if hasCommand && !hasShift && !hasControl && !hasOption {
            if let chars = event.charactersIgnoringModifiers, chars == "z" {
                Task { @MainActor in
                    await queue.undoAndGoBack()
                    if queue.isActive, let item = queue.currentItem {
                        self.appState?.openSingleFocus(item)
                    } else {
                        self.appState?.taggingQueue = nil
                    }
                }
                return true
            }
            return false
        }

        // H5: Shift+Enter to undo last tagging action
        if hasShift && !hasCommand && !hasControl && !hasOption {
            if event.keyCode == 36 { // Return/Enter
                Task { @MainActor in
                    await queue.undoAndGoBack()
                    if queue.isActive, let item = queue.currentItem {
                        self.appState?.openSingleFocus(item)
                    } else {
                        self.appState?.taggingQueue = nil
                    }
                }
                return true
            }
            // Allow shift through for other keys (key input)
        }

        // No other modifier keys should be active (except shift for key input)
        if hasCommand || hasControl || hasOption { return false }

        switch event.keyCode {
        case 53: // Escape
            queue.goBack()
            // BUG 8 fix: If goBack() exited tagging entirely (was at root with nothing
            // selected), fall through so the normal escape chain can close the focus view.
            // Otherwise the key is consumed and user must press Escape a second time.
            if !queue.isActive { return false }
            return true
        case 51: // Backspace/Delete
            queue.goBack()
            return true
        case 36: // Return/Enter (unmodified -- shift+enter handled above)
            Task { @MainActor in
                await queue.confirmAndAdvance()
                // Sync focused item when tagging queue advances
                if queue.isActive, let nextItem = queue.currentItem {
                    self.appState?.openSingleFocus(nextItem)
                } else {
                    self.appState?.taggingQueue = nil
                }
            }
            return true
        case 48: // Tab -- skip item
            Task { @MainActor in
                await queue.skipItem()
                if queue.isActive, let nextItem = queue.currentItem {
                    self.appState?.openSingleFocus(nextItem)
                } else {
                    self.appState?.taggingQueue = nil
                }
            }
            return true
        default:
            // Check if it's a tag tree key (1-9, 0, q-p) -- only consume if it matches a node
            if let chars = event.charactersIgnoringModifiers, let char = chars.first {
                if TagTreeNode.keySequence.contains(char) || TagTreeNode.keySequence.contains(Character(char.lowercased())) {
                    return queue.handleKeyPress(char)
                }
            }
            return false
        }
    }

    private func determineContext() -> ShortcutContext {
        guard let appState = appState else { return .grid }

        if appState.isShowingSingleFocus {
            // Annotation mode takes priority in detail view
            if appState.isAnnotationModeActive {
                return .annotationMode
            }
            return .detail
        }

        return .grid
    }

    // MARK: - Action Execution

    /// Execute an action for a keyboard shortcut.
    ///
    /// ## Issue #10: Notification-Based Shortcuts
    /// Many actions post notifications rather than calling methods directly.
    /// This is intentional - it decouples the keyboard manager from view implementations.
    /// Views subscribe to notifications they care about. If no listener, the action is a no-op.
    ///
    /// For critical actions where silent failure would be confusing, we use direct appState calls
    /// (toggleStar, navigateToNextItem, etc.) which always work regardless of view state.
    private func executeAction(_ action: ShortcutAction) {
        guard let appState = appState else { return }

        switch action {
        // MARK: - Direct AppState Actions (always work, no notification dependency)

        case .focusFilterBar:
            appState.focusFilterBar()

        case .toggleStar:
            // Direct call - always works (Issue #10: critical action)
            appState.toggleStarOnSelected()

        case .addTag:
            if appState.selectedItemID != nil || appState.focusedItem != nil {
                showTagInput = true
                appState.showTagInput = true
            }

        case .escape:
            handleEscape()

        case .nextItem:
            // Direct call - always works (Issue #10: critical action)
            appState.navigateToNextItem()

        case .previousItem:
            // Direct call - always works (Issue #10: critical action)
            appState.navigateToPrevItem()

        case .deleteSelected:
            let idsToDelete: [UUID]
            if !appState.selectedItemIDs.isEmpty {
                idsToDelete = Array(appState.selectedItemIDs)
            } else if let selectedID = appState.selectedItemID {
                idsToDelete = [selectedID]
            } else {
                idsToDelete = []
            }
            guard !idsToDelete.isEmpty else { return }

            if SettingsStore.shared.skipDeleteConfirmation {
                appState.deleteItems(idsToDelete)
                showDeleteConfirmation = false
                itemsPendingDeletion = []
            } else {
                itemsPendingDeletion = idsToDelete
                showDeleteConfirmation = true
            }

        case .decreaseDensity:
            appState.gridDensity = max(0, appState.gridDensity - 0.2)

        case .increaseDensity:
            appState.gridDensity = min(1, appState.gridDensity + 0.2)

        // MARK: - Grid Navigation (notification-based, handled by MasonryGridContainer)

        case .navigateDown:
            NotificationCenter.default.post(name: .gridNavigateDown, object: nil)

        case .navigateUp:
            NotificationCenter.default.post(name: .gridNavigateUp, object: nil)

        case .navigateLeft:
            NotificationCenter.default.post(name: .gridNavigateLeft, object: nil)

        case .navigateRight:
            NotificationCenter.default.post(name: .gridNavigateRight, object: nil)

        case .extendSelectionDown:
            NotificationCenter.default.post(name: .gridExtendSelectionDown, object: nil)

        case .extendSelectionUp:
            NotificationCenter.default.post(name: .gridExtendSelectionUp, object: nil)

        case .extendSelectionLeft:
            NotificationCenter.default.post(name: .gridExtendSelectionLeft, object: nil)

        case .extendSelectionRight:
            NotificationCenter.default.post(name: .gridExtendSelectionRight, object: nil)

        case .pageUp:
            LibraryViewportCommandRouter.post(.pageUp, appState: appState)

        case .pageDown:
            LibraryViewportCommandRouter.post(.pageDown, appState: appState)

        case .firstItem:
            LibraryViewportCommandRouter.post(.first, appState: appState)

        case .lastItem:
            LibraryViewportCommandRouter.post(.last, appState: appState)

        case .togglePreview:
            NotificationCenter.default.post(name: .togglePreview, object: nil)

        case .openDetail:
            NotificationCenter.default.post(name: .openDetail, object: nil)

        // MARK: - Item Actions (notification-based, various listeners)

        case .deleteFocused:
            NotificationCenter.default.post(name: .deleteFocusedItem, object: nil)

        case .addToBoard:
            guard FeatureFlags.boards else { break }
            if appState.selectedItemID != nil || appState.focusedItem != nil {
                NotificationCenter.default.post(name: .addToBoard, object: nil)
            }

        case .addToRediscover:
            if appState.selectedItemID != nil || appState.focusedItem != nil {
                NotificationCenter.default.post(name: .addToRediscover, object: nil)
            }

        case .deleteWholeItem:
            NotificationCenter.default.post(name: .deleteWholeItem, object: nil)

        case .prevSubImage:
            NotificationCenter.default.post(name: .prevSubImage, object: nil)

        case .nextSubImage:
            NotificationCenter.default.post(name: .nextSubImage, object: nil)

        case .openSource:
            NotificationCenter.default.post(name: .openSourceURL, object: nil)

        case .toggleAnnotation:
            NotificationCenter.default.post(name: .toggleAnnotationMode, object: nil)

        case .trimVideo:
            NotificationCenter.default.post(name: .trimVideo, object: nil)

        case .togglePlayPause:
            NotificationCenter.default.post(name: .togglePlayPause, object: nil)

        case .toggleVideoMute:
            NotificationCenter.default.post(name: .toggleVideoMute, object: nil)

        // MARK: - Annotation Tool Shortcuts (notification-based, SingleFocusView listener)

        case .annotationToolSelect:
            NotificationCenter.default.post(name: .annotationSelectTool, object: nil)

        case .annotationToolSniper:
            NotificationCenter.default.post(name: .annotationSniperTool, object: nil)

        case .annotationToolRectangle:
            NotificationCenter.default.post(name: .annotationRectangleTool, object: nil)

        case .annotationToolArrow:
            NotificationCenter.default.post(name: .annotationArrowTool, object: nil)

        case .annotationToolLine:
            NotificationCenter.default.post(name: .annotationLineTool, object: nil)

        case .annotationToolFreeform:
            NotificationCenter.default.post(name: .annotationFreeformTool, object: nil)

        case .annotationToolHighlighter:
            NotificationCenter.default.post(name: .annotationHighlighterTool, object: nil)

        case .annotationToolEraser:
            NotificationCenter.default.post(name: .annotationEraserTool, object: nil)

        case .annotationToolBgRemove:
            NotificationCenter.default.post(name: .annotationBgRemoveTool, object: nil)

        case .annotationToolPerson:
            NotificationCenter.default.post(name: .annotationPersonTool, object: nil)

        case .annotationBrushSizeDecrease:
            NotificationCenter.default.post(name: .annotationBrushSizeDecrease, object: nil)

        case .annotationBrushSizeIncrease:
            NotificationCenter.default.post(name: .annotationBrushSizeIncrease, object: nil)

        // MARK: - Menu-Handled Actions (kept for backwards compatibility, but menus handle these now)
        // These cases are here to satisfy the switch exhaustiveness but shouldn't be reached
        // because these shortcuts are not registered in registerDefaultShortcuts()

        case .commandPalette, .undo, .redo, .selectAll, .deselectAll,
             .exportWithMetadata, .showInfo, .quickExport, .copyImage:
            // Handled by menu commands in MediaViewerApp.swift
            // If we reach here, something is misconfigured
            logWarning("KeyboardShortcutManager received menu-handled action: \(action)")
        }
    }

    private func handleEscape() {
        guard let appState = appState else { return }

        // Priority order (close innermost overlay first):
        // 1. Close tag input
        if showTagInput {
            showTagInput = false
            appState.showTagInput = false
            return
        }

        // 2. Close command palette
        if appState.showCommandPalette {
            appState.showCommandPalette = false
            return
        }

        // 3. Close delete confirmation
        if showDeleteConfirmation {
            showDeleteConfirmation = false
            itemsPendingDeletion = []
            return
        }

        // 4. Deselect selected subject mask (sniper tool)
        if appState.hasSelectedSubjectMask {
            NotificationCenter.default.post(name: .deselectSubjectMask, object: nil)
            return
        }

        // 5. Deselect annotation shape (before exiting annotation mode)
        if appState.hasSelectedAnnotationShape {
            NotificationCenter.default.post(name: .annotationDeselectShape, object: nil)
            return
        }

        // 6. Exit annotation mode (before closing focus view)
        if appState.isAnnotationModeActive {
            appState.isAnnotationModeActive = false
            return
        }

        // 7. Close detail/focus view
        if appState.isShowingSingleFocus {
            appState.closeSingleFocus()
            return
        }

        // 8. Close duplicate review overlay
        if appState.showDuplicateReview {
            appState.showDuplicateReview = false
            return
        }

        // 9. Close rediscover (FSRS review) view - return to all media
        if appState.sidebarSelection == .rediscover {
            appState.commitLibraryDestinationChange(.allMedia)
            return
        }

        // 10. Clear filter
        if !appState.filterText.isEmpty {
            appState.commitSearchText("")
            return
        }

        // 11. Clear selection
        if appState.selectedItemID != nil {
            appState.selectedItemID = nil
            return
        }
    }

    // MARK: - Public Methods

    /// Register a custom shortcut
    func registerShortcut(_ shortcut: GlobalShortcut) {
        // Check for conflicts
        if let existingIndex = registeredShortcuts.firstIndex(where: { $0.conflicts(with: shortcut) }) {
            logWarning("[KeyboardShortcutManager] Shortcut conflict detected, replacing existing shortcut")
            registeredShortcuts[existingIndex] = shortcut
        } else {
            registeredShortcuts.append(shortcut)
        }
    }

    /// Unregister a shortcut by action
    func unregisterShortcut(action: ShortcutAction) {
        registeredShortcuts.removeAll { $0.action == action }
    }

    /// Get display string for a shortcut action
    func shortcutDisplayString(for action: ShortcutAction) -> String? {
        guard let shortcut = registeredShortcuts.first(where: { $0.action == action }) else {
            return nil
        }
        return shortcut.displayString
    }
}

// MARK: - GlobalShortcut

/// Represents a single keyboard shortcut for app-level handling.
/// Named GlobalShortcut to avoid conflict with SwiftUI's KeyboardShortcut type.
struct GlobalShortcut {
    let key: String?           // Character key (nil if using keyCode)
    let keyCode: UInt16?       // Key code for non-character keys
    let modifiers: NSEvent.ModifierFlags
    let action: ShortcutAction
    let context: ShortcutContext

    init(key: String, modifiers: NSEvent.ModifierFlags, action: ShortcutAction, context: ShortcutContext) {
        self.key = key
        self.keyCode = nil
        self.modifiers = modifiers
        self.action = action
        self.context = context
    }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, action: ShortcutAction, context: ShortcutContext) {
        self.key = nil
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.action = action
        self.context = context
    }

    func matches(event: NSEvent, currentContext: ShortcutContext) -> Bool {
        // Check context
        guard context.matches(currentContext) else { return false }

        // Check modifiers - only compare user modifiers (command, option, shift, control)
        // Ignore system flags like .function and .numericPad which are set by arrow keys
        let userModifierMask: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
        let eventUserModifiers = event.modifierFlags.intersection(userModifierMask)
        let shortcutUserModifiers = modifiers.intersection(userModifierMask)
        guard eventUserModifiers == shortcutUserModifiers else { return false }

        // Check key/keyCode
        if let keyCode = keyCode {
            return event.keyCode == keyCode
        } else if let key = key {
            return event.charactersIgnoringModifiers?.lowercased() == key.lowercased()
        }

        return false
    }

    func conflicts(with other: GlobalShortcut) -> Bool {
        // Same key/keyCode and modifiers, and overlapping context
        let sameKey: Bool
        if let keyCode = keyCode, let otherKeyCode = other.keyCode {
            sameKey = keyCode == otherKeyCode
        } else if let key = key, let otherKey = other.key {
            sameKey = key.lowercased() == otherKey.lowercased()
        } else {
            sameKey = false
        }

        return sameKey && modifiers == other.modifiers && context.overlaps(with: other.context)
    }

    var displayString: String {
        var parts: [String] = []

        if modifiers.contains(.control) { parts.append("^") }
        if modifiers.contains(.option) { parts.append("\u{2325}") } // Option symbol
        if modifiers.contains(.shift) { parts.append("\u{21E7}") }  // Shift symbol
        if modifiers.contains(.command) { parts.append("\u{2318}") } // Command symbol

        if let key = key {
            parts.append(key.uppercased())
        } else if let keyCode = keyCode {
            parts.append(keyCodeDisplayString(keyCode))
        }

        return parts.joined()
    }

    private func keyCodeDisplayString(_ keyCode: UInt16) -> String {
        switch keyCode {
        case 30: return "]"         // ] key
        case 33: return "["         // [ key
        case 36: return "\u{21A9}"  // Return
        case 49: return "Space"
        case 51: return "\u{232B}"  // Delete
        case 53: return "Esc"
        case 115: return "Home"
        case 116: return "Page Up"
        case 119: return "End"
        case 121: return "Page Down"
        case 123: return "\u{2190}" // Left arrow
        case 124: return "\u{2192}" // Right arrow
        case 125: return "\u{2193}" // Down arrow
        case 126: return "\u{2191}" // Up arrow
        default: return "[\(keyCode)]"
        }
    }
}

// MARK: - ShortcutAction

/// All available keyboard shortcut actions
enum ShortcutAction: Equatable {
    case commandPalette
    case focusFilterBar
    case toggleStar
    case addTag
    case navigateDown
    case navigateUp
    case navigateLeft
    case navigateRight
    case extendSelectionDown
    case extendSelectionUp
    case extendSelectionLeft
    case extendSelectionRight
    case pageUp
    case pageDown
    case firstItem
    case lastItem
    case togglePreview
    case openDetail
    case escape
    case undo
    case redo
    case selectAll
    case deselectAll
    case deleteSelected
    case exportWithMetadata
    // New shortcuts
    case showInfo              // Cmd+I: Show metadata/info panel
    case quickExport           // Cmd+E: Quick export
    case addToBoard            // B: Add selected to board
    case addToRediscover       // R: Add to rediscover queue
    case nextItem              // N: Next item in detail view
    case previousItem          // P: Previous item in detail view
    case prevSubImage          // [: Previous sub-image in carousel
    case nextSubImage          // ]: Next sub-image in carousel
    case openSource            // O: Open source URL
    case copyImage             // Cmd+C: Copy image to clipboard
    case toggleAnnotation      // A: Toggle annotation mode (detail view)
    case trimVideo             // T: Trim video (detail view, videos only)
    case togglePlayPause       // Space: Play/pause video (detail view)
    case toggleVideoMute       // M: Mute/unmute video (detail view)
    case deleteFocused         // Delete/Backspace: Delete focused item (detail view)
    case deleteWholeItem       // Cmd+Delete: Delete entire item (detail view, ignores sub-images)

    // Annotation mode tool shortcuts (only active when annotation mode is ON)
    case annotationToolSelect      // V: Select tool
    case annotationToolSniper      // S: Subject select (sniper) tool
    case annotationToolRectangle   // R: Rectangle tool
    case annotationToolArrow       // A: Arrow tool
    case annotationToolLine        // L: Line/freeform tool
    case annotationToolFreeform    // F: Freeform/pen tool
    case annotationToolHighlighter // H: Highlighter tool
    case annotationToolEraser      // E: Eraser tool
    case annotationToolBgRemove    // B: Background remove
    case annotationToolPerson      // P: Person isolate
    case annotationBrushSizeDecrease  // [: Decrease eraser brush size
    case annotationBrushSizeIncrease  // ]: Increase eraser brush size
    case decreaseDensity              // [: Decrease grid density (grid context)
    case increaseDensity              // ]: Increase grid density (grid context)

    var isLibraryViewportNavigation: Bool {
        switch self {
        case .pageUp, .pageDown, .firstItem, .lastItem:
            return true
        default:
            return false
        }
    }
}

// MARK: - ShortcutContext

/// Context in which a shortcut is active
enum ShortcutContext: Equatable {
    case global           // Active everywhere
    case grid             // Active in grid view only
    case detail           // Active in detail view only (annotation mode OFF)
    case gridOrDetail     // Active in both grid and detail (annotation mode OFF)
    case annotationMode   // Active only when annotation mode is ON (detail view)

    func matches(_ current: ShortcutContext) -> Bool {
        switch self {
        case .global:
            return true
        case .grid:
            return current == .grid
        case .detail:
            return current == .detail
        case .gridOrDetail:
            return current == .grid || current == .detail
        case .annotationMode:
            return current == .annotationMode
        }
    }

    func overlaps(with other: ShortcutContext) -> Bool {
        switch (self, other) {
        case (.global, _), (_, .global):
            return true
        case (.gridOrDetail, .grid), (.grid, .gridOrDetail):
            return true
        case (.gridOrDetail, .detail), (.detail, .gridOrDetail):
            return true
        case (.gridOrDetail, .gridOrDetail):
            return true
        // annotationMode is exclusive - only overlaps with itself and global
        case (.annotationMode, .annotationMode):
            return true
        default:
            return self == other
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let gridNavigateDown = Notification.Name("gridNavigateDown")
    static let gridNavigateUp = Notification.Name("gridNavigateUp")
    static let gridNavigateLeft = Notification.Name("gridNavigateLeft")
    static let gridNavigateRight = Notification.Name("gridNavigateRight")
    static let gridExtendSelectionDown = Notification.Name("gridExtendSelectionDown")
    static let gridExtendSelectionUp = Notification.Name("gridExtendSelectionUp")
    static let gridExtendSelectionLeft = Notification.Name("gridExtendSelectionLeft")
    static let gridExtendSelectionRight = Notification.Name("gridExtendSelectionRight")
    static let libraryViewportCommand = Notification.Name("libraryViewportCommand")
    static let togglePreview = Notification.Name("togglePreview")
    static let openDetail = Notification.Name("openDetail")
    static let selectAll = Notification.Name("selectAll")
    static let deselectAll = Notification.Name("deselectAll")

    // Canvas notifications
    static let canvasResetView = Notification.Name("canvasResetView")
    static let canvasZoomToFit = Notification.Name("canvasZoomToFit")
    static let canvasZoomActualSize = Notification.Name("canvasZoomActualSize")

    // Annotation notifications
    static let annotationDeselectShape = Notification.Name("annotationDeselectShape")
    static let deselectSubjectMask = Notification.Name("deselectSubjectMask")

    // Navigation sidebar toggle (for NavigationSplitView)
    static let toggleNavigationSidebar = Notification.Name("toggleNavigationSidebar")

    // New keyboard shortcut notifications
    static let quickExport = Notification.Name("quickExport")
    static let addToBoard = Notification.Name("addToBoard")
    static let addToRediscover = Notification.Name("addToRediscover")
    static let prevSubImage = Notification.Name("prevSubImage")
    static let nextSubImage = Notification.Name("nextSubImage")
    static let openSourceURL = Notification.Name("openSourceURL")
    static let copyImageToClipboard = Notification.Name("copyImageToClipboard")
    static let exportAnnotatedImage = Notification.Name("exportAnnotatedImage")  // Issue #1
    static let toggleAnnotationMode = Notification.Name("toggleAnnotationMode")

    // Annotation tool selection notifications
    static let annotationSelectTool = Notification.Name("annotationSelectTool")
    static let annotationSniperTool = Notification.Name("annotationSniperTool")
    static let annotationRectangleTool = Notification.Name("annotationRectangleTool")
    static let annotationArrowTool = Notification.Name("annotationArrowTool")
    static let annotationLineTool = Notification.Name("annotationLineTool")
    static let annotationFreeformTool = Notification.Name("annotationFreeformTool")
    static let annotationHighlighterTool = Notification.Name("annotationHighlighterTool")
    static let annotationEraserTool = Notification.Name("annotationEraserTool")
    static let annotationBgRemoveTool = Notification.Name("annotationBgRemoveTool")
    static let annotationPersonTool = Notification.Name("annotationPersonTool")
    static let annotationBrushSizeDecrease = Notification.Name("annotationBrushSizeDecrease")
    static let annotationBrushSizeIncrease = Notification.Name("annotationBrushSizeIncrease")
    static let trimVideo = Notification.Name("trimVideo")
    static let togglePlayPause = Notification.Name("togglePlayPause")
    static let toggleVideoMute = Notification.Name("toggleVideoMute")
    static let deleteFocusedItem = Notification.Name("deleteFocusedItem")
    static let deleteWholeItem = Notification.Name("deleteWholeItem")
}
