import Foundation
import Vision
import CoreImage
import AppKit
import SubjectIsolation
import PhotoPipeline

/// One-shot cancellation registration for work that does not observe Swift task cancellation.
/// Registration and cancellation may arrive in either order and from different threads.
final class VisionOperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?
    private var didRegisterHandler = false
    private var didCancel = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didCancel
    }

    func register(_ handler: @escaping () -> Void) {
        let shouldRunImmediately: Bool

        lock.lock()
        guard !didRegisterHandler else {
            lock.unlock()
            return
        }
        didRegisterHandler = true
        shouldRunImmediately = didCancel
        if !shouldRunImmediately {
            self.handler = handler
        }
        lock.unlock()

        if shouldRunImmediately {
            handler()
        }
    }

    func cancel() {
        let handler: (() -> Void)?

        lock.lock()
        guard !didCancel else {
            lock.unlock()
            return
        }
        didCancel = true
        handler = self.handler
        self.handler = nil
        lock.unlock()

        handler?()
    }
}

/// Coordinates an unstructured operation and deadline without retaining either loser.
/// Vision requests can block past cancellation, so structured task groups cannot enforce
/// a hard deadline: their scope waits for every child before returning.
private final class VisionOperationTimeoutState<Value>: @unchecked Sendable {
    private let operationCancellation: VisionOperationCancellation
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var settledResult: Result<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(operationCancellation: VisionOperationCancellation) {
        self.operationCancellation = operationCancellation
    }

    func start(
        continuation: CheckedContinuation<Value, Error>,
        seconds: TimeInterval,
        operation: @escaping () async throws -> Value
    ) {
        lock.lock()
        if let settledResult {
            lock.unlock()
            continuation.resume(with: settledResult)
            return
        }
        self.continuation = continuation
        lock.unlock()

        let operationTask = Task { [weak self] in
            do {
                let value = try await operation()
                self?.settle(with: .success(value))
            } catch {
                self?.settle(with: .failure(error))
            }
        }

        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(0, seconds)))
            } catch {
                return
            }
            self?.settle(with: .failure(VisionError.timeout), cancelOperation: true)
        }

        install(operationTask: operationTask, timeoutTask: timeoutTask)
    }

    func settle(with result: Result<Value, Error>, cancelOperation: Bool = false) {
        let continuation: CheckedContinuation<Value, Error>?
        let tasks: (Task<Void, Never>?, Task<Void, Never>?)

        lock.lock()
        guard settledResult == nil else {
            lock.unlock()
            return
        }
        settledResult = result
        continuation = self.continuation
        self.continuation = nil
        tasks = (operationTask, timeoutTask)
        operationTask = nil
        timeoutTask = nil
        lock.unlock()

        if cancelOperation {
            operationCancellation.cancel()
        }
        tasks.0?.cancel()
        tasks.1?.cancel()
        continuation?.resume(with: result)
    }

    private func install(
        operationTask: Task<Void, Never>,
        timeoutTask: Task<Void, Never>
    ) {
        lock.lock()
        if settledResult == nil {
            self.operationTask = operationTask
            self.timeoutTask = timeoutTask
            lock.unlock()
            return
        }
        lock.unlock()

        // A very fast operation, deadline, or parent cancellation may settle before
        // both task handles are installed. Cancel them after the fact in that race.
        operationTask.cancel()
        timeoutTask.cancel()
    }
}

// MARK: - Vision Processor

/// Handles the actual Vision framework operations for extracting content from images.
/// All operations run on background threads and handle corrupted/missing files gracefully.
struct VisionProcessor: Sendable {

    /// Timeout for Vision operations (30 seconds)
    private static let operationTimeout: TimeInterval = 30.0

    /// Maximum image dimension for OCR (larger images are downsampled)
    private static let maxOCRDimension: CGFloat = 2048.0

    /// Reused CI resources for color extraction and blur rendering.
    /// CIContext creation is expensive, so keep shared instances.
    private static let sharedRGBColorSpace = CGColorSpaceCreateDeviceRGB()
    private static let sharedColorRenderContext = CIContext(options: [.workingColorSpace: sharedRGBColorSpace])
    private static let sharedDefaultCIContext = CIContext(options: nil)

    // MARK: - OCR Text Extraction

    /// Result of OCR extraction including text and paragraph-grouped blocks
    struct OCRResult: Sendable {
        let text: String?
        let blocks: [TextBlock]
    }

    // MARK: - Extracted Color

    /// Color extraction result with actual RGB values and bucket classification
    /// Used for precision color search with tolerance
    struct ExtractedColor: Sendable, Codable, Equatable {
        let bucket: ColorBucket
        let r: UInt8
        let g: UInt8
        let b: UInt8
        let prominence: Double  // 0.0-1.0, how much of image is this color

        /// Hex color string (e.g., "#FF4488")
        var hex: String {
            String(format: "#%02X%02X%02X", r, g, b)
        }

        /// Integer RGB values for database queries
        var rgbInt: (r: Int, g: Int, b: Int) {
            (Int(r), Int(g), Int(b))
        }
    }

    /// Extract text from an image using VNRecognizeTextRequest
    /// - Parameter url: Path to image file
    /// - Returns: Recognized text or nil if no text found
    static func extractOCR(from url: URL) async throws -> String? {
        let result = try await extractOCRWithRegions(from: url)
        return result.text
    }

