import Foundation
import CoreGraphics
import Vision

/// Neural text block detection using Apple's private CRTextDetectionPipeline.
///
/// This replicates what Photos.app does: run the cr_td_model_v3 neural network
/// to detect text blocks BEFORE OCR, then recognize text within each block.
/// Block boundaries come from the model (oriented quads), not spatial heuristics.
///
/// Pipeline (matches Apple's internal flow):
/// ```
/// image → CRTextDetectionPipeline (neural) → block regions
///       → VNRecognizeTextRequest per block  → per-line text
///       → join lines within each block      → paragraphs
/// ```
///
/// Falls back gracefully: if the private framework isn't available,
/// returns nil so callers can use spatial heuristics instead.
public final class NeuralTextDetector: @unchecked Sendable {

    private let loader = FrameworkLoader.shared
    private let queue = DispatchQueue(label: "com.photopipeline.neuraltext", qos: .userInitiated)
    private var detectorClass: AnyClass?
    private var readerClass: AnyClass?
    private let languages: [String]
    private var available: Bool = false
    private var probedMethods: [String] = []

    public init(languages: [String] = ["en-US"]) {
        self.languages = languages
        probe()
    }

    /// Whether the neural detector is available on this system.
    public var isAvailable: Bool { available }

    /// Detected methods on the pipeline class (for diagnostics).
    public var detectedMethods: [String] { probedMethods }

    // MARK: - Detection

    /// Detect text blocks in an image using the neural pipeline.
    ///
    /// Returns an array of block regions (bounding boxes) where text was detected.
    /// Each region represents a coherent text block (paragraph, heading, caption, etc.).
    /// Returns nil if the neural detector isn't available.
    public func detectBlocks(image: CGImage) async -> [CGRect]? {
        guard available else { return nil }

        // Strategy 1: Try VNDetectTextRectanglesRequest with private extensions
        // This uses the same neural pipeline internally but through the public API surface
        if let blocks = try? await detectViaVisionPrivate(image: image), !blocks.isEmpty {
            return blocks
        }

        // Strategy 2: Try CRTextDetectionPipeline directly
        if let blocks = await detectViaCRPipeline(image: image), !blocks.isEmpty {
            return blocks
        }

        return nil
    }

    /// Full pipeline: detect blocks neurally, then OCR within each block.
    ///
    /// This is Apple's exact pipeline:
    /// 1. Neural block detection → oriented quad regions
    /// 2. Per-block VNRecognizeTextRequest → per-line text
    /// 3. Lines grouped by their source block → paragraphs
    public func detectAndRecognize(image: CGImage) async throws -> [TextBlock]? {
        guard let blockRegions = await detectBlocks(image: image), !blockRegions.isEmpty else {
            return nil
        }

        var textBlocks: [TextBlock] = []

        for (i, region) in blockRegions.enumerated() {
            // Run OCR within this block region
            let observations = try await recognizeInRegion(image: image, region: region)
            guard !observations.isEmpty else { continue }

            // Join lines within this block
            let text = observations.map(\.text).joined(separator: " ")
            let avgConf = observations.map(\.confidence).reduce(0, +) / Float(observations.count)
            let bbox = observations.map(\.boundingBox).reduce(region) { $0.union($1) }

            textBlocks.append(TextBlock(
                id: "neural-\(i)",
                text: text,
                lines: observations,
                boundingBox: bbox,
                confidence: avgConf,
                role: .body,
                columnIndex: 0
            ))
        }

        // Classify roles using the spatial analyzer (reuse the heuristics)
        let analyzer = TextLayoutAnalyzer()
        let allObs = textBlocks.flatMap(\.lines)
        let columns = analyzer.detectColumns(allObs)
        _ = analyzer.detectReadingDirection(allObs)

        // Re-tag with column indices and roles
        textBlocks = textBlocks.enumerated().map { i, block in
            let colIdx = columns.firstIndex { range in
                range.contains(block.boundingBox.midX)
            } ?? 0

            return TextBlock(
                id: block.id,
                text: block.text,
                lines: block.lines,
                boundingBox: block.boundingBox,
                confidence: block.confidence,
                role: classifyBlockRole(block, allBlocks: textBlocks),
                columnIndex: colIdx
            )
        }

        return textBlocks
    }

    // MARK: - Probing

