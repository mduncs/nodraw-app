import Foundation
import CoreImage
import AppKit

// MARK: - Perceptual Hash

/// Computes perceptual hashes for duplicate detection using DCT-based pHash.
/// pHash (perceptual hash) works by:
/// 1. Resize image to 40x40 grayscale
/// 2. Compute 2D DCT (Discrete Cosine Transform)
/// 3. Extract 10x10 low-frequency coefficients (skip DC term) → 99 values
/// 4. Threshold at median → 99-bit hash → 26-char hex string
///
/// More robust than dHash against gamma/color corrections and minor edits.
/// Similar images will have similar hashes, enabling fuzzy duplicate detection
/// via Hamming distance comparison.
struct PerceptualHash: Sendable {

    /// Timeout for hash operations (30 seconds)
    private static let operationTimeout: TimeInterval = 30.0

    // MARK: - Public API

    /// Compute perceptual hash (DCT pHash) from an image file
    /// - Parameter url: Path to image file
    /// - Returns: 99-bit hash as 26-character hex string
    static func computeHash(from url: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VisionError.fileNotFound(url)
        }

        return try await withTimeout(seconds: operationTimeout) {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let hash = try computeDCTPHash(from: url)
                        continuation.resume(returning: hash)
                    } catch {
                        continuation.resume(throwing: VisionError.hashFailed(url, error))
                    }
                }
            }
        }
    }

    /// Compute Hamming distance between two hashes
    /// - Parameters:
    ///   - hash1: First hash (hex string)
    ///   - hash2: Second hash (hex string)
    /// - Returns: Number of differing bits (0 = identical, lower = more similar)
    static func hammingDistance(_ hash1: String, _ hash2: String) -> Int {
        guard isValidHash(hash1), isValidHash(hash2), hash1.count == hash2.count else {
            return Int.max
        }

        let bytes1 = hexToBytes(hash1)
        let bytes2 = hexToBytes(hash2)
        guard bytes1.count == bytes2.count else { return Int.max }

        var distance = 0
        for (b1, b2) in zip(bytes1, bytes2) {
            distance += (b1 ^ b2).nonzeroBitCount
        }
        return distance
    }

    /// Validate hash format (non-empty, even-length hex string)
    static func isValidHash(_ hash: String) -> Bool {
        guard !hash.isEmpty, hash.count.isMultiple(of: 2) else { return false }
        return hash.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) ||  // 0-9
            (byte >= 65 && byte <= 70) ||  // A-F
            (byte >= 97 && byte <= 102)    // a-f
        }
    }

    /// Convert hex string to byte array
    private static func hexToBytes(_ hex: String) -> [UInt8] {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[index..<nextIndex], radix: 16) {
                bytes.append(byte)
            }
            index = nextIndex
        }
        return bytes
    }

    /// Check if two hashes are likely duplicates
    /// - Parameters:
    ///   - hash1: First hash
    ///   - hash2: Second hash
    ///   - threshold: Maximum Hamming distance to consider duplicate (default: 15)
    /// - Returns: True if images are likely duplicates
    static func areSimilar(_ hash1: String, _ hash2: String, threshold: Int = 15) -> Bool {
        hammingDistance(hash1, hash2) <= threshold
    }

    // MARK: - DCT pHash Implementation

    /// Compute DCT-based perceptual hash for an image
    private static func computeDCTPHash(from url: URL) throws -> String {
        // Load image
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw HashError.loadFailed
        }

        // Resize to 40x40 grayscale
        let size = 40

        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw HashError.contextCreationFailed
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        guard let data = context.data else {
            throw HashError.dataExtractionFailed
        }

        let pixels = data.bindMemory(to: UInt8.self, capacity: size * size)

        // Convert to Double matrix
        var matrix = [[Double]](repeating: [Double](repeating: 0, count: size), count: size)
        for y in 0..<size {
            for x in 0..<size {
                matrix[y][x] = Double(pixels[y * size + x])
            }
        }

        // 2D DCT (separable): rows then columns
        var dctRows = [[Double]](repeating: [Double](repeating: 0, count: size), count: size)
        for y in 0..<size {
            dctRows[y] = dct1D(matrix[y])
        }

        var dct2D = [[Double]](repeating: [Double](repeating: 0, count: size), count: size)
        for x in 0..<size {
            var column = [Double](repeating: 0, count: size)
            for y in 0..<size { column[y] = dctRows[y][x] }
            let dctCol = dct1D(column)
            for y in 0..<size { dct2D[y][x] = dctCol[y] }
        }

        // Extract 10x10 low-frequency corner, skip DC [0][0] → 99 values
        var lowFreq = [Double]()
        lowFreq.reserveCapacity(99)
        for y in 0..<10 {
            for x in 0..<10 {
                if y == 0 && x == 0 { continue }
                lowFreq.append(dct2D[y][x])
            }
        }

        // Median threshold
        let sorted = lowFreq.sorted()
        let median = sorted[sorted.count / 2]

        // Build 99 bits → pad to 104 bits (13 bytes) → 26 hex chars
        var bytes = [UInt8](repeating: 0, count: 13)
        for (i, value) in lowFreq.enumerated() {
            if value >= median {
                bytes[i / 8] |= (1 << (7 - (i % 8)))
            }
        }

        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// 1D DCT Type-II
    private static func dct1D(_ input: [Double]) -> [Double] {
        let N = input.count
        let factor = Double.pi / Double(2 * N)
        var output = [Double](repeating: 0, count: N)
        for k in 0..<N {
            var sum = 0.0
            for n in 0..<N {
                sum += input[n] * cos(factor * Double(2 * n + 1) * Double(k))
            }
            output[k] = sum
        }
        return output
    }

    // MARK: - Timeout Helper

    private static func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw VisionError.timeout
            }

            guard let result = try await group.next() else {
                throw VisionError.timeout
            }

            group.cancelAll()
            return result
        }
    }
}

