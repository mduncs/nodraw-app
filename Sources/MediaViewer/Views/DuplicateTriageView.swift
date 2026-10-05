import SwiftUI
import AppKit
import ImageIO

/// Explicit, recoverable review: comparison never implies a recommendation to delete.
struct DuplicateTriageView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel: DuplicateTriageViewModel
    @State private var showHistory = false
    @State private var zoom: CGFloat = 1

    init(detector: DuplicateDetector, reviewService: DuplicateReviewService) {
        _viewModel = StateObject(wrappedValue: DuplicateTriageViewModel(detector: detector, service: reviewService))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = viewModel.errorMessage {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled)
                    Spacer()
                    Button("Reload") { Task { await viewModel.loadGroups() } }
                        .disabled(viewModel.isApplying || viewModel.isScanning)
                }.padding(12).background(.orange.opacity(0.09))
            }
            if let notice = viewModel.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 8)
            }
            if viewModel.isScanning { scanStatus }
            if viewModel.isLoading {
                VStack(spacing: 12) { ProgressView(); Text("Loading comparison…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let group = viewModel.currentGroup {
                comparison(group)
            } else {
                emptyState
            }
            // Decision bar only when there is a group to decide on; an empty queue showed
            // "Keep 0, move 0" and a live zoom button with nothing to zoom.
            if viewModel.currentGroup != nil || viewModel.isApplying {
                Divider()
                footer
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 740, minHeight: 500)
        .task { await viewModel.loadGroups() }
        .onChange(of: viewModel.category) { _, _ in Task { await viewModel.updateFilter() } }
        .onChange(of: viewModel.showingLater) { _, _ in Task { await viewModel.loadGroups() } }
        .onChange(of: viewModel.currentGroup?.id) { _, _ in zoom = 1 }
        .sheet(isPresented: $showHistory) { historySheet }
        .background(TriageKeyboardHandler(isEnabled: !showHistory && !viewModel.isApplying && !viewModel.isScanning,
            onSelect: viewModel.selectItem, onPreviousItem: viewModel.selectPreviousItem,
            onNextItem: viewModel.selectNextItem, onConfirm: { decide(.keepSelected) },
            onKeepAll: { decide(.keepAll) }, onDismiss: { decide(.notDuplicates) },
            onLater: { decide(.later) }, onPrevious: viewModel.goToPrevious,
            onNext: viewModel.skipToNext, onEscape: closeReview))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: closeReview) { Image(systemName: "xmark") }
                .buttonStyle(.plain).help("Close duplicate review").accessibilityLabel("Close duplicate review")
            VStack(alignment: .leading, spacing: 2) {
                Text("Duplicate review").font(.headline)
                Text("Similar media can carry different work.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Match type", selection: $viewModel.category) {
                ForEach(DuplicateTriageViewModel.Category.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().fixedSize().disabled(viewModel.isApplying)
                .help("Exact copies share every media byte; look-alikes are visual suggestions")
            Toggle("Set-aside queue", isOn: $viewModel.showingLater).toggleStyle(.button).disabled(viewModel.isApplying)
                .help("Show only groups you saved for later")
            Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                .help("Decision history and recovery").accessibilityLabel("Decision history and recovery")
            Button(viewModel.isScanning ? "Scanning…" : "Scan library") { viewModel.startScan() }
                .disabled(viewModel.isScanning || viewModel.isApplying)
        }.padding(16)
    }

    private var scanStatus: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(viewModel.scanProgress.displayText).font(.callout).monospacedDigit()
            Spacer()
            Button("Cancel scan") { viewModel.cancelScan() }
        }.padding(12).background(Color.accentColor.opacity(0.06))
    }

    private func comparison(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(group.detectionMethod == .exactDuplicate ? "Exact copies" : "Look-alikes", systemImage: group.detectionMethod.icon)
                        .font(.title3.weight(.semibold))
                    Text(group.evidence?.explanation ?? "Legacy result — scan again to verify current files.")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Text("\(viewModel.currentIndex + 1) / \(viewModel.totalCount)\(viewModel.totalCount >= DuplicateTriageViewModel.batchLimit ? "+" : "") in this queue")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .help("Groups load in batches of up to \(DuplicateTriageViewModel.batchLimit). Decide or set groups aside to reach the next batch.")
            }
            if group.detectionMethod != .exactDuplicate {
                Text("Visual similarity is only a suggestion. Inspect detail before moving anything.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                let count = CGFloat(max(1, min(viewModel.items.count, 4)))
                let width = min(420.0, max(260.0, (geometry.size.width - 16 * (count - 1)) / count))
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                            comparisonCard(item, index: index, width: width,
                                height: max(170, min(340, geometry.size.height - 250)))
                        }
                    }.padding(.bottom, 8)
                }
            }
        }.padding(18)
    }

    private func comparisonCard(_ item: MediaItem, index: Int, width: CGFloat, height: CGFloat) -> some View {
        DuplicateComparisonCard(item: item, index: index, width: width, height: height, zoom: zoom,
            member: viewModel.snapshot?.members.first { $0.id == item.id },
            kept: viewModel.selectedIDs.contains(item.id), enabled: viewModel.canDecide,
            onToggle: { viewModel.toggleItem(item.id) }, onSelect: { viewModel.selectItem(index) })
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if viewModel.isApplying { Text("Verifying source files and saving this decision…").font(.caption).foregroundStyle(.secondary) }
            Text("Keep one or several. Unselected items move to Recently Deleted with their files, notes, edits and references intact. Nothing is merged and no disk space is reclaimed.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button { viewModel.goToPrevious() } label: { Image(systemName: "chevron.left") }
                    .disabled(viewModel.currentIndex == 0 || viewModel.isApplying).help("Previous group (↑)")
                Button { viewModel.skipToNext() } label: { Image(systemName: "chevron.right") }
                    .disabled(viewModel.currentIndex >= viewModel.totalCount - 1 || viewModel.isApplying).help("Next group (↓); no decision saved")
                Button { zoom = zoom == 1 ? 2 : 1 } label: { Text(zoom == 1 ? "Zoom 2×" : "Fit") }
                    .help("Preview zoom; Open original for source-quality inspection")
                Spacer()
                if viewModel.isApplying { ProgressView().controlSize(.small) }
                Button("Later") { decide(.later) }.disabled(!viewModel.canDecide).help("Save for later (L)")
                Button("Not duplicates") { decide(.notDuplicates) }.disabled(!viewModel.canDecide).help("Reject this match; keep every item (D)")
                Button("Keep all") { decide(.keepAll) }.disabled(!viewModel.canDecide).help("Accept the match, keep every item (Space)")
                Button("Keep \(viewModel.selectedIDs.count), move \(viewModel.rejectedCount)") { decide(.keepSelected) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canDecide || viewModel.selectedIDs.isEmpty || viewModel.rejectedCount == 0)
                    .help("Move only unselected whole items to Recently Deleted (Return). Undo is available in History.")
            }.controlSize(.regular)
        }.padding(16)
    }

    private var emptyState: some View {
        let copy = viewModel.emptyStateCopy
        return VStack(spacing: 14) {
            Image(systemName: copy.icon).font(.system(size: 36)).foregroundStyle(.secondary)
            Text(copy.title).font(.title3)
            Text(copy.detail)
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
            if !viewModel.showingLater {
                Button(viewModel.isScanning ? "Scanning…" : "Scan library") { viewModel.startScan() }
                    .disabled(viewModel.isScanning || viewModel.isApplying)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    private var historySheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Decision history").font(.title2)
                Spacer()
                Button("Done") { showHistory = false }.keyboardShortcut(.cancelAction)
            }
            Text("Showing the latest 50 decisions, preserved across launches. Undo restores moved items; Redo reapplies the same decision only if nothing relevant has changed. Older moved items remain in Recently Deleted. Permanently purged items cannot be restored here.")
                .font(.callout).foregroundStyle(.secondary)
            if viewModel.historyEntries.isEmpty { Text("No decisions yet.").foregroundStyle(.secondary).padding() }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.historyEntries) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title).font(.headline)
                                Text("\(entry.date.formatted()) · \(entry.movedCount) moved\(entry.isUndone ? " · Undone" : "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(entry.isUndone ? "Redo" : "Undo") { Task { await viewModel.changeHistory(entry) } }
                                .disabled(viewModel.isApplying || viewModel.isScanning)
                        }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            if let error = viewModel.errorMessage { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
        }.padding(20).frame(width: 640, height: 450).task { await viewModel.loadHistory() }
    }

    private func decide(_ decision: TriageDecision) {
        // No delayed animation: targets are locked synchronously on the input event.
        guard let request = viewModel.beginDecision(decision) else { return }
        Task { await viewModel.perform(request, undoStack: appState.undoStack) }
    }

    private func closeReview() {
        guard !viewModel.isApplying else { return }
        if appState.sidebarSelection == .duplicates { appState.commitLibraryDestinationChange(.allMedia) }
        else { appState.showDuplicateReview = false }
    }
}