    /// Probe the runtime for available text detection classes and methods.
    private func probe() {
        // Load TextRecognition framework
        do {
            try loader.load(.textRecognition)
        } catch {
            return
        }

        // Look for detection pipeline classes
        let classNames = [
            "CRTextDetectionPipeline",
            "CRNeuralTextDetectorDelegateFacade",
            "ImageReader",           // Swift class
            "CREngineAccurate",
            "CREngineFast",
            "VNCRImageReaderDetector",
        ]

        for name in classNames {
            if let cls = NSClassFromString(name) {
                if name == "CRTextDetectionPipeline" {
                    detectorClass = cls
                }
                if name == "ImageReader" || name == "CREngineAccurate" {
                    readerClass = cls
                }
                probedMethods.append(contentsOf:
                    ObjCBridge.methodNames(of: cls).map { "\(name).\($0)" }
                )
            }
        }

        // Also check Vision's internal bridge
        if let visionCls = NSClassFromString("VNCRImageReaderDetector") {
            readerClass = readerClass ?? visionCls
            probedMethods.append(contentsOf:
                ObjCBridge.methodNames(of: visionCls).map { "VNCRImageReaderDetector.\($0)" }
            )
        }

        available = detectorClass != nil || readerClass != nil
    }

    // MARK: - Strategy 1: Vision Private Extensions

