import SwiftUI
import UniformTypeIdentifiers

// MARK: - Export Options View

/// Sheet for configuring and executing metadata export
struct ExportOptionsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings

    /// Items to export
    let items: [MediaItem]
    var transferContext: MediaActionContext? = nil
    var initialSource: MediaTransferSource = .downloaded
    @State private var source: MediaTransferSource = .downloaded

    private var context: MediaActionContext { transferContext ?? MediaActionContext(items: items) }
    private var exportItems: [MediaItem] { (try? context.exportItems(source: source)) ?? [] }

    /// Callback when export completes
    var onExportComplete: (([ExportResult]) -> Void)?

    @State private var destinationFolder: URL?
    @State private var isExporting = false
    @State private var exportProgress: (current: Int, total: Int) = (0, 0)
    @State private var exportResults: [ExportResult] = []
    @State private var showResults = false
    @State private var errorMessage: String?

    // MARK: - Computed

    private var outputFormat: ExportFormat {
        ExportFormat(rawValue: settings.exportOutputFormat) ?? .jpeg
    }

    private var totalFileCount: Int {
        exportItems.reduce(0) { $0 + $1.mediaFiles.filter(isImageFile).count }
    }

    private var hasSelectedOptions: Bool {
        settings.exportIncludeCaption || settings.exportIncludeSource || settings.exportIncludeCreator ||
        settings.exportIncludeCopyright || settings.exportIncludeKeywords || settings.exportIncludeDate
    }

    private var options: ExportOptions {
        var opts = ExportOptions()
        opts.includeCaption = settings.exportIncludeCaption
        opts.includeSource = settings.exportIncludeSource
        opts.includeCreator = settings.exportIncludeCreator
        opts.includeCopyright = settings.exportIncludeCopyright
        opts.includeKeywords = settings.exportIncludeKeywords
        opts.includeDate = settings.exportIncludeDate
        opts.outputFormat = outputFormat
        opts.jpegQuality = settings.exportJpegQuality
        return opts
    }

    /// Destination path relative to home directory
    private var destinationDisplayPath: String {
        guard let folder = destinationFolder else {
            return ""
        }
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let fullPath = folder.path
        if fullPath.hasPrefix(homePath) {
            return "~" + fullPath.dropFirst(homePath.count)
        }
        return fullPath
    }

    /// Estimated file size based on format, quality, and input dimensions
    private var estimatedFileSize: String? {
        guard totalFileCount > 0 else { return nil }

        // Get first image to estimate from
        guard let firstItem = exportItems.first,
              let firstImage = firstItem.mediaFiles.first(where: isImageFile),
              let imageSource = CGImageSourceCreateWithURL(firstImage as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }

        let pixels = width * height

        // Rough estimates per format (bytes per pixel at quality 1.0)
        let bytesPerPixel: Double
        switch outputFormat {
        case .jpeg:
            // JPEG: ~0.3-1.5 bytes/pixel depending on quality
            bytesPerPixel = 0.3 + (settings.exportJpegQuality * 1.2)
        case .png:
            // PNG: ~1-3 bytes/pixel (lossless)
            bytesPerPixel = 2.0
        case .tiff:
            // TIFF: ~3-4 bytes/pixel (uncompressed RGB)
            bytesPerPixel = 3.5
        case .heic:
            // HEIC: ~0.2-1.0 bytes/pixel (better compression than JPEG)
            bytesPerPixel = 0.2 + (settings.exportJpegQuality * 0.8)
        case .webp:
            // WebP: ~0.2-1.0 bytes/pixel
            bytesPerPixel = 0.2 + (settings.exportJpegQuality * 0.8)
        }

        let estimatedBytes = Double(pixels) * bytesPerPixel
        let totalEstimate = estimatedBytes * Double(totalFileCount)

        return formatBytes(Int64(totalEstimate))
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()
                .background(Color.white.opacity(0.1))

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Items summary
                    itemsSummarySection

                    Picker("Source", selection: $source) {
                        ForEach(MediaTransferSource.allCases) { role in
                            Text(role.label).tag(role)
                                .disabled(!context.isEnabled(.exportMetadata, source: role))
                        }
                    }
                    .disabled(isExporting)

                    // Metadata options
                    metadataOptionsSection

                    // Format options
                    formatOptionsSection

                    // Destination
                    destinationSection

                    // Error message
                    if let error = errorMessage {
                        errorView(error)
                    }
                }
                .padding(24)
            }

            Divider()
                .background(Color.white.opacity(0.1))

            // Footer with buttons
            footerView
        }
        .frame(width: 480, height: 580)
        .background(Color(hex: 0x1a1a1a))
        .onAppear { source = initialSource }
        .sheet(isPresented: $showResults) {
            ExportResultsView(results: exportResults, onDismiss: {
                showResults = false
                dismiss()
            })
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Export with Metadata")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Inject EXIF/IPTC metadata into exported images")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(16)
    }

    // MARK: - Items Summary

    private var itemsSummarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Items to Export", systemImage: "photo.stack")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)

            HStack(spacing: 16) {
                summaryBadge(
                    value: "\(items.count)",
                    label: items.count == 1 ? "item" : "items",
                    icon: "doc"
                )
                summaryBadge(
                    value: "\(totalFileCount)",
                    label: totalFileCount == 1 ? "image" : "images",
                    icon: "photo"
                )
            }
        }
    }

    private func summaryBadge(value: String, label: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(.white)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(hex: 0x2a2a2a))
        )
    }

    // MARK: - Metadata Options

    private var metadataOptionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Metadata to Include", systemImage: "tag")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)

            VStack(spacing: 8) {
                metadataToggle(
                    isOn: Binding(get: { settings.exportIncludeCaption }, set: { settings.exportIncludeCaption = $0 }),
                    label: "Caption",
                    description: "Notes as IPTC Caption-Abstract",
                    icon: "text.quote"
                )
                metadataToggle(
                    isOn: Binding(get: { settings.exportIncludeSource }, set: { settings.exportIncludeSource = $0 }),
                    label: "Source URL",
                    description: "Original URL as IPTC Source",
                    icon: "link"
                )
                metadataToggle(
                    isOn: Binding(get: { settings.exportIncludeCreator }, set: { settings.exportIncludeCreator = $0 }),
                    label: "Creator",
                    description: "Author as EXIF Artist / IPTC Byline",
                    icon: "person"
                )
                metadataToggle(
                    isOn: Binding(get: { settings.exportIncludeKeywords }, set: { settings.exportIncludeKeywords = $0 }),
                    label: "Keywords",
                    description: "Tags as IPTC Keywords",
                    icon: "tag"
                )
                metadataToggle(
                    isOn: Binding(get: { settings.exportIncludeDate }, set: { settings.exportIncludeDate = $0 }),
                    label: "Date Created",
                    description: "Original date as EXIF DateTimeOriginal",
                    icon: "calendar"
                )
                metadataToggle(
                    isOn: Binding(get: { settings.exportIncludeCopyright }, set: { settings.exportIncludeCopyright = $0 }),
                    label: "Copyright",
                    description: "Auto-generated from author and year",
                    icon: "c.circle"
                )
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: 0x222222))
            )
        }
    }

    private func metadataToggle(
        isOn: Binding<Bool>,
        label: String,
        description: String,
        icon: String
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.callout)
                        .foregroundStyle(.white)
                    Text(description)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .toggleStyle(.switch)
        .tint(Color.accentOrange)
    }

    // MARK: - Format Options

    private var formatOptionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Output Format", systemImage: "doc.badge.gearshape")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)

            VStack(spacing: 12) {
                // Format picker
                Picker("Format", selection: Binding(
                    get: { outputFormat },
                    set: { settings.exportOutputFormat = $0.rawValue }
                )) {
                    ForEach(ExportFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.segmented)

                // Quality slider (for formats that support it)
                if outputFormat.supportsQuality {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("Quality")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(value: Binding(
                                get: { settings.exportJpegQuality },
                                set: { settings.exportJpegQuality = $0 }
                            ), in: 0.1...1.0, step: 0.05)
                            Text("\(Int(settings.exportJpegQuality * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 35)
                        }

                        // Quality presets
                        HStack(spacing: 8) {
                            qualityPresetButton("Low", value: 0.3)
                            qualityPresetButton("Medium", value: 0.6)
                            qualityPresetButton("High", value: 0.85)
                            qualityPresetButton("Best", value: 1.0)
                        }
                    }
                }

                // File size estimate
                if let estimate = estimatedFileSize {
                    HStack {
                        Image(systemName: "externaldrive")
                            .foregroundStyle(.secondary)
                        Text("Estimated size: \(estimate)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: 0x222222))
            )
        }
    }

    private func qualityPresetButton(_ label: String, value: Double) -> some View {
        Button(label) {
            settings.exportJpegQuality = value
        }
        .buttonStyle(.plain)
        .font(.caption2)
        .foregroundStyle(abs(settings.exportJpegQuality - value) < 0.05 ? Color.accentOrange : .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(abs(settings.exportJpegQuality - value) < 0.05 ? Color.accentOrange.opacity(0.2) : Color.clear)
        )
    }

    // MARK: - Destination

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Destination", systemImage: "folder")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)

            Button {
                selectDestination()
            } label: {
                HStack {
                    Image(systemName: "folder.badge.plus")
                        .foregroundStyle(Color.accentOrange)
                    if destinationFolder != nil {
                        Text(destinationDisplayPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("Choose destination folder...")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(hex: 0x222222))
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.1))
        )
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            // Quick actions
            Button("Select All") {
                settings.exportIncludeCaption = true
                settings.exportIncludeSource = true
                settings.exportIncludeCreator = true
                settings.exportIncludeKeywords = true
                settings.exportIncludeDate = true
                settings.exportIncludeCopyright = true
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
            .keyboardShortcut("a", modifiers: .command)

            Button("Clear All") {
                settings.exportIncludeCaption = false
                settings.exportIncludeSource = false
                settings.exportIncludeCreator = false
                settings.exportIncludeKeywords = false
                settings.exportIncludeDate = false
                settings.exportIncludeCopyright = false
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
            .keyboardShortcut("a", modifiers: [.command, .shift])

            Spacer()

            // Cancel / Export
            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.escape, modifiers: [])

            Button {
                performExport()
            } label: {
                if isExporting {
                    HStack(spacing: 6) {
                        ProgressView(value: Double(exportProgress.current), total: max(1, Double(exportProgress.total)))
                            .progressViewStyle(.linear)
                            .frame(width: 40)
                        Text("\(exportProgress.current)/\(exportProgress.total)")
                            .font(.caption.monospacedDigit())
                    }
                    .frame(width: 80)
                } else {
                    Text("Export")
                        .frame(width: 60)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentOrange)
            .disabled(!canExport || isExporting)
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(16)
    }

    // MARK: - Computed Properties

    private var canExport: Bool {
        destinationFolder != nil && hasSelectedOptions && totalFileCount > 0
    }

    // MARK: - Actions

    private func selectDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a destination folder for exported images"
        panel.prompt = "Select"

        if panel.runModal() == .OK {
            destinationFolder = panel.url
            errorMessage = nil
        }
    }

    private func performExport() {
        guard let destination = destinationFolder else { return }
        let inputs: [MediaItem]
        do {
            inputs = try context.exportItems(source: source)
            guard !inputs.isEmpty else { throw MediaTransferError.empty }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        isExporting = true
        exportProgress = (0, totalFileCount)
        errorMessage = nil

        Task {
            let injector = MetadataInjector()
            let results = await injector.exportBatch(items: inputs, to: destination, options: options) { current, total in
                Task { @MainActor in
                    exportProgress = (current, total)
                }
            }

            await MainActor.run {
                isExporting = false
                exportResults = results
                showResults = true
                onExportComplete?(results)
            }
        }
    }

    // MARK: - Helpers

    private func isImageFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "tiff", "tif", "webp", "heic", "heif"].contains(ext)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Export Results View

/// Shows export results summary
struct ExportResultsView: View {
    let results: [ExportResult]
    let onDismiss: () -> Void

    private var successCount: Int {
        results.filter(\.success).count
    }

    private var failureCount: Int {
        results.filter { !$0.success }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: failureCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(failureCount == 0 ? .green : .orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(failureCount == 0 ? "Export Complete" : "Export Complete with Errors")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("\(successCount) of \(results.count) images exported")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(16)

            Divider()
                .background(Color.white.opacity(0.1))

            // Results list
            if failureCount > 0 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Failed Exports")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.bottom, 4)

                        ForEach(results.filter { !$0.success }, id: \.sourceURL) { result in
                            HStack(spacing: 8) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(result.sourceURL.lastPathComponent)
                                        .font(.caption)
                                        .foregroundStyle(.white)
                                    if let error = result.error {
                                        Text(error.localizedDescription)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.red.opacity(0.1))
                            )
                        }
                    }
                    .padding(16)
                }
                .frame(maxHeight: 200)
            } else {
                // Success state
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("All images exported successfully")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(24)
            }

            Divider()
                .background(Color.white.opacity(0.1))

            // Footer - Show in Finder moved to right side next to Done
            HStack {
                Spacer()

                if successCount > 0, let firstSuccess = results.first(where: \.success) {
                    Button("Show in Finder") {
                        NSWorkspace.shared.selectFile(
                            firstSuccess.destinationURL.path,
                            inFileViewerRootedAtPath: firstSuccess.destinationURL.deletingLastPathComponent().path
                        )
                    }
                    .buttonStyle(.bordered)
                }

                Button("Done") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentOrange)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(16)
        }
        .frame(width: 400, height: failureCount > 0 ? 400 : 280)
        .background(Color(hex: 0x1a1a1a))
    }
}

// MARK: - Preview

#if DEBUG
struct ExportOptionsView_Previews: PreviewProvider {
    static var previews: some View {
        ExportOptionsView(items: [.preview])
            .preferredColorScheme(.dark)
    }
}
#endif
