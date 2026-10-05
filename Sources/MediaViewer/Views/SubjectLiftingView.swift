import SwiftUI
import AppKit
import VisionKit
import CoreGraphics
import SubjectIsolation

// MARK: - Subject Mask Type

/// Cached subject mask from Vision analysis for instant sniper selection
struct SubjectMask: Identifiable, Equatable {
    let id = UUID()
    let mask: CGImage           // The actual mask image
    let bounds: CGRect          // Bounding box in normalized coords (0-1)
    let instanceIndex: Int      // Index in Vision's instance array
    let maskPixelData: Data     // Pre-extracted pixel data for fast hit testing
    let bytesPerRow: Int        // Bytes per row in pixel data
    let contourPath: CGPath?        // Full contour path in normalized coordinates
    let outerContourPath: CGPath?   // Simplified outer contour (no holes)

    init(
        mask: CGImage,
        bounds: CGRect,
        instanceIndex: Int,
        maskPixelData: Data,
        bytesPerRow: Int,
        contourPath: CGPath? = nil,
        outerContourPath: CGPath? = nil
    ) {
        self.mask = mask
        self.bounds = bounds
        self.instanceIndex = instanceIndex
        self.maskPixelData = maskPixelData
        self.bytesPerRow = bytesPerRow
        self.contourPath = contourPath
        self.outerContourPath = outerContourPath
    }

    static func == (lhs: SubjectMask, rhs: SubjectMask) -> Bool {
        lhs.id == rhs.id
    }

    /// Check if a pixel in the mask is set (non-zero alpha) - O(1) memory lookup
    func isPixelSet(x: Int, y: Int) -> Bool {
        guard x >= 0 && x < mask.width && y >= 0 && y < mask.height else {
            return false
        }
        // CGImage coordinates: origin at bottom-left, but our data is top-left
        // Flip y coordinate
        let flippedY = mask.height - 1 - y
        let offset = flippedY * bytesPerRow + x
        guard offset >= 0 && offset < maskPixelData.count else { return false }
        return maskPixelData[offset] > 128
    }

    /// Extract grayscale pixel data from a CGImage for fast hit testing
    static func extractPixelData(from image: CGImage) -> (data: Data, bytesPerRow: Int)? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width

        // Create grayscale context to extract alpha/luminance
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else { return nil }
        let buffer = Data(bytes: data, count: height * bytesPerRow)
        return (buffer, bytesPerRow)
    }
}

// MARK: - Subject Lifting View (Apple Native)

/// SwiftUI wrapper for Apple's native ImageAnalysisOverlayView
/// Provides iOS-style "lift subject" interaction on macOS 14+
@available(macOS 14.0, *)
struct SubjectLiftingOverlay: NSViewRepresentable {
    let image: NSImage
    let contentRect: CGRect

    func makeNSView(context: Context) -> ImageAnalysisOverlayView {
        let overlayView = ImageAnalysisOverlayView()
        overlayView.delegate = context.coordinator
        // Enable subject lifting interaction
        overlayView.preferredInteractionTypes = .imageSubject
        return overlayView
    }

    func updateNSView(_ overlayView: ImageAnalysisOverlayView, context: Context) {
        context.coordinator.contentRect = contentRect
        overlayView.setContentsRectNeedsUpdate()

        // Analyze image for subjects
        Task { @MainActor in
            await context.coordinator.analyzeImage(image, for: overlayView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(contentRect: contentRect)
    }

    class Coordinator: NSObject, ImageAnalysisOverlayViewDelegate {
        var contentRect: CGRect
        private let analyzer = ImageAnalyzer()
        private var lastAnalyzedImage: NSImage?

        init(contentRect: CGRect) {
            self.contentRect = contentRect
        }

        // MARK: - ImageAnalysisOverlayViewDelegate

        func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
            return contentRect
        }

        // MARK: - Analysis

        @MainActor
        func analyzeImage(_ image: NSImage, for overlayView: ImageAnalysisOverlayView) async {
            // Skip if already analyzed this image
            guard lastAnalyzedImage !== image else { return }
            lastAnalyzedImage = image

            let configuration = ImageAnalyzer.Configuration([.visualLookUp])

            do {
                let analysis = try await analyzer.analyze(
                    image,
                    orientation: .up,
                    configuration: configuration
                )
                overlayView.analysis = analysis
            } catch {
                Log.error("Subject lifting analysis failed: \(error.localizedDescription)")
            }
        }
    }
}