/// Event policy is shared with tests; modified shortcuts belong to the app's command
/// system, and repeating keys may navigate but must never repeat a review decision.
enum DuplicateTriageKeyPolicy {
    static func accepts(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool) -> Bool {
        guard modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        let decisions: Set<UInt16> = [36, 49, 2, 37]
        return !(isRepeat && decisions.contains(keyCode))
    }
}

private struct TriageKeyboardHandler: NSViewRepresentable {
    let isEnabled: Bool
    let onSelect: (Int) -> Void
    let onPreviousItem: () -> Void
    let onNextItem: () -> Void
    let onConfirm: () -> Void
    let onKeepAll: () -> Void
    let onDismiss: () -> Void
    let onLater: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> KeyboardView {
        let view = KeyboardView(); view.handler = self
        return view
    }
    func updateNSView(_ view: KeyboardView, context: Context) { view.handler = self }
    final class KeyboardView: NSView {
        var handler: TriageKeyboardHandler?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let handler = self.handler, handler.isEnabled,
                      event.window === self.window, self.window?.isKeyWindow == true,
                      !(self.window?.firstResponder is NSTextView), !self.isHiddenOrHasHiddenAncestor,
                      DuplicateTriageKeyPolicy.accepts(keyCode: event.keyCode, modifiers: event.modifierFlags, isRepeat: event.isARepeat) else { return event }
                switch event.keyCode {
                case 18: handler.onSelect(0)
                case 19: handler.onSelect(1)
                case 20: handler.onSelect(2)
                case 21: handler.onSelect(3)
                case 23: handler.onSelect(4)
                case 22: handler.onSelect(5)
                case 26: handler.onSelect(6)
                case 28: handler.onSelect(7)
                case 25: handler.onSelect(8)
                case 36: handler.onConfirm()
                case 49: handler.onKeepAll()
                case 2: handler.onDismiss()
                case 37: handler.onLater()
                case 123: handler.onPreviousItem()
                case 124: handler.onNextItem()
                case 125: handler.onNext()
                case 126: handler.onPrevious()
                case 53: handler.onEscape()
                default: return event
                }
                return nil
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

private struct TriageImageView: View {
    let itemID: UUID
    let url: URL
    let width: CGFloat
    let height: CGFloat
    @State private var image: NSImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
            else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark").font(.title)
                    Text("Preview unavailable — open original").font(.caption)
                }.foregroundStyle(.secondary)
            } else { ProgressView().controlSize(.small) }
        }.frame(width: width, height: height)
            .task(id: url) {
                image = nil; failed = false
                if let cached = await ImageCache.shared.loadThumbnail(itemId: itemID, from: url, size: .medium) {
                    guard !Task.isCancelled else { return }; image = cached; return
                }
                let loaded = await Task.detached(priority: .utility) { () -> CGImage? in
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1400, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
                }.value
                guard !Task.isCancelled else { return }
                if let loaded { image = NSImage(cgImage: loaded, size: .zero) } else { failed = true }
            }
    }
}