// MARK: - Hash Errors

private enum HashError: Error, LocalizedError {
    case loadFailed
    case contextCreationFailed
    case dataExtractionFailed

    var errorDescription: String? {
        switch self {
        case .loadFailed:
            return "Failed to load image for hashing"
        case .contextCreationFailed:
            return "Failed to create graphics context for hashing"
        case .dataExtractionFailed:
            return "Failed to extract pixel data for hashing"
        }
    }
}

// MARK: - Batch Operations

extension PerceptualHash {

    /// Find duplicates in a collection of items with hashes
    /// - Parameters:
    ///   - hashes: Dictionary mapping item IDs to their hashes
    ///   - threshold: Hamming distance threshold for duplicates
    /// - Returns: Array of duplicate pairs (id1, id2, distance)
    static func findDuplicates<ID: Hashable>(
        in hashes: [ID: String],
        threshold: Int = 15
    ) -> [(ID, ID, Int)] {
        var duplicates: [(ID, ID, Int)] = []
        let items = Array(hashes)

        for i in 0..<items.count {
            for j in (i + 1)..<items.count {
                let distance = hammingDistance(items[i].value, items[j].value)
                if distance <= threshold {
                    duplicates.append((items[i].key, items[j].key, distance))
                }
            }
        }

        // Sort by distance (most similar first)
        return duplicates.sorted { $0.2 < $1.2 }
    }

    /// Group items by similarity clusters
    /// - Parameters:
    ///   - hashes: Dictionary mapping item IDs to their hashes
    ///   - threshold: Hamming distance threshold for grouping
    /// - Returns: Array of groups, each containing similar item IDs
    static func clusterBySimilarity<ID: Hashable>(
        _ hashes: [ID: String],
        threshold: Int = 15
    ) -> [[ID]] {
        var clusters: [[ID]] = []
        var assigned: Set<ID> = []

        for (id, hash) in hashes {
            guard !assigned.contains(id) else { continue }

            var cluster: [ID] = [id]
            assigned.insert(id)

            for (otherId, otherHash) in hashes {
                guard !assigned.contains(otherId) else { continue }

                if hammingDistance(hash, otherHash) <= threshold {
                    cluster.append(otherId)
                    assigned.insert(otherId)
                }
            }

            clusters.append(cluster)
        }

        return clusters
    }
}
