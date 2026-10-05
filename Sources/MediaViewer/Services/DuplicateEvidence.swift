import Foundation
import CryptoKit
import GRDB
import Darwin
import ImageIO
import CoreGraphics

/// Content evidence is deliberately independent of capture context and human metadata.
/// An exact media-set match is not permission to discard either capture.
struct DuplicateEvidence: Codable, Hashable, Sendable {
    static let currentVersion = 1
    var version: Int = currentVersion
    var items: [DuplicateItemEvidence]
    var mediaSetDigest: String?
    var visualDistance: Int?
    var explanation: String

    var isCurrent: Bool { version == Self.currentVersion }
}

struct DuplicateItemEvidence: Codable, Hashable, Sendable {
    var itemID: UUID
    var mediaFilesJSON: String
    var contextImageString: String?
    var files: [DuplicateFileEvidence]
    var mediaSetDigest: String
}

struct DuplicateFileEvidence: Codable, Hashable, Sendable {
    var path: String
    var version: DuplicateFileVersion
    var sha256: String
    var visual: DuplicateVisualFingerprint?
}

struct DuplicateFileVersion: Codable, Hashable, Sendable {
    var device: UInt64
    var inode: UInt64
    var size: Int64
    var modifiedSeconds: Int64
    var modifiedNanos: Int64
    var changedSeconds: Int64
    var changedNanos: Int64

    static func read(_ url: URL) throws -> Self {
        var value = stat()
        guard url.isFileURL, stat(url.path, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFREG, value.st_size >= 0 else {
            throw DuplicateEvidenceError.unreadableFile(url.lastPathComponent)
        }
        return Self(device: UInt64(value.st_dev), inode: UInt64(value.st_ino), size: value.st_size,
                    modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanos: Int64(value.st_mtimespec.tv_nsec),
                    changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanos: Int64(value.st_ctimespec.tv_nsec))
    }
}

struct DuplicateVisualFingerprint: Codable, Hashable, Sendable {
    /// Bounded thumbnail DCT, not a semantic embedding and not byte identity.
    var hash: UInt64
    var aspectRatio: Double
    var meanLuminance: Double
    var contrast: Double
    var luminanceSketch: Data? = nil

    func hasSimilarStructure(to other: Self) -> Bool {
        guard let left = luminanceSketch, let right = other.luminanceSketch,
              left.count == 64, right.count == 64 else { return false }
        var leftSum = 0.0, rightSum = 0.0
        var leftSquares = 0.0, rightSquares = 0.0, cross = 0.0
        for (a, b) in zip(left, right) {
            let a = Double(a), b = Double(b)
            leftSum += a; rightSum += b
            leftSquares += a * a; rightSquares += b * b; cross += a * b
        }
        let leftVariance = leftSquares - leftSum * leftSum / 64
        let rightVariance = rightSquares - rightSum * rightSum / 64
        guard leftVariance > 0, rightVariance > 0 else { return false }
        // Mean/contrast normalization tolerates brightness changes and reencoding.
        let correlation = (cross - leftSum * rightSum / 64) / sqrt(leftVariance * rightVariance)
        return correlation >= 1 - 0.45 * 0.45 / 2
    }
}

enum DuplicateEvidenceError: LocalizedError {
    case unverified, stale, unreadableFile(String), invalidPrimary, scanAlreadyRunning
    var errorDescription: String? {
        switch self {
        case .unverified: return "This result predates verified content evidence. Scan again before reviewing it."
        case .stale: return "The files or group changed after this scan. Scan again before applying this decision."
        case .unreadableFile(let name): return "Could not read a stable regular file: \(name)."
        case .invalidPrimary: return "The chosen item is no longer an active member of this group."
        case .scanAlreadyRunning: return "A duplicate scan is already running."
        }
    }
}

/// Shared with review: refresh SHA-256 without trusting the stat cache before any mutation.
enum DuplicateEvidenceService {
    struct Source: Sendable {
        var id: UUID
        var mediaFilesJSON: String
        var contextImageString: String?

