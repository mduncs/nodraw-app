import Foundation
import Combine

/// In-memory ownership of unfinished editor sessions across view replacement.
/// This is retry recovery, not durable recovery after quitting the application.
@MainActor
final class AnnotationSessionRegistry: ObservableObject {
    static let shared = AnnotationSessionRegistry()

    struct RetainedSession: Identifiable {
        let id = UUID()
        let session: AnnotationEditorSession
        let sourceURL: URL
    }

    @Published private(set) var failedSessions: [RetainedSession] = []
    @Published private(set) var retainedCount = 0

    private struct Key: Hashable {
        let itemID: UUID
        let assetID: UUID?
        let legacyIndex: Int?
        let sourceURL: URL

        init(itemID: UUID, assetID: UUID?, index: Int, sourceURL: URL) {
            self.itemID = itemID
            self.assetID = assetID
            self.legacyIndex = assetID == nil ? index : nil
            self.sourceURL = sourceURL.standardizedFileURL
        }
    }

    private var sessions: [Key: RetainedSession] = [:]
    private var observations: [Key: AnyCancellable] = [:]
    private var errors: [Key: String] = [:]

    func session(itemID: UUID, assetID: UUID?, index: Int, sourceURL: URL) -> AnnotationEditorSession? {
        sessions[Key(itemID: itemID, assetID: assetID, index: index, sourceURL: sourceURL)]?.session
    }

    /// Call before releasing the view's ownership, not from a detached teardown task.
    func retain(_ session: AnnotationEditorSession, sourceURL: URL) {
        let key = Key(itemID: session.itemId, assetID: session.assetID, index: session.mediaFileIndex, sourceURL: sourceURL)
        guard session.isDirty || session.isSaving || session.saveError != nil else {
            releaseIfClean(session)
            return
        }
        if sessions[key]?.session === session { return }
        sessions[key] = RetainedSession(session: session, sourceURL: sourceURL)
        retainedCount = sessions.count
        observations[key] = session.$saveError.combineLatest(session.$isDirty, session.$isSaving)
            .sink { [weak self, weak session] error, dirty, saving in
                guard let self, let session, self.sessions[key]?.session === session else { return }
                // Use published values: @Published emits before its stored value changes.
                if !dirty && !saving && error == nil {
                    self.remove(key)
                } else {
                    self.errors[key] = error
                    self.publishFailures()
                }
            }
    }

    /// A successful older save is not enough if the user edited during its await.
    func releaseIfClean(_ session: AnnotationEditorSession) {
        guard !session.isDirty, !session.isSaving, session.saveError == nil else { return }
        for key in sessions.keys.filter({ sessions[$0]?.session === session }) { remove(key) }
    }

    /// Explicit retry for retained sessions. Each failure remains available in
    /// failedSessions; another session's failure never prevents later retries.
    func flush() async {
        let retained = Array(sessions.values)
        for entry in retained {
            do {
                try await entry.session.saveNow()
                releaseIfClean(entry.session)
            } catch {
                // AnnotationEditorSession publishes the actionable save error.
            }
        }
    }

    private func remove(_ key: Key) {
        observations.removeValue(forKey: key)?.cancel()
        sessions.removeValue(forKey: key)
        errors.removeValue(forKey: key)
        retainedCount = sessions.count
        publishFailures()
    }

    private func publishFailures() {
        failedSessions = sessions.compactMap { key, entry in errors[key] == nil ? nil : entry }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }
}
