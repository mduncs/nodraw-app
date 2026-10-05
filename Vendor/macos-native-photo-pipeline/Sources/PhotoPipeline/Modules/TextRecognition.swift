import Foundation
import CoreGraphics
import Vision

/// OCR text recognition with dual engine support.
///
/// - **Standard engine**: Public `VNRecognizeTextRequest` — works in sandboxed apps.
/// - **Advanced engine**: Private `CREngineAccurate` via dlopen — 6 language models,
///   form/table detection, language model integration. Non-sandboxed only.
///
/// ```swift
/// let recognizer = try TextRecognizer()
/// let observations = try await recognizer.recognize(image: cgImage)
/// for obs in observations {
///     print("\(obs.text) [\(obs.confidence)]")
/// }
/// ```
public final class TextRecognizer: @unchecked Sendable {

    /// Which OCR engine to use.
    public enum Engine: Sendable {
        /// Public Vision API (VNRecognizeTextRequest). Works everywhere.
        case standard
        /// Private CREngine (TextRecognition.framework). More accurate, non-sandboxed only.
        case advanced
    }

    private let engine: Engine
    private let languages: [String]
    private let loader = FrameworkLoader.shared
    private let queue = DispatchQueue(label: "com.photopipeline.text-recognition", qos: .userInitiated)

    /// Post-OCR quality filter. Applied automatically to all recognition results.
    ///
    /// **Library addition, not Apple behavior.** Photos.app stores all OCR results
    /// regardless of quality. This filter removes garbled noise (texture patterns,
    /// bokeh, wood grain misread as characters) before results reach your code.
    ///
    /// Set to `nil` to disable and match Apple's store-everything behavior.
    public let qualityFilter: OCRQualityFilter?

    /// Initialize the text recognizer.
    ///
    /// - Parameters:
    ///   - engine: Which OCR engine to use. Default `.standard`.
    ///   - languages: BCP-47 language codes. Default `["en-US"]`.
    ///   - qualityFilter: Post-OCR quality filter. Default `.default` (on).
    ///     Pass `nil` to disable filtering and match Apple's behavior.
    public init(
        engine: Engine = .standard,
        languages: [String] = ["en-US"],
        qualityFilter: OCRQualityFilter? = .default
    ) throws {
        self.engine = engine
        self.languages = languages
        self.qualityFilter = qualityFilter

        if engine == .advanced {
            try loader.load(.textRecognition)
        }
    }

    /// Recognize text in an image. Returns individual line observations.
    ///
    /// Results are automatically filtered by `qualityFilter` (if set) to remove
    /// low-confidence noise. Pass `qualityFilter: nil` at init to disable.
    public func recognize(image: CGImage) async throws -> [TextObservation] {
        let raw: [TextObservation]
        switch engine {
        case .standard:
            raw = try await recognizeStandard(image: image)
        case .advanced:
            raw = try await recognizeAdvanced(image: image)
        }
        if let filter = qualityFilter {
            return filter.apply(raw)
        }
        return raw
    }

    /// Recognize and group text using the specified layout strategy.
    ///
    /// - `.line`: raw per-line observations wrapped as single-line blocks
    /// - `.block`: spatial paragraph grouping (vertically adjacent, aligned lines)
    /// - `.column`: column detection + block grouping within each column
    /// - `.document`: full layout with columns, reading order, and structural roles
    /// - `.neural`: Apple's CRTextDetectionPipeline neural block detection + per-block OCR.
    ///   Falls back to `.document` if the private framework is unavailable.
    public func recognizeGrouped(image: CGImage, grouping: TextGrouping = .block) async throws -> [TextBlock] {
        if grouping == .neural {
            let detector = NeuralTextDetector(languages: languages)
            if var blocks = try await detector.detectAndRecognize(image: image), !blocks.isEmpty {
                if let filter = qualityFilter {
                    blocks = filterBlocks(blocks, with: filter)
                }
                return blocks
            }
            // Fall back to spatial document analysis
            let observations = try await recognize(image: image)
            let analyzer = TextLayoutAnalyzer()
            return analyzer.group(observations, strategy: .document)
        }

        let observations = try await recognize(image: image)
        let analyzer = TextLayoutAnalyzer()
        return analyzer.group(observations, strategy: grouping)
    }

