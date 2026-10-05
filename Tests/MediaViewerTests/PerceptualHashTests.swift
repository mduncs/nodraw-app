import XCTest
import AppKit
@testable import MediaViewer

final class PerceptualHashTests: XCTestCase {

    // MARK: - Hamming Distance Tests

    func testHammingDistanceIdentical() {
        let hash = "abcdef0123456789"

        let distance = PerceptualHash.hammingDistance(hash, hash)

        XCTAssertEqual(distance, 0)
    }

    func testHammingDistanceOneBitDifferent() {
        // These differ by exactly one bit
        // 0x0000000000000000 vs 0x0000000000000001
        let hash1 = "0000000000000000"
        let hash2 = "0000000000000001"

        let distance = PerceptualHash.hammingDistance(hash1, hash2)

        XCTAssertEqual(distance, 1)
    }

    func testHammingDistanceMultipleBits() {
        // 0x0000000000000003 has bits 0 and 1 set
        // vs 0x0000000000000000 with no bits
        let hash1 = "0000000000000000"
        let hash2 = "0000000000000003"

        let distance = PerceptualHash.hammingDistance(hash1, hash2)

        XCTAssertEqual(distance, 2)
    }

    func testHammingDistanceMaximum() {
        // All zeros vs all ones
        let hash1 = "0000000000000000"
        let hash2 = "ffffffffffffffff"

        let distance = PerceptualHash.hammingDistance(hash1, hash2)

        XCTAssertEqual(distance, 64)
    }

    func testHammingDistanceInvalidHashLength() {
        let hash1 = "abc"
        let hash2 = "abcdef"

        let distance = PerceptualHash.hammingDistance(hash1, hash2)

        XCTAssertEqual(distance, Int.max)
    }

    func testHammingDistanceInvalidHexCharacters() {
        let hash1 = "gggggggggggggggg"  // 'g' is not hex
        let hash2 = "0000000000000000"

        let distance = PerceptualHash.hammingDistance(hash1, hash2)

        XCTAssertEqual(distance, Int.max)
    }

    func testHammingDistanceSymmetric() {
        let hash1 = "1234567890abcdef"
        let hash2 = "fedcba0987654321"

        let d1 = PerceptualHash.hammingDistance(hash1, hash2)
        let d2 = PerceptualHash.hammingDistance(hash2, hash1)

        XCTAssertEqual(d1, d2)
    }

    // MARK: - Similarity Tests

    func testAreSimilarWithIdenticalHashes() {
        let hash = "abcdef0123456789"

        XCTAssertTrue(PerceptualHash.areSimilar(hash, hash))
    }

    func testAreSimilarWithSmallDifference() {
        // 5 bits different - should be similar with default threshold of 10
        let hash1 = "000000000000001f"  // 5 bits set
        let hash2 = "0000000000000000"

        XCTAssertTrue(PerceptualHash.areSimilar(hash1, hash2))
    }

    func testAreSimilarWithLargeDifference() {
        // More than 10 bits different
        let hash1 = "00000000ffffffff"  // 32 bits set
        let hash2 = "0000000000000000"

        XCTAssertFalse(PerceptualHash.areSimilar(hash1, hash2))
    }

    func testAreSimilarWithCustomThreshold() {
        let hash1 = "000000000000001f"  // 5 bits different
        let hash2 = "0000000000000000"

        XCTAssertTrue(PerceptualHash.areSimilar(hash1, hash2, threshold: 5))
        XCTAssertFalse(PerceptualHash.areSimilar(hash1, hash2, threshold: 4))
    }

    func testAreSimilarWithExactThreshold() {
        // Exactly at threshold should be considered similar
        let hash1 = "00000000000003ff"  // 10 bits set
        let hash2 = "0000000000000000"

        XCTAssertTrue(PerceptualHash.areSimilar(hash1, hash2, threshold: 10))
    }

    // MARK: - Batch Duplicate Detection Tests

    func testFindDuplicatesEmpty() {
        let hashes: [String: String] = [:]

        let duplicates = PerceptualHash.findDuplicates(in: hashes)

        XCTAssertTrue(duplicates.isEmpty)
    }

    func testFindDuplicatesSingleItem() {
        let hashes = ["id1": "abcdef0123456789"]

        let duplicates = PerceptualHash.findDuplicates(in: hashes)

        XCTAssertTrue(duplicates.isEmpty)
    }

    func testFindDuplicatesWithIdentical() {
        let hashes = [
            "id1": "0000000000000000",
            "id2": "0000000000000000"
        ]

        let duplicates = PerceptualHash.findDuplicates(in: hashes)

        XCTAssertEqual(duplicates.count, 1)
        XCTAssertEqual(duplicates[0].2, 0)  // Distance should be 0
    }

