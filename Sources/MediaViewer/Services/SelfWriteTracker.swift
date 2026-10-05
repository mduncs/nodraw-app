import Foundation
import CryptoKit

// MARK: - Self-Write Tracker

/// Tracks paths recently written by the app so ArchiveWatcher can skip
/// identify our own frontmatter updates. Exact content receipts ensure even an
/// external edit in the same timestamp tick is never misclassified as ours.
actor SelfWriteTracker {
    private struct Receipt {
        let writtenAt: Date
        let digest: SHA256.Digest
    }
    private var recentWrites: [String: Receipt] = [:]
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 5.0) {
        self.ttl = ttl
    }

    /// Mark a path as recently written by the app.
    func markWritten(_ path: String) {
        guard let content = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        recentWrites[canonicalize(path)] = Receipt(writtenAt: Date(), digest: SHA256.hash(data: content))
        cleanupIfNeeded()
    }

    /// Record bytes actually published, not a time sampled before file IO.
    func markPublished(_ path: String, content: String) {
        recentWrites[canonicalize(path)] = Receipt(writtenAt: Date(), digest: SHA256.hash(data: Data(content.utf8)))
        cleanupIfNeeded()
    }

    /// Check if a path was written by us within the TTL window.
    /// Returns true only if: (1) within TTL, AND (2) file bytes match our write
    /// (no external modification since our write).
    func shouldSkip(_ path: String) -> Bool {
        cleanupIfNeeded()

        let resolved = canonicalize(path)
        guard let receipt = recentWrites[resolved] else { return false }

        if Date().timeIntervalSince(receipt.writtenAt) < ttl {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: resolved)),
                  SHA256.hash(data: data) == receipt.digest else {
                recentWrites.removeValue(forKey: resolved)
                return false
            }
            return true
        } else {
            // Expired — external edit or delayed FSEvents delivery
            recentWrites.removeValue(forKey: resolved)
            return false
        }
    }

    /// Remove expired entries to prevent unbounded growth.
    private func cleanupIfNeeded() {
        guard recentWrites.count > 50 else { return }
        let cutoff = Date().addingTimeInterval(-ttl)
        recentWrites = recentWrites.filter { $0.value.writtenAt > cutoff }
    }

    /// Resolve symlinks so FSEvents paths and DB paths match even through symlinked vaults.
    private func canonicalize(_ path: String) -> String {
        (path as NSString).resolvingSymlinksInPath
    }
}