    /// Recognize with full document layout analysis.
    /// Returns a `DocumentLayout` with columns, reading order, and form/table detection.
    public func recognizeDocument(image: CGImage) async throws -> DocumentLayout {
        let observations = try await recognize(image: image)
        let analyzer = TextLayoutAnalyzer()
        return analyzer.analyzeDocument(observations)
    }

    // MARK: - Standard engine (public Vision API)

    private func recognizeStandard(image: CGImage) async throws -> [TextObservation] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    cont.resume(returning: try self.recognizeStandardSync(image: image))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Advanced engine (private TextRecognition framework)

    private func recognizeAdvanced(image: CGImage) async throws -> [TextObservation] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let results = try self.recognizeAdvancedSync(image: image)
                    cont.resume(returning: results)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func recognizeAdvancedSync(image: CGImage) throws -> [TextObservation] {
        // CRImageReader is the ObjC class for text recognition (wraps CREngineAccurate internally)
        guard let readerCls = loader.classNamed("CRImageReader") else {
            throw FrameworkError.classNotFound("CRImageReader", framework: "TextRecognition")
        }

        // Build options dictionary
        let options: [String: Any] = [
            "VNRequestOptionRecognitionLanguages": languages,
            "VNRequestOptionRecognitionLevel": 1, // accurate
            "VNRequestOptionUsesLanguageCorrection": true,
        ]

        // CRImageReader initWithOptions:error:
        let allocSel = NSSelectorFromString("alloc")
        guard readerCls.responds(to: allocSel),
              let allocated = (readerCls as AnyObject).perform(allocSel)?.takeUnretainedValue() else {
            throw FrameworkError.invocationFailed("Failed to alloc CRImageReader")
        }

        let (reader, initError) = ObjCBridge.msgSendObjError(
            allocated, "initWithOptions:error:", options as NSDictionary
        )
        if let initError {
            throw initError
        }
        guard let reader else {
            throw FrameworkError.invocationFailed("CRImageReader initWithOptions: returned nil")
        }

        // Create pixel buffer from CGImage
        guard let pixelBuffer = createPixelBuffer(from: image) else {
            throw FrameworkError.invocationFailed("Failed to create pixel buffer for OCR")
        }

        // resultsForPixelBuffer:roi:options:error:
        // Use full image ROI (0,0,1,1 in normalized coords)
        let roi = CGRect(x: 0, y: 0, width: 1, height: 1)

        // Try resultsForPixelBuffer:options:error: (simpler 3-arg version)
        let resultsSel = "resultsForPixelBuffer:options:error:"
        if ObjCBridge.responds(reader, to: resultsSel) {
            var error: NSError?
            typealias F = @convention(c) (AnyObject, Selector, CVPixelBuffer, AnyObject, UnsafeMutablePointer<NSError?>) -> AnyObject?
            let msgSend = unsafeBitCast(
                dlsym(dlopen(nil, RTLD_LAZY), "objc_msgSend"),
                to: F.self
            )
            let rawResult = msgSend(reader, NSSelectorFromString(resultsSel), pixelBuffer, options as NSDictionary, &error)
            if let error { throw error }

            if let results = rawResult {
                return parseImageReaderResults(results)
            }
        }

        // Try full 5-arg version: resultsForPixelBuffer:roi:options:error:withProgressHandler:
        let fullSel = "resultsForPixelBuffer:roi:options:error:withProgressHandler:"
        if ObjCBridge.responds(reader, to: fullSel) {
            var error: NSError?
            typealias F = @convention(c) (AnyObject, Selector, CVPixelBuffer, CGRect, AnyObject, UnsafeMutablePointer<NSError?>, AnyObject?) -> AnyObject?
            let msgSend = unsafeBitCast(
                dlsym(dlopen(nil, RTLD_LAZY), "objc_msgSend"),
                to: F.self
            )
            let rawResult = msgSend(reader, NSSelectorFromString(fullSel), pixelBuffer, roi, options as NSDictionary, &error, nil)
            if let error { throw error }

            if let results = rawResult {
                return parseImageReaderResults(results)
            }
        }

        // If private engine fails, fall back to standard
        return try recognizeStandardSync(image: image)
    }