    func testFindDuplicatesWithSimilar() {
        let hashes = [
            "id1": "0000000000000000",
            "id2": "0000000000000001",  // 1 bit different
            "id3": "ffffffffffffffff"   // Very different
        ]

        let duplicates = PerceptualHash.findDuplicates(in: hashes, threshold: 10)

        XCTAssertEqual(duplicates.count, 1)
        XCTAssertTrue(duplicates[0].0 == "id1" || duplicates[0].1 == "id1")
        XCTAssertTrue(duplicates[0].0 == "id2" || duplicates[0].1 == "id2")
    }

    func testFindDuplicatesSortedByDistance() {
        let hashes = [
            "id1": "0000000000000000",
            "id2": "0000000000000001",  // 1 bit from id1
            "id3": "000000000000000f"   // 4 bits from id1
        ]

        let duplicates = PerceptualHash.findDuplicates(in: hashes, threshold: 10)

        XCTAssertEqual(duplicates.count, 3)  // All pairs within threshold
        XCTAssertEqual(duplicates[0].2, 1)   // Smallest distance first
    }

    func testFindDuplicatesWithUUID() {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        let hashes: [UUID: String] = [
            id1: "0000000000000000",
            id2: "0000000000000001",
            id3: "ffffffffffffffff"
        ]

        let duplicates = PerceptualHash.findDuplicates(in: hashes, threshold: 5)

        XCTAssertEqual(duplicates.count, 1)
    }

    // MARK: - Clustering Tests

    func testClusterBySimilarityEmpty() {
        let hashes: [String: String] = [:]

        let clusters = PerceptualHash.clusterBySimilarity(hashes)

        XCTAssertTrue(clusters.isEmpty)
    }

    func testClusterBySimilaritySingleItem() {
        let hashes = ["id1": "abcdef0123456789"]

        let clusters = PerceptualHash.clusterBySimilarity(hashes)

        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0], ["id1"])
    }

    func testClusterBySimilarityIdenticalPair() {
        let hashes = [
            "id1": "0000000000000000",
            "id2": "0000000000000000"
        ]

        let clusters = PerceptualHash.clusterBySimilarity(hashes)

        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].count, 2)
    }

    func testClusterBySimilarityDistinctGroups() {
        let hashes = [
            "id1": "0000000000000000",
            "id2": "0000000000000001",  // Similar to id1
            "id3": "ffffffffffffffff",
            "id4": "ffffffffffffff00"   // Similar to id3
        ]

        let clusters = PerceptualHash.clusterBySimilarity(hashes, threshold: 10)

        XCTAssertEqual(clusters.count, 2)
        // Each cluster should have 2 items
        XCTAssertTrue(clusters.allSatisfy { $0.count == 2 })
    }

    func testClusterBySimilarityAllUnique() {
        let hashes = [
            "id1": "0000000000000000",
            "id2": "ffffffffffffffff",
            "id3": "00000000ffffffff"
        ]

        // With threshold=1, these should all be separate
        let clusters = PerceptualHash.clusterBySimilarity(hashes, threshold: 1)

        XCTAssertEqual(clusters.count, 3)
        XCTAssertTrue(clusters.allSatisfy { $0.count == 1 })
    }

    func testClusterBySimilarityTransitive() {
        // Test that if A~B and B~C, they end up in same cluster
        let hashes = [
            "id1": "0000000000000000",
            "id2": "0000000000000007",  // 3 bits from id1
            "id3": "000000000000000e"   // Close to id2 but further from id1
        ]

        let clusters = PerceptualHash.clusterBySimilarity(hashes, threshold: 10)

        // Should all be in one cluster due to chaining
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].count, 3)
    }

    // MARK: - Hash Format Tests

    func testHashFormatValidation() {
        // Valid hash should be 16 hex characters
        let validHash = "abcdef0123456789"
        let distance = PerceptualHash.hammingDistance(validHash, validHash)
        XCTAssertEqual(distance, 0)

        // Test all uppercase
        let upperHash = "ABCDEF0123456789"
        let distanceUpper = PerceptualHash.hammingDistance(validHash, upperHash)
        // Should work case-insensitively? Actually Swift's UInt64(radix:) is case insensitive
        XCTAssertEqual(distanceUpper, 0)
    }

    // MARK: - Edge Cases

    func testEmptyHashes() {
        let distance = PerceptualHash.hammingDistance("", "")
        XCTAssertEqual(distance, Int.max)
    }

    func testMixedCaseHashes() {
        let hash1 = "AbCdEf0123456789"
        let hash2 = "abcdef0123456789"

        // UInt64(radix:) is case-insensitive, so these should be equal
        let distance = PerceptualHash.hammingDistance(hash1, hash2)
        XCTAssertEqual(distance, 0)
    }

    // MARK: - Bit Counting Accuracy

    func testBitCountingAccuracy() {
        // Known values with specific bit counts
        let testCases: [(String, String, Int)] = [
            ("0000000000000000", "0000000000000001", 1),   // 1 bit
            ("0000000000000000", "0000000000000003", 2),   // 2 bits
            ("0000000000000000", "0000000000000007", 3),   // 3 bits
            ("0000000000000000", "000000000000000f", 4),   // 4 bits
            ("0000000000000000", "00000000000000ff", 8),   // 8 bits
            ("0000000000000000", "000000000000ffff", 16),  // 16 bits
            ("0000000000000000", "00000000ffffffff", 32),  // 32 bits
        ]

        for (hash1, hash2, expected) in testCases {
            let distance = PerceptualHash.hammingDistance(hash1, hash2)
            XCTAssertEqual(distance, expected, "Failed for \(hash1) vs \(hash2)")
        }
    }

    // MARK: - Integration Test Helpers

    /// Helper to create a mock image file for testing (actual implementation would need real images)
    private func createMockImageFile() -> URL? {
        // This would create a temporary image file for testing
        // In actual tests, you'd use test fixtures
        return nil
    }
}

