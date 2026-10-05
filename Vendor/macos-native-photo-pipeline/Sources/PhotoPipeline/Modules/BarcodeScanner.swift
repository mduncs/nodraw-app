import Foundation
import CoreGraphics
import Vision

/// Barcode and QR code detection using public VNDetectBarcodesRequest.
///
/// Detects all standard symbologies: QR, EAN-13, Code 128, UPC-E, Aztec, Data Matrix, etc.
///
/// ```swift
/// let scanner = BarcodeScanner()
/// let results = try await scanner.scan(image: cgImage)
/// for code in results {
///     print("\(code.symbology): \(code.payload) at \(code.boundingBox)")
/// }
/// ```
public final class BarcodeScanner: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.photopipeline.barcode", qos: .userInitiated)

    public init() {}

    /// Scan for barcodes and QR codes in an image.
    public func scan(image: CGImage) async throws -> [BarcodeResult] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let results = try self.scanSync(image: image)
                    cont.resume(returning: results)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Sync implementation

    private func scanSync(image: CGImage) throws -> [BarcodeResult] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNDetectBarcodesRequest()
        try handler.perform([request])

        return (request.results ?? []).map { obs in
            BarcodeResult(
                payload: obs.payloadStringValue ?? "",
                symbology: obs.symbology.rawValue,
                boundingBox: obs.boundingBox,
                confidence: obs.confidence
            )
        }
    }
}

// MARK: - Result types

/// A detected barcode or QR code.
public struct BarcodeResult: Codable, Sendable {
    /// The decoded payload string (URL, text, number, etc.).
    public let payload: String
    /// The symbology identifier, e.g. "VNBarcodeSymbologyQR", "VNBarcodeSymbologyEAN13".
    public let symbology: String
    /// Bounding box in Vision normalized coordinates (0-1, origin bottom-left).
    public let boundingBox: CGRect
    public let confidence: Float
}
