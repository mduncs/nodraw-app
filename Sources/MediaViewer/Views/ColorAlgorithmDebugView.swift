import SwiftUI
import UniformTypeIdentifiers

// MARK: - ColorAlgorithmDebugView

/// Debug view for comparing color extraction algorithms side-by-side.
/// Shows an image and runs all 4 algorithms with timing information.
struct ColorAlgorithmDebugView: View {
    @State private var selectedImageURL: URL?
    @State private var isProcessing = false
    @State private var results: ColorExtractionResults?
    @State private var errorMessage: String?
    @State private var dragOver = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Color Algorithm Comparison")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                if isProcessing {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            .padding()
            .background(Color(hex: 0x1f1f1f))

            Divider()
                .background(Color.white.opacity(0.1))

            // Main content
            ScrollView {
                VStack(spacing: 20) {
                    // Image selection area
                    imageSelectionArea

                    // Results
                    if let results = results {
                        resultsGrid(results)
                    }

                    // Error message
                    if let error = errorMessage {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                            .padding()
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 600, minHeight: 500)
    }

    // MARK: - Image Selection Area

    private var imageSelectionArea: some View {
        VStack(spacing: 12) {
            if let url = selectedImageURL {
                // Show selected image
                HStack(spacing: 16) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 200, maxHeight: 200)
                                .cornerRadius(8)
                        case .failure:
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        case .empty:
                            ProgressView()
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .frame(width: 200, height: 200)
                    .background(Color(hex: 0x2a2a2a))
                    .cornerRadius(8)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(url.lastPathComponent)
                            .font(.callout)
                            .foregroundStyle(.white)
                            .lineLimit(2)

                        Button("Choose Different Image") {
                            chooseImage()
                        }
                        .buttonStyle(.bordered)

                        Button("Re-analyze") {
                            Task {
                                await analyzeImage(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.accentOrange)
                        .disabled(isProcessing)
                    }

                    Spacer()
                }
            } else {
                // Drop zone / file picker
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)

                    Text("Drop an image here or click to select")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Button("Choose Image") {
                        chooseImage()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentOrange)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            dragOver ? Color.accentOrange : Color.white.opacity(0.2),
                            style: StrokeStyle(lineWidth: 2, dash: [8])
                        )
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(dragOver ? Color.accentOrange.opacity(0.1) : Color.clear)
                )
                .onDrop(of: [.fileURL], isTargeted: $dragOver) { providers in
                    handleDrop(providers)
                }
            }
        }
    }

    // MARK: - Results Grid

    private func resultsGrid(_ results: ColorExtractionResults) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Results")
                .font(.headline)
                .foregroundStyle(.white)

            // Summary row
            HStack(spacing: 12) {
                summaryCard(
                    "Total Time",
                    value: String(format: "%.1f ms", results.totalTimeMs),
                    icon: "clock"
                )
                summaryCard(
                    "Fastest",
                    value: results.fastest,
                    icon: "bolt"
                )
            }

            // Algorithm results in grid
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 16),
                GridItem(.flexible(), spacing: 16)
            ], spacing: 16) {
                algorithmResultCard(results.gridSampling)
                algorithmResultCard(results.kMeans)
                algorithmResultCard(results.saturationWeighted)
                algorithmResultCard(results.multiShade)
                algorithmResultCard(results.medianCut)
            }
        }
    }

    private func summaryCard(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: 0x2a2a2a))
        )
    }

    private func algorithmResultCard(_ result: VisionProcessor.ColorExtractionResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text(result.algorithmName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                Spacer()
                Text(String(format: "%.1f ms", result.durationMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color(hex: 0x333333))
                    )
            }

            // Color swatches
            HStack(spacing: 8) {
                ForEach(Array(result.colors.enumerated()), id: \.offset) { index, color in
                    colorSwatch(color)
                }

                // Fill empty space if less than 5 colors
                if result.colors.count < 5 {
                    ForEach(result.colors.count..<5, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.clear)
                            .frame(width: 40, height: 60)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: 0x2a2a2a))
        )
    }

    private func colorSwatch(_ color: VisionProcessor.ExtractedColor) -> some View {
        VStack(spacing: 4) {
            // Color circle
            Circle()
                .fill(Color(
                    red: Double(color.r) / 255.0,
                    green: Double(color.g) / 255.0,
                    blue: Double(color.b) / 255.0
                ))
                .frame(width: 36, height: 36)
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                )

            // Bucket name
            Text(color.bucket.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            // Prominence
            Text("\(Int(color.prominence * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(width: 40)
        .help(color.hex)
    }

    // MARK: - Actions

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            selectedImageURL = url
            Task {
                await analyzeImage(url)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                return
            }

            // Verify it's an image
            guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
                  type.conforms(to: .image) else {
                DispatchQueue.main.async {
                    self.errorMessage = "Dropped file is not an image"
                }
                return
            }

            DispatchQueue.main.async {
                self.selectedImageURL = url
                Task {
                    await self.analyzeImage(url)
                }
            }
        }

        return true
    }

    private func analyzeImage(_ url: URL) async {
        isProcessing = true
        errorMessage = nil
        results = nil

        do {
            let algorithmResults = try await VisionProcessor.runAllColorAlgorithms(from: url)

            let totalTime = algorithmResults.gridSampling.durationMs +
                           algorithmResults.kMeans.durationMs +
                           algorithmResults.saturationWeighted.durationMs +
                           algorithmResults.multiShade.durationMs +
                           algorithmResults.medianCut.durationMs

            let allResults = [
                algorithmResults.gridSampling,
                algorithmResults.kMeans,
                algorithmResults.saturationWeighted,
                algorithmResults.multiShade,
                algorithmResults.medianCut
            ]
            let fastest = allResults.min(by: { $0.durationMs < $1.durationMs })?.algorithmName ?? "Unknown"

            results = ColorExtractionResults(
                gridSampling: algorithmResults.gridSampling,
                kMeans: algorithmResults.kMeans,
                saturationWeighted: algorithmResults.saturationWeighted,
                multiShade: algorithmResults.multiShade,
                medianCut: algorithmResults.medianCut,
                totalTimeMs: totalTime,
                fastest: fastest
            )
        } catch {
            errorMessage = "Analysis failed: \(error.localizedDescription)"
        }

        isProcessing = false
    }
}

// MARK: - Supporting Types

private struct ColorExtractionResults {
    let gridSampling: VisionProcessor.ColorExtractionResult
    let kMeans: VisionProcessor.ColorExtractionResult
    let saturationWeighted: VisionProcessor.ColorExtractionResult
    let multiShade: VisionProcessor.ColorExtractionResult
    let medianCut: VisionProcessor.ColorExtractionResult
    let totalTimeMs: Double
    let fastest: String
}

// MARK: - Color Extension for hex init

private extension Color {
    init(hex: UInt) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

// MARK: - Preview

#if DEBUG
struct ColorAlgorithmDebugView_Previews: PreviewProvider {
    static var previews: some View {
        ColorAlgorithmDebugView()
            .frame(width: 700, height: 600)
    }
}
#endif
