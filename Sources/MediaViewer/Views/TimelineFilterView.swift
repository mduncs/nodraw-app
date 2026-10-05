import SwiftUI
import AppKit

// MARK: - TimelineFilterView

/// Horizontal timeline scrubber with density visualization and date range filtering.
/// Bloomberg-aesthetic: thin, information-dense, dark chrome.
struct TimelineFilterView: View {
    @ObservedObject var viewModel: TimelineViewModel
    let onRangeChanged: (ClosedRange<Date>?) -> Void

    @State private var isDragging: Bool = false
    @State private var dragStartPosition: CGFloat = 0
    @State private var dragCurrentPosition: CGFloat = 0
    @State private var isHovering: Bool = false
    @State private var hoverPosition: CGFloat = 0
    @State private var activeHandleEdge: RangeEdge?
    @State private var activeHandlePosition: CGFloat?
    @State private var showsDateRangeEditor = false
    @State private var draftRangeStart = Date()
    @State private var draftRangeEnd = Date()

    private enum RangeEdge: Equatable { case lower, upper }

    private let barSpacing: CGFloat = 1
    /// A few wide buckets read as bars, not as slabs filling the strip.
    private let maxBarWidth: CGFloat = 28
    private let maxBarHeight: CGFloat = 32
    private let minBarHeight: CGFloat = 3