    private func parseImageReaderResults(_ rawResult: AnyObject) -> [TextObservation] {
        // CRImageReaderOutput contains recognized text regions
        // Try to extract text observations from the result

        // If result is an array of result objects
        if let results = rawResult as? [AnyObject] {
            return results.compactMap { parseOneResult($0) }
        }

        // If result is a single CRImageReaderOutput, try getting its text features
        if let textFeatures = ObjCBridge.getValue(rawResult, forKey: "textFeatures") as? [AnyObject] {
            return textFeatures.compactMap { parseOneResult($0) }
        }
        if let allResults = ObjCBridge.getValue(rawResult, forKey: "allResults") as? [AnyObject] {
            return allResults.compactMap { parseOneResult($0) }
        }
        // Try detectedBlocks or textBlocks
        if let blocks = ObjCBridge.getValue(rawResult, forKey: "detectedBlocks") as? [AnyObject] {
            return blocks.compactMap { parseOneResult($0) }
        }

        // Single result
        if let single = parseOneResult(rawResult) {
            return [single]
        }

        return []
    }

    private func parseOneResult(_ obj: AnyObject) -> TextObservation? {
        // Try various property names for text content
        let text: String?
        if let t = ObjCBridge.getValue(obj, forKey: "string") as? String { text = t }
        else if let t = ObjCBridge.getValue(obj, forKey: "text") as? String { text = t }
        else if let t = ObjCBridge.getValue(obj, forKey: "recognizedText") as? String { text = t }
        else if let t = ObjCBridge.getValue(obj, forKey: "topCandidate") as? String { text = t }
        else { text = nil }

        guard let text, !text.isEmpty else { return nil }

        let confidence = (ObjCBridge.getValue(obj, forKey: "confidence") as? NSNumber)?.floatValue ?? 1.0
        let bbox = ObjCBridge.getValue(obj, forKey: "boundingBox") as? CGRect ?? .zero
        let lang = ObjCBridge.getValue(obj, forKey: "language") as? String

        return TextObservation(
            text: text,
            boundingBox: bbox,
            confidence: confidence,
            language: lang
        )
    }

    private func recognizeStandardSync(image: CGImage) throws -> [TextObservation] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        // `perform` is synchronous and may both invoke a completion handler and throw for
        // the same Vision failure. Read results after it returns so errors have one path and
        // cannot double-resume an async continuation.
        let request = VNRecognizeTextRequest()

        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true

        try handler.perform([request])
        return (request.results ?? []).compactMap { result -> TextObservation? in
            guard let candidate = result.topCandidates(1).first else { return nil }
            return TextObservation(
                text: candidate.string,
                boundingBox: result.boundingBox,
                confidence: candidate.confidence,
                language: nil
            )
        }
    }

    // MARK: - Block Filtering

    /// Apply quality filter to neural text blocks.
    /// Filters individual lines within each block, rebuilds block text,
    /// and drops blocks that end up empty.
    private func filterBlocks(_ blocks: [TextBlock], with filter: OCRQualityFilter) -> [TextBlock] {
        blocks.compactMap { block in
            let filteredLines = filter.apply(block.lines)
            guard !filteredLines.isEmpty else { return nil }
            let text = filteredLines.map(\.text).joined(separator: " ")
            let avgConf = filteredLines.map(\.confidence).reduce(0, +) / Float(filteredLines.count)
            return TextBlock(
                id: block.id,
                text: text,
                lines: filteredLines,
                boundingBox: block.boundingBox,
                confidence: avgConf,
                role: block.role,
                columnIndex: block.columnIndex
            )
        }
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