private struct DuplicateComparisonCard: View {
    let item: MediaItem
    let index: Int
    let width: CGFloat
    let height: CGFloat
    let zoom: CGFloat
    let member: DuplicateReviewMember?
    let kept: Bool
    let enabled: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void
    @State private var assetIndex = 0
    @State private var expandedNotes = false
    @State private var dimensions: String?
    private var urls: [URL] { item.mediaFiles + (item.contextImage.map { [$0] } ?? []) }
    private var selectedURL: URL? { urls.indices.contains(assetIndex) ? urls[assetIndex] : urls.first }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Toggle(isOn: Binding(get: { kept }, set: { _ in onToggle() })) { Text("Keep \(index + 1)").font(.headline) }
                        .disabled(!enabled)
                    Spacer()
                    if item.metadata.starred { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                }
                if urls.count > 1 {
                    Picker("Inspect asset", selection: $assetIndex) {
                        ForEach(Array(urls.enumerated()), id: \.offset) { offset, url in
                            Text(offset >= item.mediaFiles.count ? "Source screenshot" : "\(offset + 1). \(url.lastPathComponent)").tag(offset)
                        }
                    }.font(.caption)
                }
                if let url = selectedURL {
                    TriageImageView(itemID: item.id, url: url, width: width - 20, height: height)
                        .scaleEffect(zoom).frame(width: width - 20, height: height).clipped()
                        .background(.black.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 6))
                        .onTapGesture(perform: onSelect)
                }
                HStack {
                    Text(selectedURL?.lastPathComponent ?? item.folderName).font(.caption.weight(.medium))
                        .lineLimit(2).textSelection(.enabled)
                    Spacer()
                    if let dimensions { Text(dimensions).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                }
                HStack(spacing: 8) {
                    Button("Open original") { if let url = selectedURL { NSWorkspace.shared.open(url) } }
                        .disabled(selectedURL == nil).help("Inspect this asset at full quality in its default app")
                    Button("Reveal file") { if let url = selectedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                }.controlSize(.small)
                Text("\(counted(item.mediaFiles.count, "media asset"))\(item.contextImage == nil ? "" : " + source screenshot")\(member.map { " · " + ByteCountFormatter.string(fromByteCount: $0.fileBytes, countStyle: .file) } ?? "")")
                    .font(.caption)
                metadataRow("Source", value: item.metadata.source.absoluteString)
                metadataRow("Captured", value: item.metadata.archivedDate.formatted(date: .abbreviated, time: .shortened))
                metadataRow("Tags", value: item.metadata.tags.isEmpty ? "None" : item.metadata.tags.joined(separator: ", "))
                VStack(alignment: .leading, spacing: 3) {
                    Text("NOTES").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    Text(item.metadata.notes.flatMap { $0.isEmpty ? nil : $0 } ?? "None")
                        .font(.caption).textSelection(.enabled).lineLimit(expandedNotes ? nil : 4)
                    if let notes = item.metadata.notes, !notes.isEmpty {
                        HStack {
                            Button(expandedNotes ? "Collapse" : "Show full notes") { expandedNotes.toggle() }
                            Button("Copy notes") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(notes, forType: .string) }
                        }.buttonStyle(.link).font(.caption)
                    }
                }
                if let member {
                    Label(counted(member.annotationCount, "saved edit document"), systemImage: "square.and.pencil")
                        .font(.caption.weight(member.annotationCount > 0 ? .semibold : .regular))
                        .foregroundStyle(member.annotationCount > 0 ? Color.accentColor : .secondary)
                    if member.annotationCount > 0 {
                        Text("Preview shows the source, not the edit. Edits stay attached to this whole item, including in Recently Deleted.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if member.boardCount > 0 || member.canvasCount > 0 {
                        Text("\(counted(member.boardCount, "board")) · \(counted(member.canvasCount, "canvas reference"))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(kept ? "Will remain in your library" : "Will move as a whole item to Recently Deleted")
                    .font(.caption.weight(.medium)).foregroundStyle(kept ? Color.accentColor : .secondary)
            }.padding(10)
        }.frame(width: width)
            .background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(kept ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: kept ? 2 : 1))
            .task(id: selectedURL) {
                dimensions = nil
                guard let url = selectedURL else { return }
                let value = await Task.detached(priority: .utility) { () -> String? in
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                          let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = info[kCGImagePropertyPixelWidth] as? NSNumber,
                          let height = info[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
                    return "\(width.intValue) × \(height.intValue)"
                }.value
                guard !Task.isCancelled else { return }; dimensions = value
            }
    }
    private func metadataRow(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "1 board", "2 boards" — English-only, matching the rest of the review copy.
private func counted(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}