    /// Extract text and paragraph-grouped blocks from an image using VNRecognizeTextRequest
    /// and TextLayoutAnalyzer for spatial grouping.
    /// - Parameter url: Path to image file
    /// - Returns: OCRResult containing paragraph-structured text and TextBlocks
    static func extractOCRWithRegions(from url: URL) async throws -> OCRResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VisionError.fileNotFound(url)
        }

        return try await withTimeout(seconds: operationTimeout) { cancellation in
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let request = VNRecognizeTextRequest()
                    cancellation.register {
                        request.cancel()
                    }

                    guard !cancellation.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    do {
                        // Load and optionally downsample image
                        guard let cgImage = loadImage(from: url, maxDimension: maxOCRDimension) else {
                            continuation.resume(returning: OCRResult(text: nil, blocks: []))
                            return
                        }

                        request.recognitionLevel = .accurate
                        request.usesLanguageCorrection = true

                        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                        try handler.perform([request])

                        guard let observations = request.results else {
                            continuation.resume(returning: OCRResult(text: nil, blocks: []))
                            return
                        }

                        // Map Vision observations to PhotoPipeline.TextObservation for the layout analyzer
                        let textObservations: [PhotoPipeline.TextObservation] = observations.compactMap { obs in
                            guard let candidate = obs.topCandidates(1).first else { return nil }
                            return PhotoPipeline.TextObservation(
                                text: candidate.string,
                                boundingBox: obs.boundingBox,
                                confidence: candidate.confidence
                            )
                        }

                        // Strip social metadata while the raw spatial relationships are still
                        // available. Vision may split a display name from the handle/timestamp
                        // beside it, and the quality filter rejects that marker observation.
                        let cleaned = sanitizeSocialMetadataNoise(textObservations)

                        // Filter out noise/garbage text (texture patterns, bokeh, wood grain etc.)
                        let qualityFilter = OCRQualityFilter(
                            minimumConfidence: 0.25,
                            minimumLength: 2,
                            maximumSymbolRatio: 0.35,
                            minimumWordRatio: 0.3
                        )
                        let filtered = qualityFilter.apply(cleaned)

                        // Group into paragraphs using TextLayoutAnalyzer
                        let analyzer = TextLayoutAnalyzer()
                        let blocks = OCRParagraphGrouper.group(filtered, analyzer: analyzer)

                        // Build paragraph-structured text (blocks separated by double newlines)
                        let text = blocks.map(\.text).joined(separator: "\n\n")
                            .trimmingCharacters(in: .whitespacesAndNewlines)

                        continuation.resume(returning: OCRResult(
                            text: text.isEmpty ? nil : text,
                            blocks: blocks
                        ))
                    } catch {
                        continuation.resume(throwing: VisionError.ocrFailed(url, error))
                    }
                }
            }
        }
    }

    /// Strip common social-feed metadata noise from OCR lines while preserving content text.
    /// Examples removed: handles/timestamps/badges like "@user", "[+3]", "7h", and icon artifacts.
    /// Internal so the spatial policy can be covered without invoking Vision.
    static func sanitizeSocialMetadataNoise(_ observations: [PhotoPipeline.TextObservation]) -> [PhotoPipeline.TextObservation] {
        // First locate short display names that Vision emitted separately, immediately to
        // the left of a strong handle + badge/timestamp marker on the same visual row.
        // This must happen before line cleanup removes the marker observation.
        var splitDisplayNameIndices = Set<Int>()
        for markerIndex in observations.indices where isStrongSocialHeaderMarker(observations[markerIndex].text) {
            let markerBounds = observations[markerIndex].boundingBox
            let nearestDisplayNameIndex = observations.indices
                .filter { index in
                    index != markerIndex
                        && isLikelyDisplayName(observations[index].text)
                        && isImmediatelyLeftOnSameRow(
                            observations[index].boundingBox,
                            of: markerBounds
                        )
                }
                .min { lhs, rhs in
                    let lhsGap = markerBounds.minX - observations[lhs].boundingBox.maxX
                    let rhsGap = markerBounds.minX - observations[rhs].boundingBox.maxX
                    return lhsGap < rhsGap
                }

            if let nearestDisplayNameIndex {
                splitDisplayNameIndices.insert(nearestDisplayNameIndex)
            }
        }

        return observations.indices.compactMap { index in
            guard !splitDisplayNameIndices.contains(index) else { return nil }
            let obs = observations[index]
            let original = obs.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !original.isEmpty else { return nil }
            guard let cleaned = sanitizeSocialMetadataLine(original) else { return nil }
            if cleaned == original {
                return obs
            }
            return PhotoPipeline.TextObservation(
                text: cleaned,
                boundingBox: obs.boundingBox,
                confidence: obs.confidence,
                language: obs.language
            )
        }
    }

    private static func isStrongSocialHeaderMarker(_ text: String) -> Bool {
        let hasHandle = regexContains(#"@[A-Za-z0-9_.]+"#, in: text)
        let hasBadge = text.contains("[+") || regexContains(#"\[\+\d+\]?"#, in: text)
        let hasRelativeTime = regexContains(#"\b\d+\s*[smhdwy]\b"#, in: text)
        return hasHandle && (hasBadge || hasRelativeTime)
    }

    private static func isLikelyDisplayName(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard (1...3).contains(words.count) else { return false }

        let allowedPunctuation = CharacterSet(charactersIn: "-'\u{2019}.")
        return trimmed.unicodeScalars.allSatisfy {
            CharacterSet.letters.contains($0)
                || CharacterSet.whitespaces.contains($0)
                || allowedPunctuation.contains($0)
        }
    }

    private static func isImmediatelyLeftOnSameRow(_ candidate: CGRect, of marker: CGRect) -> Bool {
        guard candidate.height > 0, marker.height > 0, candidate.midX < marker.midX else {
            return false
        }

        let verticalOverlap = max(0, min(candidate.maxY, marker.maxY) - max(candidate.minY, marker.minY))
        let overlapRatio = verticalOverlap / min(candidate.height, marker.height)
        let heightRatio = min(candidate.height, marker.height) / max(candidate.height, marker.height)
        guard overlapRatio >= 0.65, heightRatio >= 0.6 else { return false }

        let horizontalGap = marker.minX - candidate.maxX
        let maximumGap = max(0.06, max(candidate.height, marker.height) * 1.5)
        return horizontalGap >= -0.01 && horizontalGap <= maximumGap
    }

    /// Returns cleaned line text, or nil if the line looks like pure social metadata.
    private static func sanitizeSocialMetadataLine(_ text: String) -> String? {
        var working = text
        let hadHandle = regexContains(#"@[A-Za-z0-9_.]+"#, in: text)
        let hadBadge = text.contains("[+") || regexContains(#"\[\+\d+\]?"#, in: text)
        let hadRelativeTime = regexContains(#"\b\d+\s*[smhdwy]\b"#, in: text)
        let hadEngagementMetric = regexContains(#"\b\d+(\.\d+)?[KMB]\b"#, in: text)
        let hadIconArtifacts = text.contains("©") || text.contains("•") || text.contains("O*")
        let hadSocialMarker = hadHandle || hadBadge || hadRelativeTime || hadEngagementMetric || hadIconArtifacts

        // If a timestamp marker exists, drop the whole metadata prefix up to and including it.
        // This preserves trailing content when OCR merges header + post text on one line.
        if hadRelativeTime {
            working = regexReplacingFirst(#"^.*?\b\d+\s*[smhdwy]\b\s*"#, in: working, with: "")
        }

        if hadSocialMarker {
            working = regexReplacing(#"@[A-Za-z0-9_.]+"#, in: working, with: " ")
            working = regexReplacing(#"\[\+\d+\]?"#, in: working, with: " ")
            working = regexReplacing(#"\b\d+\s*[smhdwy]\b"#, in: working, with: " ")
            working = regexReplacing(#"\b\d+(\.\d+)?[KMB]\b"#, in: working, with: " ")
            working = working.replacingOccurrences(of: "©", with: " ")
            working = working.replacingOccurrences(of: "•", with: " ")
            working = working.replacingOccurrences(of: "O*", with: " ")
            working = regexReplacing(#"\s*[()]+\s*"#, in: working, with: " ")
            working = regexReplacing(#"\s*\*\s*"#, in: working, with: " ")
        }

        working = regexReplacing(#"\s+"#, in: working, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-–—•|:;.,()[]{}<>*"))

        guard !working.isEmpty else { return nil }

        // Drop short metadata leftovers (e.g. "Samuel James", "nicole ruiz", "ill").
        if hadSocialMarker {
            let words = working.split(whereSeparator: \.isWhitespace)
            let hasSentencePunctuation = working.contains { ".!?".contains($0) }
            if !hasSentencePunctuation && words.count <= 2 {
                return nil
            }

            if hadEngagementMetric {
                let lettersOnly = working.filter { $0.isLetter }
                if lettersOnly.count <= 4 && words.count <= 2 {
                    return nil
                }
            }
        }

        return working
    }

    private static func regexContains(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func regexReplacing(_ pattern: String, in text: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    private static func regexReplacingFirst(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let range = text.range(of: pattern, options: .regularExpression) else { return text }
        var updated = text
        updated.replaceSubrange(range, with: replacement)
        return updated
    }

    // MARK: - Dominant Color Extraction

    /// Extract dominant colors with actual RGB values for precision color search
    /// - Parameter url: Path to image file
    /// - Returns: Array of ExtractedColor with bucket classification, RGB values, and prominence
    static func extractDominantColors(from url: URL) async throws -> [ExtractedColor] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VisionError.fileNotFound(url)
        }

        return try await withTimeout(seconds: operationTimeout) {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    guard let cgImage = loadImage(from: url, maxDimension: 256) else {
                        continuation.resume(returning: [ExtractedColor(bucket: .gray, r: 128, g: 128, b: 128, prominence: 1.0)])
                        return
                    }

                    // Analyze colors by sampling the original image
                    let colors = classifyImageColors(cgImage: cgImage)
                    continuation.resume(returning: colors)
                }
            }
        }
    }

    /// Legacy method for backward compatibility - returns just buckets
    static func extractDominantColorBuckets(from url: URL) async throws -> [ColorBucket] {
        let colors = try await extractDominantColors(from: url)
        return colors.map(\.bucket)
    }

    /// Classify image colors by sampling pixels, returning actual RGB values and bucket classification
    private static func classifyImageColors(cgImage: CGImage) -> [ExtractedColor] {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else {
            return [ExtractedColor(bucket: .gray, r: 128, g: 128, b: 128, prominence: 1.0)]
        }

        // Use CIContext to render to a known RGBA format (handles all color space/byte order issues)
        let ciImage = CIImage(cgImage: cgImage)
        let context = sharedColorRenderContext

        // Render to RGBA bitmap (always 4 bytes per pixel in RGBA order)
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        context.render(
            ciImage,
            toBitmap: &pixelData,
            rowBytes: bytesPerRow,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8,
            colorSpace: sharedRGBColorSpace
        )

        // Track both bucket counts AND RGB sums for averaging
        var bucketCounts: [ColorBucket: Int] = [:]
        var bucketRGBSums: [ColorBucket: (r: Int, g: Int, b: Int)] = [:]
        for bucket in ColorBucket.allCases {
            bucketCounts[bucket] = 0
            bucketRGBSums[bucket] = (0, 0, 0)
        }

        // Sample pixels in a grid
        let sampleStep = max(1, min(width, height) / 20)
        var sampleCount = 0

        for y in stride(from: 0, to: height, by: sampleStep) {
            for x in stride(from: 0, to: width, by: sampleStep) {
                let offset = y * bytesPerRow + x * bytesPerPixel

                // RGBA format - guaranteed by CIContext.render with .RGBA8
                let rByte = pixelData[offset]
                let gByte = pixelData[offset + 1]
                let bByte = pixelData[offset + 2]

                let r = Double(rByte) / 255.0
                let g = Double(gByte) / 255.0
                let b = Double(bByte) / 255.0

                let bucket = classifyRGB(r: r, g: g, b: b)
                bucketCounts[bucket, default: 0] += 1

                // Accumulate actual RGB values for averaging
                var current = bucketRGBSums[bucket] ?? (0, 0, 0)
                current.r += Int(rByte)
                current.g += Int(gByte)
                current.b += Int(bByte)
                bucketRGBSums[bucket] = current

                sampleCount += 1
            }
        }

        guard sampleCount > 0 else {
            return [ExtractedColor(bucket: .gray, r: 128, g: 128, b: 128, prominence: 1.0)]
        }

        // Get top 3 buckets by count (no minimum threshold to ensure we always get colors)
        let sortedBuckets = bucketCounts
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .prefix(3)

        // Build ExtractedColor array with average RGB per bucket
        var result: [ExtractedColor] = []
        for (bucket, count) in sortedBuckets {
            let sums = bucketRGBSums[bucket] ?? (0, 0, 0)
            let avgR = UInt8(sums.r / count)
            let avgG = UInt8(sums.g / count)
            let avgB = UInt8(sums.b / count)
            let prominence = Double(count) / Double(sampleCount)

            result.append(ExtractedColor(
                bucket: bucket,
                r: avgR,
                g: avgG,
                b: avgB,
                prominence: prominence
            ))
        }

        // Ensure at least one color
        if result.isEmpty {
            result.append(ExtractedColor(bucket: .gray, r: 128, g: 128, b: 128, prominence: 1.0))
        }

        return result
    }

    // MARK: - Alternative Color Extraction Algorithms

    /// Result type for debug color extraction with timing
    struct ColorExtractionResult: Sendable {
        let colors: [ExtractedColor]
        let durationMs: Double
        let algorithmName: String
    }

    /// Extract colors using K-means clustering (k=5)
    /// Returns actual cluster centroids as RGB colors with cluster size as prominence
    static func extractDominantColorsKMeans(from url: URL) async throws -> [ExtractedColor] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VisionError.fileNotFound(url)
        }

        return try await withTimeout(seconds: operationTimeout) {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    guard let cgImage = loadImage(from: url, maxDimension: 256) else {
                        continuation.resume(returning: [ExtractedColor(bucket: .gray, r: 128, g: 128, b: 128, prominence: 1.0)])
                        return
                    }

                    let colors = classifyImageColorsKMeans(cgImage: cgImage, k: 5)
                    continuation.resume(returning: colors)
                }
            }
        }
    }

    /// K-means clustering implementation for color extraction
    private static func classifyImageColorsKMeans(cgImage: CGImage, k: Int) -> [ExtractedColor] {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else {
            return [ExtractedColor(bucket: .gray, r: 128, g: 128, b: 128, prominence: 1.0)]
        }

        // Get pixel data
        let ciImage = CIImage(cgImage: cgImage)
        let context = sharedColorRenderContext
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        context.render(
            ciImage,
            toBitmap: &pixelData,
            rowBytes: bytesPerRow,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8,
            colorSpace: sharedRGBColorSpace
        )

        // Sample pixels into RGB tuples
        let sampleStep = max(1, min(width, height) / 32)
        var samples: [(r: Double, g: Double, b: Double)] = []

        for y in stride(from: 0, to: height, by: sampleStep) {
            for x in stride(from: 0, to: width, by: sampleStep) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = Double(pixelData[offset]) / 255.0
                let g = Double(pixelData[offset + 1]) / 255.0
                let b = Double(pixelData[offset + 2]) / 255.0
                samples.append((r, g, b))
            }
        }

        guard !samples.isEmpty else {
            return [ExtractedColor(bucket: .gray, r: 128, g: 128, b: 128, prominence: 1.0)]
        }

        // Initialize centroids by picking k evenly-spaced samples
        var centroids: [(r: Double, g: Double, b: Double)] = []
        let step = max(1, samples.count / k)
        for i in 0..<k {
            let idx = min(i * step, samples.count - 1)
            centroids.append(samples[idx])
        }

        // K-means iterations (max 10)
        var assignments = [Int](repeating: 0, count: samples.count)
        for _ in 0..<10 {
            // Assign samples to nearest centroid
            for (i, sample) in samples.enumerated() {
                var bestDist = Double.infinity
                var bestIdx = 0
                for (j, centroid) in centroids.enumerated() {
                    let dist = pow(sample.r - centroid.r, 2) + pow(sample.g - centroid.g, 2) + pow(sample.b - centroid.b, 2)
                    if dist < bestDist {
                        bestDist = dist
                        bestIdx = j
                    }
                }
                assignments[i] = bestIdx
            }

            // Update centroids
            var sums = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: k)
            var counts = [Int](repeating: 0, count: k)

            for (i, sample) in samples.enumerated() {
                let cluster = assignments[i]
                sums[cluster].r += sample.r
                sums[cluster].g += sample.g
                sums[cluster].b += sample.b
                counts[cluster] += 1
            }

            for j in 0..<k {
                if counts[j] > 0 {
                    centroids[j] = (
                        r: sums[j].r / Double(counts[j]),
                        g: sums[j].g / Double(counts[j]),
                        b: sums[j].b / Double(counts[j])
                    )
                }
            }
        }

        // Count final cluster assignments
        var clusterCounts = [Int](repeating: 0, count: k)
        for cluster in assignments {
            clusterCounts[cluster] += 1
        }

        // Build results sorted by cluster size
        var results: [(centroid: (r: Double, g: Double, b: Double), count: Int)] = []
        for (i, centroid) in centroids.enumerated() {
            if clusterCounts[i] > 0 {
                results.append((centroid, clusterCounts[i]))
            }
        }
        results.sort { $0.count > $1.count }

        // Convert to ExtractedColor
        let totalSamples = samples.count
        return results.prefix(5).map { item in
            let r = UInt8(min(255, max(0, item.centroid.r * 255)))
            let g = UInt8(min(255, max(0, item.centroid.g * 255)))
            let b = UInt8(min(255, max(0, item.centroid.b * 255)))
            let bucket = classifyRGB(r: item.centroid.r, g: item.centroid.g, b: item.centroid.b)
            let prominence = Double(item.count) / Double(totalSamples)
            return ExtractedColor(bucket: bucket, r: r, g: g, b: b, prominence: prominence)
        }
    }

    /// Extract colors using saturation-weighted buckets
    /// Weights pixels by saturation, ignores low-saturation (gray) pixels
    static func extractDominantColorsSaturationWeighted(from url: URL) async throws -> [ExtractedColor] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VisionError.fileNotFound(url)
        }

        return try await withTimeout(seconds: operationTimeout) {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    guard let cgImage = loadImage(from: url, maxDimension: 256) else {
                        continuation.resume(returning: [ExtractedColor(bucket: .gray, r: 128, g: 128, b: 128, prominence: 1.0)])
                        return
                    }

                    let colors = classifyImageColorsSaturationWeighted(cgImage: cgImage)
                    continuation.resume(returning: colors)
                }
            }
        }
    }

    /// Saturation-weighted bucket classification
    private static func classifyImageColorsSaturationWeighted(cgImage: CGImage) -> [ExtractedColor] {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else {
            return [ExtractedColor(bucket: .gray, r: 128, g: 128, b: 128, prominence: 1.0)]
        }

        let ciImage = CIImage(cgImage: cgImage)
        let context = sharedColorRenderContext
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        context.render(
            ciImage,
            toBitmap: &pixelData,
            rowBytes: bytesPerRow,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8,
            colorSpace: sharedRGBColorSpace
        )

        // Track weighted bucket scores and weighted RGB sums
        var bucketWeights: [ColorBucket: Double] = [:]
        var bucketRGBSums: [ColorBucket: (r: Double, g: Double, b: Double)] = [:]
        for bucket in ColorBucket.allCases {
            bucketWeights[bucket] = 0
            bucketRGBSums[bucket] = (0, 0, 0)
        }

        let sampleStep = max(1, min(width, height) / 20)
        var totalWeight: Double = 0
        let minSaturation: Double = 0.15

        for y in stride(from: 0, to: height, by: sampleStep) {
            for x in stride(from: 0, to: width, by: sampleStep) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let rByte = pixelData[offset]
                let gByte = pixelData[offset + 1]
                let bByte = pixelData[offset + 2]

                let r = Double(rByte) / 255.0
                let g = Double(gByte) / 255.0
                let b = Double(bByte) / 255.0

                // Calculate saturation
                let maxC = max(r, g, b)
                let minC = min(r, g, b)
                let saturation = maxC > 0 ? (maxC - minC) / maxC : 0

                // Skip low-saturation (gray) pixels
                guard saturation >= minSaturation else { continue }

                let weight = saturation  // Weight by saturation
                let bucket = classifyRGB(r: r, g: g, b: b)

                bucketWeights[bucket, default: 0] += weight

                var current = bucketRGBSums[bucket] ?? (0, 0, 0)
                current.r += Double(rByte) * weight
                current.g += Double(gByte) * weight
                current.b += Double(bByte) * weight
                bucketRGBSums[bucket] = current

                totalWeight += weight
            }
        }

        guard totalWeight > 0 else {
            // No chromatic pixels found, return gray
            return [ExtractedColor(bucket: .gray, r: 128, g: 128, b: 128, prominence: 1.0)]
        }

        // Get top 3 buckets by weight
        let sortedBuckets = bucketWeights
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .prefix(3)

        var result: [ExtractedColor] = []
        for (bucket, weight) in sortedBuckets {
            let sums = bucketRGBSums[bucket] ?? (0, 0, 0)
            let avgR = UInt8(min(255, max(0, sums.r / weight)))
            let avgG = UInt8(min(255, max(0, sums.g / weight)))
            let avgB = UInt8(min(255, max(0, sums.b / weight)))
            let prominence = weight / totalWeight

            result.append(ExtractedColor(
                bucket: bucket,
                r: avgR,
                g: avgG,
                b: avgB,
                prominence: prominence
            ))
        }

        if result.isEmpty {
            result.append(ExtractedColor(bucket: .gray, r: 128, g: 128, b: 128, prominence: 1.0))
        }

        return result
    }

    // MARK: - Median Cut Color Extraction

    /// Extract colors using Median Cut algorithm (8 palette colors)
    static func extractDominantColorsMedianCut(from url: URL) async throws -> [ExtractedColor] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VisionError.fileNotFound(url)
        }

        return try await withTimeout(seconds: operationTimeout) {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    guard let cgImage = loadImage(from: url, maxDimension: 256) else {
                        continuation.resume(returning: [ExtractedColor(bucket: .gray, r: 128, g: 128, b: 128, prominence: 1.0)])
                        return
                    }
                    let colors = medianCutPalette(cgImage: cgImage, paletteSize: 8)
                    continuation.resume(returning: colors)
                }
            }
        }
    }

    /// Median Cut implementation
    private static func medianCutPalette(cgImage: CGImage, paletteSize: Int) -> [ExtractedColor] {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else {
            return [ExtractedColor(bucket: .gray, r: 128, g: 128, b: 128, prominence: 1.0)]
        }

        // Get pixel data
        let ciImage = CIImage(cgImage: cgImage)
        let context = sharedColorRenderContext
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        context.render(ciImage, toBitmap: &pixelData, rowBytes: bytesPerRow,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       format: .RGBA8, colorSpace: sharedRGBColorSpace)

        // Sample ~10k pixels
        let targetSamples = 10000
        let totalPixels = width * height
        let step = max(1, totalPixels / targetSamples)

        typealias RGB = (r: UInt8, g: UInt8, b: UInt8)
        var samples: [RGB] = []
        samples.reserveCapacity(min(targetSamples, totalPixels))

        var pixelIndex = 0
        while pixelIndex < totalPixels {
            let x = pixelIndex % width
            let y = pixelIndex / width
            let offset = y * bytesPerRow + x * bytesPerPixel
            samples.append((pixelData[offset], pixelData[offset + 1], pixelData[offset + 2]))
            pixelIndex += step
        }

        guard !samples.isEmpty else {
            return [ExtractedColor(bucket: .gray, r: 128, g: 128, b: 128, prominence: 1.0)]
        }

        // Median cut box
        struct Box {
            var pixels: [RGB]

            var rangeR: UInt8 { (pixels.map(\.r).max() ?? 0) &- (pixels.map(\.r).min() ?? 0) }
            var rangeG: UInt8 { (pixels.map(\.g).max() ?? 0) &- (pixels.map(\.g).min() ?? 0) }
            var rangeB: UInt8 { (pixels.map(\.b).max() ?? 0) &- (pixels.map(\.b).min() ?? 0) }

            var widestAxis: Int { // 0=R, 1=G, 2=B
                let ranges = [rangeR, rangeG, rangeB]
                return ranges.firstIndex(of: ranges.max()!) ?? 0
            }

            func split() -> (Box, Box) {
                var sorted = pixels
                switch widestAxis {
                case 0: sorted.sort { $0.r < $1.r }
                case 1: sorted.sort { $0.g < $1.g }
                default: sorted.sort { $0.b < $1.b }
                }
                let mid = sorted.count / 2
                return (Box(pixels: Array(sorted[..<mid])), Box(pixels: Array(sorted[mid...])))
            }

            var averageColor: RGB {
                guard !pixels.isEmpty else { return (128, 128, 128) }
                var rSum = 0, gSum = 0, bSum = 0
                for p in pixels {
                    rSum += Int(p.r); gSum += Int(p.g); bSum += Int(p.b)
                }
                let count = pixels.count
                return (UInt8(rSum / count), UInt8(gSum / count), UInt8(bSum / count))
            }
        }

        var boxes = [Box(pixels: samples)]

        while boxes.count < paletteSize {
            // Find box with most pixels to split
            guard let maxIdx = boxes.enumerated()
                .filter({ $0.element.pixels.count > 1 })
                .max(by: { $0.element.pixels.count < $1.element.pixels.count })?
                .offset else {
                break
            }
            let box = boxes.remove(at: maxIdx)
            let (a, b) = box.split()
            boxes.append(a)
            boxes.append(b)
        }

        // Convert to ExtractedColor, sorted by box size
        let totalSamples = samples.count
        let sorted = boxes.sorted { $0.pixels.count > $1.pixels.count }

        return sorted.prefix(8).map { box in
            let avg = box.averageColor
            let bucket = classifyRGB(r: Double(avg.r) / 255.0, g: Double(avg.g) / 255.0, b: Double(avg.b) / 255.0)
            let prominence = Double(box.pixels.count) / Double(totalSamples)
            return ExtractedColor(bucket: bucket, r: avg.r, g: avg.g, b: avg.b, prominence: prominence)
        }
    }

    /// Multi-shade bucket for color extraction result
    struct MultiShadeBucket: Hashable, Sendable {
        let bucket: ColorBucket
        let shade: Shade

        enum Shade: String, CaseIterable, Sendable {
            case light
            case medium
            case dark

            var displayName: String {
                rawValue.capitalized
            }
        }

        var displayName: String {
            "\(shade.displayName) \(bucket.displayName)"
        }
    }

    /// Result with multi-shade bucket information
    struct MultiShadeExtractedColor: Sendable {
        let multiShadeBucket: MultiShadeBucket
        let r: UInt8
        let g: UInt8
        let b: UInt8
        let prominence: Double

        /// Convert to standard ExtractedColor (loses shade info)
        func toExtractedColor() -> ExtractedColor {
            ExtractedColor(
                bucket: multiShadeBucket.bucket,
                r: r,
                g: g,
                b: b,
                prominence: prominence
            )
        }
    }

    /// Extract colors using multi-shade buckets (light/medium/dark variants)
    static func extractDominantColorsMultiShade(from url: URL) async throws -> [MultiShadeExtractedColor] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VisionError.fileNotFound(url)
        }

        return try await withTimeout(seconds: operationTimeout) {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    guard let cgImage = loadImage(from: url, maxDimension: 256) else {
                        let gray = MultiShadeBucket(bucket: .gray, shade: .medium)
                        continuation.resume(returning: [MultiShadeExtractedColor(multiShadeBucket: gray, r: 128, g: 128, b: 128, prominence: 1.0)])
                        return
                    }

                    let colors = classifyImageColorsMultiShade(cgImage: cgImage)
                    continuation.resume(returning: colors)
                }
            }
        }
    }

    /// Multi-shade bucket classification
    private static func classifyImageColorsMultiShade(cgImage: CGImage) -> [MultiShadeExtractedColor] {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else {
            let gray = MultiShadeBucket(bucket: .gray, shade: .medium)
            return [MultiShadeExtractedColor(multiShadeBucket: gray, r: 128, g: 128, b: 128, prominence: 1.0)]
        }

        let ciImage = CIImage(cgImage: cgImage)
        let context = sharedColorRenderContext
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        context.render(
            ciImage,
            toBitmap: &pixelData,
            rowBytes: bytesPerRow,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8,
            colorSpace: sharedRGBColorSpace
        )

        // Track multi-shade bucket counts and RGB sums
        var bucketCounts: [MultiShadeBucket: Int] = [:]
        var bucketRGBSums: [MultiShadeBucket: (r: Int, g: Int, b: Int)] = [:]

        let sampleStep = max(1, min(width, height) / 20)
        var sampleCount = 0

        for y in stride(from: 0, to: height, by: sampleStep) {
            for x in stride(from: 0, to: width, by: sampleStep) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let rByte = pixelData[offset]
                let gByte = pixelData[offset + 1]
                let bByte = pixelData[offset + 2]

                let r = Double(rByte) / 255.0
                let g = Double(gByte) / 255.0
                let b = Double(bByte) / 255.0

                // Get base bucket and shade
                let baseBucket = classifyRGB(r: r, g: g, b: b)
                let value = max(r, g, b)
                let shade: MultiShadeBucket.Shade
                if value < 0.33 {
                    shade = .dark
                } else if value < 0.66 {
                    shade = .medium
                } else {
                    shade = .light
                }

                let multiShade = MultiShadeBucket(bucket: baseBucket, shade: shade)
                bucketCounts[multiShade, default: 0] += 1

                var current = bucketRGBSums[multiShade] ?? (0, 0, 0)
                current.r += Int(rByte)
                current.g += Int(gByte)
                current.b += Int(bByte)
                bucketRGBSums[multiShade] = current

                sampleCount += 1
            }
        }

        guard sampleCount > 0 else {
            let gray = MultiShadeBucket(bucket: .gray, shade: .medium)
            return [MultiShadeExtractedColor(multiShadeBucket: gray, r: 128, g: 128, b: 128, prominence: 1.0)]
        }

        // Get top 5 multi-shade buckets by count
        let sortedBuckets = bucketCounts
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .prefix(5)

        var result: [MultiShadeExtractedColor] = []
        for (bucket, count) in sortedBuckets {
            let sums = bucketRGBSums[bucket] ?? (0, 0, 0)
            let avgR = UInt8(sums.r / count)
            let avgG = UInt8(sums.g / count)
            let avgB = UInt8(sums.b / count)
            let prominence = Double(count) / Double(sampleCount)

            result.append(MultiShadeExtractedColor(
                multiShadeBucket: bucket,
                r: avgR,
                g: avgG,
                b: avgB,
                prominence: prominence
            ))
        }

        if result.isEmpty {
            let gray = MultiShadeBucket(bucket: .gray, shade: .medium)
            result.append(MultiShadeExtractedColor(multiShadeBucket: gray, r: 128, g: 128, b: 128, prominence: 1.0))
        }

        return result
    }

    // MARK: - Debug: Run All Algorithms

    /// Run all color extraction algorithms and return timing results
    /// Used by ColorAlgorithmDebugView for comparison
    static func runAllColorAlgorithms(from url: URL) async throws -> (
        gridSampling: ColorExtractionResult,
        kMeans: ColorExtractionResult,
        saturationWeighted: ColorExtractionResult,
        multiShade: ColorExtractionResult,
        medianCut: ColorExtractionResult
    ) {
        // Grid sampling (original)
        let startGrid = CFAbsoluteTimeGetCurrent()
        let gridColors = try await extractDominantColors(from: url)
        let gridTime = (CFAbsoluteTimeGetCurrent() - startGrid) * 1000

        // K-means
        let startKMeans = CFAbsoluteTimeGetCurrent()
        let kMeansColors = try await extractDominantColorsKMeans(from: url)
        let kMeansTime = (CFAbsoluteTimeGetCurrent() - startKMeans) * 1000

        // Saturation-weighted
        let startSat = CFAbsoluteTimeGetCurrent()
        let satColors = try await extractDominantColorsSaturationWeighted(from: url)
        let satTime = (CFAbsoluteTimeGetCurrent() - startSat) * 1000

        // Multi-shade
        let startMulti = CFAbsoluteTimeGetCurrent()
        let multiShadeColors = try await extractDominantColorsMultiShade(from: url)
        let multiTime = (CFAbsoluteTimeGetCurrent() - startMulti) * 1000

        // Median Cut
        let startMedian = CFAbsoluteTimeGetCurrent()
        let medianCutColors = try await extractDominantColorsMedianCut(from: url)
        let medianTime = (CFAbsoluteTimeGetCurrent() - startMedian) * 1000

        // Convert multi-shade to ExtractedColor for consistent display
        let multiShadeConverted = multiShadeColors.map { $0.toExtractedColor() }

        return (
            gridSampling: ColorExtractionResult(colors: gridColors, durationMs: gridTime, algorithmName: "Grid Sampling"),
            kMeans: ColorExtractionResult(colors: kMeansColors, durationMs: kMeansTime, algorithmName: "K-Means (k=5)"),
            saturationWeighted: ColorExtractionResult(colors: satColors, durationMs: satTime, algorithmName: "Saturation Weighted"),
            multiShade: ColorExtractionResult(colors: multiShadeConverted, durationMs: multiTime, algorithmName: "Multi-Shade Buckets"),
            medianCut: ColorExtractionResult(colors: medianCutColors, durationMs: medianTime, algorithmName: "Median Cut (8)")
        )
    }

    /// Classify a single RGB color into a specific color bucket
    private static func classifyRGB(r: Double, g: Double, b: Double) -> ColorBucket {
        // Calculate HSV
        let maxC = max(r, g, b)
        let delta = maxC - min(r, g, b)

        let value = maxC
        let saturation = maxC > 0 ? delta / maxC : 0

        // Very dark = black
        if value < 0.15 {
            return .black
        }

        // Very light and low saturation = white
        if value > 0.85 && saturation < 0.15 {
            return .white
        }

        // Low saturation = gray (or brown if warm-ish and mid-value)
        if saturation < 0.20 {
            // Check for brown (desaturated orange/yellow range with medium value)
            if value > 0.2 && value < 0.6 {
                let hue = calculateHue(r: r, g: g, b: b, maxC: maxC, delta: delta)
                if hue >= 15 && hue <= 50 {
                    return .brown
                }
            }
            return .gray
        }

        // Calculate hue (0-360)
        let hue = calculateHue(r: r, g: g, b: b, maxC: maxC, delta: delta)

        // Classify by hue ranges
        // Red: 0-15, 345-360
        // Orange: 15-45
        // Yellow: 45-70
        // Green: 70-165
        // Cyan: 165-195
        // Blue: 195-260
        // Purple: 260-290
        // Pink: 290-345 (also includes high-saturation reds with high value)

        // Special case: pink is desaturated red/magenta with high value
        if (hue >= 330 || hue <= 15) && value > 0.7 && saturation < 0.6 {
            return .pink
        }

        // Brown detection: low-saturation orange/yellow with lower value
        if hue >= 15 && hue <= 50 && value < 0.6 && saturation < 0.7 {
            return .brown
        }

        if hue >= 345 || hue < 15 {
            return .red
        } else if hue >= 15 && hue < 45 {
            return .orange
        } else if hue >= 45 && hue < 70 {
            return .yellow
        } else if hue >= 70 && hue < 165 {
            return .green
        } else if hue >= 165 && hue < 195 {
            return .cyan
        } else if hue >= 195 && hue < 260 {
            return .blue
        } else if hue >= 260 && hue < 290 {
            return .purple
        } else { // 290-345
            return .pink
        }
    }

    /// Calculate hue from RGB (0-360 degrees)
    private static func calculateHue(r: Double, g: Double, b: Double, maxC: Double, delta: Double) -> Double {
        guard delta > 0 else { return 0 }

        var hue: Double = 0
        if maxC == r {
            hue = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
        } else if maxC == g {
            hue = 60 * (((b - r) / delta) + 2)
        } else {
            hue = 60 * (((r - g) / delta) + 4)
        }
        if hue < 0 { hue += 360 }
        return hue
    }

    // MARK: - Feature Vector Extraction

    /// Extract feature vector for future clustering/similarity detection
    /// - Parameter url: Path to image file
    /// - Returns: Feature vector as array of floats, or nil if extraction fails
    static func extractFeatureVector(from url: URL) async throws -> [Float]? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VisionError.fileNotFound(url)
        }

        return try await withTimeout(seconds: operationTimeout) {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        guard let cgImage = loadImage(from: url, maxDimension: 512) else {
                            continuation.resume(returning: nil)
                            return
                        }

                        let request = VNGenerateImageFeaturePrintRequest()
                        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                        try handler.perform([request])

                        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
                            continuation.resume(returning: nil)
                            return
                        }

                        // Extract the feature data
                        let data = observation.data
                        let count = data.count / MemoryLayout<Float>.size
                        var floats = [Float](repeating: 0, count: count)
                        _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }

                        continuation.resume(returning: floats)
                    } catch {
                        continuation.resume(throwing: VisionError.featureExtractionFailed(url, error))
                    }
                }
            }
        }
    }

    // MARK: - Saliency Detection

    /// Detect the most salient region of an image for smart thumbnail cropping
    /// - Parameter url: Path to image file
    /// - Returns: Normalized rect (0-1) of the salient region, or nil if detection fails
    static func extractSaliencyRect(from url: URL) async throws -> CGRect? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VisionError.fileNotFound(url)
        }

        return try await withTimeout(seconds: operationTimeout) {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        guard let cgImage = loadImage(from: url, maxDimension: 1024) else {
                            continuation.resume(returning: nil)
                            return
                        }

                        // Use attention-based saliency for better results with faces/objects
                        let request = VNGenerateAttentionBasedSaliencyImageRequest()
                        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                        try handler.perform([request])

                        guard let observation = request.results?.first as? VNSaliencyImageObservation,
                              let salientObjects = observation.salientObjects,
                              !salientObjects.isEmpty else {
                            continuation.resume(returning: nil)
                            return
                        }

                        // Find the union of all salient object bounding boxes
                        var unionRect = salientObjects[0].boundingBox
                        for obj in salientObjects.dropFirst() {
                            unionRect = unionRect.union(obj.boundingBox)
                        }

                        // Expand slightly for context (10% padding)
                        let padding: CGFloat = 0.1
                        let expandedRect = CGRect(
                            x: max(0, unionRect.origin.x - unionRect.width * padding),
                            y: max(0, unionRect.origin.y - unionRect.height * padding),
                            width: min(1 - max(0, unionRect.origin.x - unionRect.width * padding),
                                       unionRect.width * (1 + 2 * padding)),
                            height: min(1 - max(0, unionRect.origin.y - unionRect.height * padding),
                                        unionRect.height * (1 + 2 * padding))
                        )

                        continuation.resume(returning: expandedRect)
                    } catch {
                        continuation.resume(throwing: VisionError.saliencyFailed(url, error))
                    }
                }
            }
        }
    }

    // MARK: - Background Removal (macOS 14+)

    /// Shared isolator instance for subject isolation operations
    private static let isolator = SubjectIsolator()

    /// Generate a foreground instance mask for background removal
    /// Uses SubjectIsolation library for consistent results across the app
    /// - Parameter url: Path to image file
    /// - Returns: Mask as CGImage (white = foreground, black = background), or nil if unavailable
    static func removeBackground(from url: URL) async throws -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VisionError.fileNotFound(url)
        }

        return try await withTimeout(seconds: operationTimeout) {
            guard let cgImage = loadImage(from: url, maxDimension: 2048) else {
                return nil
            }

            do {
                let mask = try await isolator.foregroundMask(image: cgImage)
                return mask
            } catch {
                throw VisionError.backgroundRemovalFailed(url, error)
            }
        }
    }

    // MARK: - Person Segmentation

    /// Segment people from an image
    /// Uses SubjectIsolation library for person segmentation
    /// - Parameters:
    ///   - url: Path to image file
    ///   - quality: Quality level (.fast, .balanced, .accurate)
    /// - Returns: Person mask as CGImage (white = person, black = background)
    static func segmentPerson(
        from url: URL,
        quality: VNGeneratePersonSegmentationRequest.QualityLevel = .balanced
    ) async throws -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VisionError.fileNotFound(url)
        }

        return try await withTimeout(seconds: operationTimeout) {
            guard let cgImage = loadImage(from: url, maxDimension: 2048) else {
                return nil
            }

            // Map VNGeneratePersonSegmentationRequest.QualityLevel to SubjectIsolation's SegmentationQuality
            let isolationQuality: SegmentationQuality
            switch quality {
            case .fast: isolationQuality = .fast
            case .balanced: isolationQuality = .balanced
            case .accurate: isolationQuality = .accurate
            @unknown default: isolationQuality = .balanced
            }

            do {
                let result = try await isolator.segmentPersons(image: cgImage, quality: isolationQuality)
                return result.mask
            } catch {
                throw VisionError.personSegmentationFailed(url, error)
            }
        }
    }

    // MARK: - Subject Selection (Sniper Tool)

    /// Analyze all subjects in an image and return their masks for preview/hit-testing
    /// Uses SubjectIsolation library which provides masks, bounding boxes, and contour paths
    /// Called on annotation mode start to enable instant sniper selection
    /// - Parameter url: Path to image file
    /// - Returns: Array of SubjectMask with mask images, bounds, and contour paths
    static func analyzeAllSubjects(from url: URL) async throws -> [SubjectMask] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VisionError.fileNotFound(url)
        }

        return try await withTimeout(seconds: operationTimeout) {
            guard let cgImage = loadImage(from: url, maxDimension: 2048) else {
                return []
            }

            do {
                let result = try await isolator.isolate(
                    image: cgImage,
                    options: IsolationOptions(
                        requestedTypes: [.foregroundInstance],
                        generatePaths: true,
                        contourSimplification: 0.005
                    )
                )

                var masks: [SubjectMask] = []

                for subject in result.subjects {
                    // Pre-extract pixel data for fast hit testing
                    guard let pixelData = SubjectMask.extractPixelData(from: subject.mask) else {
                        continue
                    }

                    masks.append(SubjectMask(
                        mask: subject.mask,
                        bounds: subject.boundingBox,
                        instanceIndex: subject.index,
                        maskPixelData: pixelData.data,
                        bytesPerRow: pixelData.bytesPerRow,
                        contourPath: subject.contourPath,
                        outerContourPath: subject.outerContourPath
                    ))
                }

                return masks
            } catch {
                throw VisionError.subjectSelectionFailed(url, error)
            }
        }
    }

    // MARK: - Mask Feathering

    /// Apply Gaussian blur to soften mask edges
    /// - Parameters:
    ///   - mask: Input mask CGImage
    ///   - radius: Blur radius in pixels (default 3.0)
    /// - Returns: Feathered mask as CGImage
    static func featherMask(_ mask: CGImage, radius: CGFloat = 3.0) -> CGImage? {
        let ciImage = CIImage(cgImage: mask)

        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else {
            return nil
        }

        blurFilter.setValue(ciImage, forKey: kCIInputImageKey)
        blurFilter.setValue(radius, forKey: kCIInputRadiusKey)

        guard let blurredImage = blurFilter.outputImage else {
            return nil
        }

        // Crop to original extent (blur expands the image)
        let croppedImage = blurredImage.cropped(to: ciImage.extent)

        let context = sharedDefaultCIContext
        return context.createCGImage(croppedImage, from: croppedImage.extent)
    }

    // MARK: - Image Loading

    /// Load an image from disk, optionally downsampling to max dimension
    private static func loadImage(from url: URL, maxDimension: CGFloat) -> CGImage? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        // Check original dimensions
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            // Fall back to loading without downsampling
            return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        }

        let originalMax = max(width, height)

        // If already small enough, load directly
        if CGFloat(originalMax) <= maxDimension {
            return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        }

        // Downsample
        let scale = maxDimension / CGFloat(originalMax)
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: Int(CGFloat(originalMax) * scale),
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]

        return CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)
    }

    // MARK: - Timeout Helper

    /// Internal so the cancellation-resistant race can be covered without running Vision.
    static func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withTimeout(seconds: seconds) { _ in
            try await operation()
        }
    }

    /// Variant for blocking operations that must register their own cancellation primitive.
    static func withTimeout<T>(
        seconds: TimeInterval,
        operation: @escaping (VisionOperationCancellation) async throws -> T
    ) async throws -> T {
        let operationCancellation = VisionOperationCancellation()
        let state = VisionOperationTimeoutState<T>(operationCancellation: operationCancellation)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.start(
                    continuation: continuation,
                    seconds: seconds,
                    operation: {
                        try await operation(operationCancellation)
                    }
                )
            }
        } onCancel: {
            state.settle(with: .failure(CancellationError()), cancelOperation: true)
        }
    }
}