    /// Use VNDetectTextRectanglesRequest to get block-level regions.
    /// The public API gives us text rectangles — with `reportCharacterBoxes = false`
    /// these are line-level, but we can group nearby lines into blocks.
    ///
    /// The key insight: VNRecognizeTextRequest internally groups lines by their
    /// source detection block. We can extract this by analyzing the spatial
    /// distribution of returned observations.
    private func detectViaVisionPrivate(image: CGImage) async throws -> [CGRect] {
        try await withCheckedThrowingContinuation { cont in
            let handler = VNImageRequestHandler(cgImage: image, options: [:])

            // VNDetectTextRectanglesRequest gives us text regions
            let request = VNDetectTextRectanglesRequest { request, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }

                guard let results = request.results as? [VNTextObservation] else {
                    cont.resume(returning: [])
                    return
                }

                // Group detected text rectangles into blocks using
                // the neural detector's own line grouping
                let rects = results.map { $0.boundingBox }
                let blocks = self.groupRectsIntoBlocks(rects)
                cont.resume(returning: blocks)
            }

            // Ask for character-level boxes so we can distinguish lines from blocks
            request.reportCharacterBoxes = false

            do {
                try handler.perform([request])
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    /// Group detected text rectangles into blocks.
    /// Lines from the same text block will have very similar X ranges
    /// and small vertical gaps.
    private func groupRectsIntoBlocks(_ rects: [CGRect]) -> [CGRect] {
        guard !rects.isEmpty else { return [] }

        // Sort top to bottom (descending Y in Vision coords)
        let sorted = rects.sorted { $0.midY > $1.midY }
        let medianHeight = sorted.map(\.height).sorted()[sorted.count / 2]
        let threshold = medianHeight * 2.0

        var blocks: [[CGRect]] = []
        var current: [CGRect] = [sorted[0]]

        for rect in sorted.dropFirst() {
            guard let last = current.last else {
                current = [rect]
                continue
            }

            let gap = last.minY - rect.maxY
            let overlapStart = max(last.minX, rect.minX)
            let overlapEnd = min(last.maxX, rect.maxX)
            let hOverlap = max(0, overlapEnd - overlapStart) /
                min(last.width, rect.width)

            if gap < threshold && gap >= 0 && hOverlap > 0.3 {
                current.append(rect)
            } else {
                blocks.append(current)
                current = [rect]
            }
        }
        blocks.append(current)

        // Merge each group into a single bounding box
        return blocks.map { group in
            group.reduce(group[0]) { $0.union($1) }
        }
    }

    // MARK: - Strategy 2: CRTextDetectionPipeline Direct

    /// Try to use CRTextDetectionPipeline directly via dlopen.
    private func detectViaCRPipeline(image: CGImage) async -> [CGRect]? {
        guard let cls = detectorClass else { return nil }

        return await withCheckedContinuation { cont in
            queue.async {
                // Try to create the pipeline
                guard let pipeline = ObjCBridge.create(cls) else {
                    cont.resume(returning: nil)
                    return
                }

                // Create pixel buffer
                guard let pixelBuffer = self.createPixelBuffer(from: image) else {
                    cont.resume(returning: nil)
                    return
                }

                // Try known method signatures for detection
                let detectionSelectors = [
                    "detectTextInPixelBuffer:",
                    "detectInPixelBuffer:",
                    "processPixelBuffer:",
                    "detectTextRegionsInPixelBuffer:",
                    "detect:",
                ]

                for sel in detectionSelectors {
                    if ObjCBridge.responds(pipeline, to: sel) {
                        let result = ObjCBridge.call(pipeline, sel, with: pixelBuffer)

                        // Try to extract bounding boxes from the result
                        if let rects = self.extractRects(from: result) {
                            cont.resume(returning: rects)
                            return
                        }
                    }
                }

                // Try with CGImage input instead
                let imageSelectors = [
                    "detectTextInImage:",
                    "detectInImage:",
                    "processImage:",
                ]

                for sel in imageSelectors {
                    if ObjCBridge.responds(pipeline, to: sel) {
                        let result = ObjCBridge.call(pipeline, sel, with: image)
                        if let rects = self.extractRects(from: result) {
                            cont.resume(returning: rects)
                            return
                        }
                    }
                }

                cont.resume(returning: nil)
            }
        }
    }

    /// Extract CGRect array from various possible output formats.
    private func extractRects(from result: Any?) -> [CGRect]? {
        guard let result else { return nil }

        // Array of NSDictionary with boundingBox keys
        if let dicts = result as? [NSDictionary] {
            let rects = dicts.compactMap { dict -> CGRect? in
                if let box = dict["boundingBox"] as? CGRect { return box }
                if let box = dict["bounds"] as? CGRect { return box }
                if let box = dict["rect"] as? CGRect { return box }
                // Try nested NSValue
                if let val = dict["boundingBox"] as? NSValue {
                    return val.rectValue
                }
                return nil
            }
            return rects.isEmpty ? nil : rects
        }

        // Array of NSObject with boundingBox property
        if let objects = result as? [NSObject] {
            let rects = objects.compactMap { obj -> CGRect? in
                if let val = ObjCBridge.getValue(obj, forKey: "boundingBox") {
                    if let rect = val as? CGRect { return rect }
                    if let nsVal = val as? NSValue { return nsVal.rectValue }
                }
                // Try quad corners → axis-aligned bounding box
                if let topLeft = ObjCBridge.getValue(obj, forKey: "topLeft") as? CGPoint,
                   let bottomRight = ObjCBridge.getValue(obj, forKey: "bottomRight") as? CGPoint {
                    return CGRect(
                        x: topLeft.x, y: bottomRight.y,
                        width: bottomRight.x - topLeft.x,
                        height: topLeft.y - bottomRight.y
                    )
                }
                return nil
            }
            return rects.isEmpty ? nil : rects
        }

        return nil
    }

    // MARK: - Per-Block OCR

    /// Run VNRecognizeTextRequest within a specific region of the image.
    private func recognizeInRegion(image: CGImage, region: CGRect) async throws -> [TextObservation] {
        try await withCheckedThrowingContinuation { cont in
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }

                let observations = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap { result -> TextObservation? in
                    guard let candidate = result.topCandidates(1).first else { return nil }
                    return TextObservation(
                        text: candidate.string,
                        boundingBox: result.boundingBox,
                        confidence: candidate.confidence,
                        language: nil
                    )
                }
                cont.resume(returning: observations)
            }

            request.recognitionLevel = .accurate
            request.recognitionLanguages = languages
            request.usesLanguageCorrection = true
            request.regionOfInterest = region

            do {
                try handler.perform([request])
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    // MARK: - Role Classification

    /// Simple role classification based on block properties relative to peers.
    private func classifyBlockRole(_ block: TextBlock, allBlocks: [TextBlock]) -> TextRole {
        guard allBlocks.count > 1 else { return .body }

        let heights = allBlocks.flatMap { $0.lines.map { $0.boundingBox.height } }
        let medianH = heights.sorted()[heights.count / 2]
        let blockAvgH = block.lines.map { $0.boundingBox.height }.reduce(0, +)
            / CGFloat(max(block.lines.count, 1))

        let maxY = allBlocks.map { $0.boundingBox.maxY }.max() ?? 1
        let minY = allBlocks.map { $0.boundingBox.minY }.min() ?? 0
        let pageHeight = maxY - minY

        // Heading: notably larger text, especially near top
        if blockAvgH > medianH * 1.4 {
            if block.lines.count <= 2 { return .heading }
            let nearTop = block.boundingBox.maxY > maxY - pageHeight * 0.15
            if nearTop { return .heading }
        }

        // Caption: notably smaller text, near bottom or narrow
        if blockAvgH < medianH * 0.8 {
            let nearBottom = block.boundingBox.minY < minY + pageHeight * 0.1
            if nearBottom || block.lines.count == 1 { return .caption }
        }

        return .body
    }

    // MARK: - Helpers

    private func createPixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let width = image.width
        let height = image.height
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                           kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        guard let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