    var body: some View {
        VStack(spacing: 0) {
            // Collapse/expand toggle
            if viewModel.isExpanded {
                expandedContent
            } else {
                collapsedContent
            }
        }
        .background(Color(hex: 0x1a1a1a))
        .onReceive(viewModel.$selectedRange) { newRange in
            onRangeChanged(newRange)
        }
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        VStack(spacing: 4) {
            // Header row with labels and controls
            headerRow

            // Main timeline scrubber
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    // Background
                    Rectangle()
                        .fill(Color(hex: 0x252525))

                    // Density bars
                    densityBars(in: geometry.size)

                    // Selection overlay
                    if let range = viewModel.selectedRange {
                        selectionOverlay(range: range, in: geometry.size)
                    }

                    // Hover indicator
                    if isHovering && !isDragging {
                        hoverIndicator(in: geometry.size)
                    }

                    // Drag selection preview
                    if isDragging {
                        dragSelectionPreview(in: geometry.size)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .contentShape(Rectangle())
                .coordinateSpace(name: "timelinePlot")
                .gesture(dragGesture(in: geometry.size), including: canScrub ? .all : .subviews)
                .onHover { hovering in
                    isHovering = hovering && canScrub
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoverPosition = location.x
                    case .ended:
                        break
                    }
                }
            }
            .frame(height: maxBarHeight + 8)
            .help(canScrub ? Self.gestureHint : "")

            // Axis labels
            axisLabels
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Collapsed Content

    private var collapsedContent: some View {
        HStack(spacing: 6) {
            Button(action: { viewModel.isExpanded = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.caption)
                    if let label = viewModel.selectedRangeLabel ?? viewModel.dataRangeLabel {
                        Text(label)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption2)

                    Spacer(minLength: 0)
                }
                .foregroundStyle(viewModel.selectedRange == nil ? Color.secondary : Color.accentColor)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Expand date filter")

            if viewModel.selectedRange != nil {
                Button(action: { viewModel.clearSelection() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear date filter")
                .accessibilityLabel("Clear date filter")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Header Row

    private static let gestureHint = "Click a period to filter · drag to set a range · drag either edge to adjust"

    /// More than one period to choose between.
    private var canScrub: Bool { !viewModel.buckets.isEmpty && !viewModel.hasSinglePeriod }

    private var headerRow: some View {
        HStack(spacing: 8) {
            // Collapse button
            Button(action: { viewModel.isExpanded = false }) {
                Image(systemName: "chevron.up")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Collapse timeline")
            .accessibilityLabel("Collapse timeline")

            // Date range label
            if let label = viewModel.selectedRangeLabel {
                rangeLabel(label, isFiltered: true)

                Button(action: { viewModel.clearSelection() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear date filter")
                .accessibilityLabel("Clear date filter")
            } else if let label = viewModel.dataRangeLabel {
                rangeLabel(label, isFiltered: false)
            }

            // Instructions only when there is something to click. Shorter copy at narrower widths,
            // and nothing rather than a clipped fragment when even that does not fit.
            if canScrub {
                ViewThatFits(in: .horizontal) {
                    gestureHintLabel(Self.gestureHint)
                    gestureHintLabel("Click or drag to filter by date")
                    Color.clear.frame(width: 0, height: 0)
                }
                .layoutPriority(-1)
            }

            Spacer(minLength: 8)

            // Granularity controls
            Button {
                if let range = viewModel.selectedRange {
                    draftRangeStart = range.lowerBound
                    draftRangeEnd = range.upperBound
                } else if let range = viewModel.dataRange {
                    draftRangeStart = range.lowerBound
                    draftRangeEnd = range.upperBound
                }
                showsDateRangeEditor = true
            } label: {
                Label("Dates…", systemImage: "calendar")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Set an exact date range")
            .accessibilityLabel("Set exact date range")
            .disabled(viewModel.dataRange == nil)
            .popover(isPresented: $showsDateRangeEditor, arrowEdge: .bottom) {
                dateRangeEditor
            }

            granularityControls
        }
    }

    private func gestureHintLabel(_ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.left.and.right")
                .accessibilityHidden(true)
            Text(text).lineLimit(1).fixedSize()
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
    }

    private var dateRangeEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Date range")
                .font(.headline)
            DatePicker("From", selection: $draftRangeStart, displayedComponents: .date)
            DatePicker("Through", selection: $draftRangeEnd, displayedComponents: .date)
            HStack {
                Button("Clear") {
                    viewModel.clearSelection()
                    showsDateRangeEditor = false
                }
                Spacer()
                Button("Cancel") { showsDateRangeEditor = false }
                Button("Apply") {
                    let start = Calendar.current.startOfDay(for: draftRangeStart)
                    let endDay = Calendar.current.startOfDay(for: draftRangeEnd)
                    guard start <= endDay,
                          let exclusiveEnd = Calendar.current.date(byAdding: .day, value: 1, to: endDay) else { return }
                    viewModel.setSelectedRange(start...exclusiveEnd.addingTimeInterval(-1))
                    showsDateRangeEditor = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(Calendar.current.startOfDay(for: draftRangeStart) > Calendar.current.startOfDay(for: draftRangeEnd))
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    /// A readout, not a second collapse control beside the chevron.
    private func rangeLabel(_ label: String, isFiltered: Bool) -> some View {
        Text(label)
            .font(.caption.monospaced())
            .lineLimit(1)
            .foregroundStyle(isFiltered ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 8)
            .frame(minHeight: 24)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isFiltered ? Color.accentColor.opacity(0.12) : Color.white.opacity(0.04))
            )
            .help(isFiltered ? "Selected archive dates; use Dates… for exact entry" : "Archive dates shown in the timeline")
            .accessibilityLabel(isFiltered ? "Selected date range \(label)" : "Date range \(label)")
    }

    // MARK: - Granularity Controls

    private var granularityControls: some View {
        HStack(spacing: 4) {
            // Zoom out
            Button(action: { viewModel.zoomOut() }) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.caption)
                    .frame(width: 18, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(viewModel.granularity == .month ? .tertiary : .secondary)
            .disabled(viewModel.granularity == .month)
            .help("Coarser buckets")
            .accessibilityLabel("Zoom timeline out")

            // Current granularity
            Text(viewModel.granularity.rawValue)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 40)

            // Zoom in
            Button(action: { viewModel.zoomIn() }) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.caption)
                    .frame(width: 18, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(viewModel.granularity == .day ? .tertiary : .secondary)
            .disabled(viewModel.granularity == .day)
            .help("Finer buckets")
            .accessibilityLabel("Zoom timeline in")
        }
    }

    // MARK: - Density Bars

    @ViewBuilder
    private func densityBars(in size: CGSize) -> some View {
        let buckets = viewModel.buckets

        if buckets.isEmpty {
            // Empty state
            Text(viewModel.isLoading ? "Loading dates…" : "No archived dates yet")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.hasSinglePeriod, let only = buckets.first {
            // One bucket would draw as a slab across the whole strip. Say what it means instead.
            Text("All \(only.count.formatted()) items archived \(singlePeriodLabel(for: only.date))")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Canvas { context, canvasSize in
                for bucket in buckets {
                    guard let span = viewModel.span(of: bucket) else { continue }
                    let slotStart = span.lowerBound * canvasSize.width
                    let slotWidth = (span.upperBound - span.lowerBound) * canvasSize.width
                    let width = max(1, min(slotWidth - barSpacing, maxBarWidth))
                    let height = bucket.count > 0 ? max(minBarHeight, bucket.normalizedHeight * maxBarHeight) : 1
                    let rect = CGRect(x: slotStart + (slotWidth - width) / 2,
                                      y: canvasSize.height - 2 - height,
                                      width: width, height: height)
                    let color: Color = viewModel.isBucketSelected(bucket) && bucket.count > 0
                        ? .accentColor
                        : Color.white.opacity(bucket.count > 0 ? 0.26 : 0.07)
                    context.fill(Path(roundedRect: rect, cornerRadius: min(1.5, width / 2)), with: .color(color))
                }
            }
            .accessibilityHidden(true)
        }
    }

    private func singlePeriodLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        switch viewModel.granularity {
        case .day:
            formatter.dateStyle = .medium
            return "on " + formatter.string(from: date)
        case .week:
            formatter.dateFormat = "MMM d, yyyy"
            return "the week of " + formatter.string(from: date)
        case .month:
            formatter.dateFormat = "MMMM yyyy"
            return "in " + formatter.string(from: date)
        }
    }

    // MARK: - Selection Overlay

    @ViewBuilder
    private func selectionOverlay(range: ClosedRange<Date>, in size: CGSize) -> some View {
        if let startPos = viewModel.positionForDate(range.lowerBound),
           let endPos = viewModel.positionForDate(range.upperBound) {
            let lowerX = max(0, min(size.width, activeHandleEdge == .lower ? activeHandlePosition ?? startPos * size.width : startPos * size.width))
            let upperX = max(0, min(size.width, activeHandleEdge == .upper ? activeHandlePosition ?? endPos * size.width : endPos * size.width))
            let bandStart = min(lowerX, upperX)
            let bandWidth = max(1, abs(upperX - lowerX))
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: bandWidth, height: size.height)
                    .offset(x: bandStart)

                selectionHandle(edge: .lower, x: lowerX, range: range, in: size)
                selectionHandle(edge: .upper, x: upperX, range: range, in: size)
            }
            .frame(width: size.width, height: size.height)
        }
    }

    private func selectionHandle(edge: RangeEdge, x: CGFloat, range: ClosedRange<Date>, in size: CGSize) -> some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 4, height: maxBarHeight + 4)
            .overlay(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 0.5))
            .frame(width: 24, height: size.height)
            .contentShape(Rectangle())
            .position(x: x, y: size.height / 2)
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("timelinePlot"))
                    .onChanged { value in
                        activeHandleEdge = edge
                        activeHandlePosition = max(0, min(size.width, value.location.x))
                    }
                    .onEnded { value in
                        let position = max(0, min(size.width, value.location.x))
                        if let date = viewModel.dateForPosition(position, in: size.width) {
                            viewModel.moveSelectedRangeBoundary(modelBoundary(for: edge), to: date)
                        }
                        activeHandleEdge = nil
                        activeHandlePosition = nil
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(edge == .lower ? "Adjust range start" : "Adjust range end")
            .accessibilityValue(viewModel.selectedRangeLabel ?? "")
            .accessibilityHint("Drag or use the VoiceOver adjustable action to change the date range")
            .accessibilityAdjustableAction { direction in
                let component = viewModel.granularity.calendarComponent
                let current = edge == .lower ? range.lowerBound : range.upperBound
                let amount = direction == .increment ? 1 : -1
                guard let date = Calendar.current.date(byAdding: component, value: amount, to: current) else { return }
                viewModel.moveSelectedRangeBoundary(modelBoundary(for: edge), to: date)
            }
    }

    private func modelBoundary(for edge: RangeEdge) -> TimelineRangeBoundary {
        edge == .lower ? .lower : .upper
    }

    // MARK: - Hover Indicator

    private func hoverIndicator(in size: CGSize) -> some View {
        VStack(spacing: 2) {
            if let date = viewModel.dateForPosition(hoverPosition, in: size.width) {
                // Date tooltip
                Text(formatHoverDate(date))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 2))
            }

            Rectangle()
                .fill(Color.white.opacity(0.5))
                .frame(width: 1, height: maxBarHeight)
        }
        .position(x: hoverPosition, y: size.height / 2 - 10)
    }

    // MARK: - Drag Selection Preview

    private func dragSelectionPreview(in size: CGSize) -> some View {
        let minX = min(dragStartPosition, dragCurrentPosition)
        let maxX = max(dragStartPosition, dragCurrentPosition)
        let width = max(1, maxX - minX)

        return Rectangle()
            .fill(Color.accentColor.opacity(0.3))
            .frame(width: width, height: maxBarHeight + 4)
            .position(x: minX + width / 2, y: size.height / 2)
    }

    // MARK: - Axis Labels

    @ViewBuilder
    private var axisLabels: some View {
        let buckets = viewModel.buckets

        if buckets.count < 2 {
            EmptyView()
        } else {
            GeometryReader { geometry in
                let width = geometry.size.width
                // About one label per 64pt, always including the first bucket.
                let maxLabels = max(2, Int(width / 64))
                let stride = max(1, Int((Double(buckets.count) / Double(maxLabels)).rounded(.up)))
                let indices = Swift.stride(from: 0, to: buckets.count, by: stride).map { $0 }
                ZStack(alignment: .topLeading) {
                    ForEach(Array(indices.enumerated()), id: \.element) { position, index in
                        let bucket = buckets[index]
                        let previous = position > 0 ? buckets[indices[position - 1]].date : nil
                        let center = viewModel.span(of: bucket).map { ($0.lowerBound + $0.upperBound) / 2 * width } ?? 0
                        Text(viewModel.granularity.formatAxisLabel(for: bucket.date, previous: previous))
                            .font(.system(size: 9).monospaced())
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                            .position(x: min(max(center, 20), width - 20), y: 5)
                    }
                }
            }
            .frame(height: 10)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Drag Gesture

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    dragStartPosition = value.startLocation.x
                }
                dragCurrentPosition = max(0, min(size.width, value.location.x))
            }
            .onEnded { value in
                isDragging = false

                let startX = min(dragStartPosition, dragCurrentPosition)
                let endX = max(dragStartPosition, dragCurrentPosition)

                if endX - startX < 4 {
                    // Click - select single bucket
                    if let date = viewModel.dateForPosition(value.location.x, in: size.width) {
                        selectBucketContaining(date)
                    }
                } else {
                    // Drag - select range
                    if let startDate = viewModel.dateForPosition(startX, in: size.width),
                       let endDate = viewModel.dateForPosition(endX, in: size.width) {
                        viewModel.setSelectedRange(startDate...endDate)
                    }
                }
            }
    }

    // MARK: - Helpers

    private func selectBucketContaining(_ date: Date) {
        if let bucket = viewModel.buckets.first(where: { bucket in
            let nextStart = Calendar.current.date(
                byAdding: viewModel.granularity.calendarComponent,
                value: 1,
                to: bucket.date
            ) ?? bucket.date
            return date >= bucket.date && date < nextStart
        }) {
            viewModel.selectBucket(bucket)
        }
    }

    private func formatHoverDate(_ date: Date) -> String {
        viewModel.granularity.formatLabel(for: date)
    }
}

// MARK: - TimelineFilterContainer

/// Container that manages the TimelineViewModel and integrates with AppState
struct TimelineFilterContainer: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = TimelineViewModel()