// MARK: - Async Hash Computation Tests

extension PerceptualHashTests {

    func testComputeHashFileNotFound() async {
        let nonExistentURL = URL(fileURLWithPath: "/nonexistent/path/image.jpg")

        do {
            _ = try await PerceptualHash.computeHash(from: nonExistentURL)
            XCTFail("Expected error for non-existent file")
        } catch {
            // Expected - file not found error
            XCTAssertTrue(error is VisionError)
            if case VisionError.fileNotFound = error {
                // Correct error type
            } else {
                XCTFail("Expected fileNotFound error, got \(error)")
            }
        }
    }

    // Note: Testing actual hash computation requires real image files.
    // These tests would typically use test fixtures or create temp images.
    // For now we test only the sync/algorithm parts and file-not-found handling.

    func testComputeHashWithTempImage() async throws {
        // Create a temporary test image programmatically
        let tempDir = FileManager.default.temporaryDirectory
        let imageURL = tempDir.appendingPathComponent("test_perceptual_hash_\(UUID().uuidString).png")

        // Create a simple 100x100 image
        guard createTestImage(at: imageURL, width: 100, height: 100) else {
            // If we can't create an image, skip this test
            return
        }

        defer {
            try? FileManager.default.removeItem(at: imageURL)
        }

        let hash = try await PerceptualHash.computeHash(from: imageURL)

        // DCT pHash should be 26 hex characters (99 bits padded to 104 bits)
        XCTAssertEqual(hash.count, 26)
        XCTAssertTrue(hash.allSatisfy { $0.isHexDigit })
    }

    func testSameImageProducesSameHash() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let imageURL = tempDir.appendingPathComponent("test_same_hash_\(UUID().uuidString).png")

        guard createTestImage(at: imageURL, width: 100, height: 100) else {
            return
        }

        defer {
            try? FileManager.default.removeItem(at: imageURL)
        }

        let hash1 = try await PerceptualHash.computeHash(from: imageURL)
        let hash2 = try await PerceptualHash.computeHash(from: imageURL)

        XCTAssertEqual(hash1, hash2)
    }

    // Helper to create a simple test image
    private func createTestImage(at url: URL, width: Int, height: Int) -> Bool {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return false
        }

        // Fill with a gradient pattern
        for y in 0..<height {
            for x in 0..<width {
                context.setFillColor(red: CGFloat(x) / CGFloat(width),
                                     green: CGFloat(y) / CGFloat(height),
                                     blue: 0.5,
                                     alpha: 1.0)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }

        guard let cgImage = context.makeImage() else {
            return false
        }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return false
        }

        do {
            try pngData.write(to: url)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Performance Tests

extension PerceptualHashTests {

    func testHammingDistancePerformance() {
        let hash1 = "abcdef0123456789"
        let hash2 = "fedcba9876543210"

        measure {
            for _ in 0..<10000 {
                _ = PerceptualHash.hammingDistance(hash1, hash2)
            }
        }
    }

    func testFindDuplicatesPerformance() {
        // Generate 100 random hashes
        var hashes: [Int: String] = [:]
        for i in 0..<100 {
            let value = UInt64.random(in: 0...UInt64.max)
            hashes[i] = String(format: "%016llx", value)
        }

        measure {
            _ = PerceptualHash.findDuplicates(in: hashes, threshold: 10)
        }
    }

    func testClusteringPerformance() {
        var hashes: [Int: String] = [:]
        for i in 0..<100 {
            let value = UInt64.random(in: 0...UInt64.max)
            hashes[i] = String(format: "%016llx", value)
        }

        measure {
            _ = PerceptualHash.clusterBySimilarity(hashes, threshold: 10)
        }
    }
}

// MARK: - Hash Consistency Tests

extension PerceptualHashTests {

    func testZeroHashFormat() {
        // Zero should produce 16 zeros
        let expected = "0000000000000000"
        let distance = PerceptualHash.hammingDistance(expected, expected)
        XCTAssertEqual(distance, 0)
    }

    func testMaxHashFormat() {
        // Max value should be all f's
        let expected = "ffffffffffffffff"
        let distance = PerceptualHash.hammingDistance(expected, expected)
        XCTAssertEqual(distance, 0)
    }
}