// MARK: - Errors

enum VisionError: Error, LocalizedError {
    case fileNotFound(URL)
    case timeout
    case ocrFailed(URL, Error)
    case colorExtractionFailed(URL, Error)
    case featureExtractionFailed(URL, Error)
    case saliencyFailed(URL, Error)
    case hashFailed(URL, Error)
    case backgroundRemovalFailed(URL, Error)
    case personSegmentationFailed(URL, Error)
    case subjectSelectionFailed(URL, Error)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "File not found: \(url.lastPathComponent)"
        case .timeout:
            return "Vision operation timed out"
        case .ocrFailed(let url, let error):
            return "OCR failed for \(url.lastPathComponent): \(error.localizedDescription)"
        case .colorExtractionFailed(let url, let error):
            return "Color extraction failed for \(url.lastPathComponent): \(error.localizedDescription)"
        case .featureExtractionFailed(let url, let error):
            return "Feature extraction failed for \(url.lastPathComponent): \(error.localizedDescription)"
        case .saliencyFailed(let url, let error):
            return "Saliency detection failed for \(url.lastPathComponent): \(error.localizedDescription)"
        case .hashFailed(let url, let error):
            return "Hash computation failed for \(url.lastPathComponent): \(error.localizedDescription)"
        case .backgroundRemovalFailed(let url, let error):
            return "Background removal failed for \(url.lastPathComponent): \(error.localizedDescription)"
        case .personSegmentationFailed(let url, let error):
            return "Person segmentation failed for \(url.lastPathComponent): \(error.localizedDescription)"
        case .subjectSelectionFailed(let url, let error):
            return "Subject selection failed for \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}