        static func fetch(in db: Database) throws -> [Source] {
            try Row.fetchAll(db, sql: "SELECT id, mediaFilesJSON, contextImageString FROM media_items WHERE COALESCE(deletedAt, '') = '' ORDER BY id").compactMap { row in
                guard let raw: String = row["id"], let id = UUID(uuidString: raw) else { return nil }
                return Source(id: id, mediaFilesJSON: row["mediaFilesJSON"], contextImageString: row["contextImageString"])
            }
        }

        var urls: [URL]? {
            guard let entries = try? JSONDecoder().decode([String].self, from: Data(mediaFilesJSON.utf8)), !entries.isEmpty else { return nil }
            var result: [URL] = []
            for entry in entries {
                guard !entry.isEmpty else { return nil }
                if let url = URL(string: entry), url.isFileURL { result.append(url.standardizedFileURL) }
                else if entry.hasPrefix("/") { result.append(URL(fileURLWithPath: entry).standardizedFileURL) }
                else { return nil }
            }
            return result
        }
    }

    static func revalidate(_ group: DuplicateGroup, db: DatabaseManager, allowingDeleted: Bool = false) async throws {
        guard let evidence = group.evidence, evidence.isCurrent,
              Set(evidence.items.map(\.itemID)) == Set(group.itemIds), group.itemIds.count >= 2 else {
            throw DuplicateEvidenceError.unverified
        }
        let itemIDs = group.itemIds
        let sources = try await db.read { database -> [Source] in
            var sources: [Source] = []
            for offset in stride(from: 0, to: itemIDs.count, by: 500) {
                let chunk = Array(itemIDs[offset..<min(offset + 500, itemIDs.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let predicate = allowingDeleted ? "" : " AND COALESCE(deletedAt, '') = ''"
                let rows = try Row.fetchAll(database, sql: "SELECT id, mediaFilesJSON, contextImageString FROM media_items WHERE id IN (\(placeholders))\(predicate)", arguments: StatementArguments(chunk.map(\.uuidString)))
                for row in rows {
                    let raw: String = row["id"]
                    guard let id = UUID(uuidString: raw) else { continue }
                    sources.append(Source(id: id, mediaFilesJSON: row["mediaFilesJSON"], contextImageString: row["contextImageString"]))
                }
            }
            return sources
        }
        let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        for item in evidence.items {
            try Task.checkCancellation()
            guard let source = byID[item.itemID], source.mediaFilesJSON == item.mediaFilesJSON,
                  source.contextImageString == item.contextImageString, let urls = source.urls,
                  urls.count == item.files.count else { throw DuplicateEvidenceError.stale }
            for (url, file) in zip(urls, item.files) {
                guard url.path == file.path, try DuplicateFileVersion.read(url) == file.version else { throw DuplicateEvidenceError.stale }
                let hashing = Task.detached(priority: .utility) { try sha256(url: url) }
                let digest = try await withTaskCancellationHandler(operation: { try await hashing.value }, onCancel: { hashing.cancel() })
                try Task.checkCancellation()
                guard digest == file.sha256, try DuplicateFileVersion.read(url) == file.version else { throw DuplicateEvidenceError.stale }
            }
        }
    }

    /// Transaction-time cheap guard after the asynchronous full-content revalidation.
    static func validateSnapshot(_ group: DuplicateGroup, in db: Database, allowingDeleted: Bool = false) throws {
        guard let evidence = group.evidence, evidence.isCurrent else { throw DuplicateEvidenceError.unverified }
        let currentIDs = try DuplicateGroupMemberRecord.fetchItemIds(db: db, groupId: group.id)
        guard Set(currentIDs) == Set(group.itemIds) else { throw DuplicateEvidenceError.stale }
        for item in evidence.items {
            let predicate = allowingDeleted ? "" : " AND COALESCE(deletedAt, '') = ''"
            guard let row = try Row.fetchOne(db, sql: "SELECT mediaFilesJSON, contextImageString FROM media_items WHERE id = ?\(predicate)", arguments: [item.itemID.uuidString]),
                  row["mediaFilesJSON"] as String == item.mediaFilesJSON,
                  row["contextImageString"] as String? == item.contextImageString else { throw DuplicateEvidenceError.stale }
            for file in item.files {
                guard try DuplicateFileVersion.read(URL(fileURLWithPath: file.path)) == file.version else { throw DuplicateEvidenceError.stale }
            }
        }
    }

    static func sha256(url: URL, cancellation: (() throws -> Void)? = nil) throws -> String {
        let before = try DuplicateFileVersion.read(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var readCount: Int64 = 0
        while true {
            try Task.checkCancellation()
            try cancellation?()
            // FileHandle's autoreleased NSData must be drained on every chunk, even
            // when called from a long-lived task with no surrounding run-loop pool.
            let count = try autoreleasepool {
                guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { return 0 }
                hasher.update(data: data)
                return data.count
            }
            if count == 0 { break }
            readCount += Int64(count)
        }
        guard readCount == before.size, try DuplicateFileVersion.read(url) == before else { throw DuplicateEvidenceError.stale }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func mediaSetDigest(_ files: [DuplicateFileEvidence]) -> String {
        // Sorted multiset, including repeated media. Captures with extra media never compare exact.
        digest(files.map { "\($0.version.size):\($0.sha256)" }.sorted().joined(separator: "\n"))
    }

    static func visualFingerprint(_ url: URL) -> DuplicateVisualFingerprint? {
        autoreleasepool { thumbnailFingerprint(url) }
    }

    private static func thumbnailFingerprint(_ url: URL) -> DuplicateVisualFingerprint? {
        // ImageIO downsamples during decode. No full-resolution raster, GPU, model, or video decode.
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "bmp", "tiff", "tif"]
        guard imageExtensions.contains(url.pathExtension.lowercased()),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 128,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        var pixels = [UInt8](repeating: 0, count: 32 * 32)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return true
        }
        guard drawn else { return nil }
        let mean = pixels.reduce(0.0) { $0 + Double($1) } / 1024
        let contrast = sqrt(pixels.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / 1024)
        // Flat/near-flat images are high-collision hashes, not useful near-copy evidence.
        guard contrast >= 6 else { return nil }
        let cosine = (0..<8).map { frequency in (0..<32).map { cos((Double($0) * 2 + 1) * Double(frequency) * .pi / 64) } }
        // Separable low-frequency DCT: ~10K multiplies, not 64 full 2-D passes.
        var horizontal = [Double](repeating: 0, count: 32 * 8)
        for y in 0..<32 { for u in 0..<8 {
            for x in 0..<32 { horizontal[y * 8 + u] += Double(pixels[y * 32 + x]) * cosine[u][x] }
        } }
        var coefficients: [Double] = []
        for v in 0..<8 { for u in 0..<8 {
            var value = 0.0
            for y in 0..<32 { value += horizontal[y * 8 + u] * cosine[v][y] }
            coefficients.append(value)
        } }
        let median = coefficients.dropFirst().sorted()[31]
        var hash: UInt64 = 0
        for index in 1..<64 where coefficients[index] > median { hash |= UInt64(1) << index }
        var sketch = [UInt8](repeating: 0, count: 64)
        for y in 0..<8 { for x in 0..<8 {
            var sum = 0
            for dy in 0..<4 { for dx in 0..<4 { sum += Int(pixels[(y * 4 + dy) * 32 + x * 4 + dx]) } }
            sketch[y * 8 + x] = UInt8((sum + 8) / 16)
        } }
        return DuplicateVisualFingerprint(hash: hash, aspectRatio: Double(image.width) / Double(image.height), meanLuminance: mean / 255, contrast: contrast / 255, luminanceSketch: Data(sketch))
    }
}