    /// Callback when the date range filter changes
    var onFilterChanged: ((ClosedRange<Date>?) -> Void)?

    /// Track whether we've loaded data (to avoid double loading)
    @State private var hasLoadedData = false

    var body: some View {
        TimelineFilterView(viewModel: viewModel) { range in
            onFilterChanged?(range)
        }
        .task {
            await loadDataIfNeeded()
        }
        .onReceive(appState.$initPhase) { phase in
            if case .ready = phase, !hasLoadedData {
                Task {
                    await loadDataIfNeeded()
                }
            }
        }
    }

    private func loadDataIfNeeded() async {
        guard !hasLoadedData, let store = appState.mediaStore else { return }
        hasLoadedData = true
        viewModel.attach(to: store)
        await viewModel.loadTimelineData()
        viewModel.autoSelectGranularity()
    }
}

// MARK: - Preview

#if DEBUG
struct TimelineFilterView_Previews: PreviewProvider {
    static var previews: some View {
        let viewModel = TimelineViewModel()

        // Simulate some bucket data
        let calendar = Calendar.current
        let today = Date()
        var buckets: [TimelineBucket] = []

        for i in 0..<12 {
            if let date = calendar.date(byAdding: .month, value: -i, to: today) {
                let count = Int.random(in: 0...50)
                buckets.append(TimelineBucket(date: date, count: count, maxCount: 50))
            }
        }

        return VStack {
            TimelineFilterView(viewModel: viewModel) { range in
                logDebug("Range changed: \(String(describing: range))")
            }

            Spacer()
        }
        .frame(width: 800, height: 200)
        .background(Color(hex: 0x1a1a1a))
        .preferredColorScheme(.dark)
    }
}
#endif
