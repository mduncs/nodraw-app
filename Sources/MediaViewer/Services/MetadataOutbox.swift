import Foundation
import GRDB

/// The database is the acceptance boundary. Triggers cover raw SQL, batch edits,
/// annotation writes, and callers interrupted before they can wake WriteBackQueue.
enum MetadataOutbox {
    enum Source: Sendable { case user, sidecar }

    struct Intent: Sendable {
        let itemID: String
        let path: String
        let field: String
        let revision: Int64
        let baseJSON: String
        let desiredJSON: String
    }

    struct Status: Sendable {
        let itemID: String
        let metadataPath: String
        let field: String
        let revision: Int64
        let state: String
        let error: String?
        let externalJSON: String?
        let baseJSON: String
        let desiredJSON: String
    }

    static func install(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE metadata_projection_context (id INTEGER PRIMARY KEY CHECK(id = 1), importing INTEGER NOT NULL);
            INSERT INTO metadata_projection_context VALUES (1, 0);
            CREATE TABLE metadata_projection_clock (id INTEGER PRIMARY KEY CHECK(id = 1), revision INTEGER NOT NULL);
            INSERT INTO metadata_projection_clock VALUES (1, 0);
            CREATE TABLE metadata_outbox (
                itemID TEXT NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
                field TEXT NOT NULL, revision INTEGER NOT NULL,
                baseJSON TEXT NOT NULL, desiredJSON TEXT NOT NULL,
                state TEXT NOT NULL DEFAULT 'pending', error TEXT, externalJSON TEXT,
                PRIMARY KEY(itemID, field)
            );
            CREATE TABLE metadata_projection_conflicts (
                itemID TEXT NOT NULL, field TEXT NOT NULL, revision INTEGER NOT NULL,
                baseJSON TEXT NOT NULL, desiredJSON TEXT NOT NULL, externalJSON TEXT NOT NULL,
                detectedAt TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                UNIQUE(itemID, field, revision, externalJSON)
            );
            """)
        let fields: [(String, String, String)] = [
            ("tags", "COALESCE(OLD.tagsJSON, '[]')", "COALESCE(NEW.tagsJSON, '[]')"),
            ("notes", "json_quote(NULLIF(OLD.notes, ''))", "json_quote(NULLIF(NEW.notes, ''))"),
            ("starred", "CASE WHEN OLD.starred THEN 'true' ELSE 'false' END", "CASE WHEN NEW.starred THEN 'true' ELSE 'false' END"),
            ("deleted", "CASE WHEN COALESCE(OLD.deletedAt, '') != '' THEN 'true' ELSE 'false' END", "CASE WHEN COALESCE(NEW.deletedAt, '') != '' THEN 'true' ELSE 'false' END")
        ]
        for (field, before, after) in fields {
            try db.execute(sql: """
                CREATE TRIGGER metadata_intent_\(field) AFTER UPDATE ON media_items
                WHEN (SELECT importing FROM metadata_projection_context WHERE id = 1) = 0
                  AND (\(before)) IS NOT (\(after))
                BEGIN
                    \(captureSQL(item: "NEW.id", field: field, before: before, after: after))
                END;
                """)
        }
        for (event, ref, before, after, condition) in [
            ("INSERT", "NEW", "'false'", "'true'", "(SELECT COUNT(*) FROM annotations WHERE itemId = NEW.itemId) = 1"),
            ("DELETE", "OLD", "'true'", "'false'", "NOT EXISTS(SELECT 1 FROM annotations WHERE itemId = OLD.itemId)")
        ] {
            try db.execute(sql: """
                CREATE TRIGGER metadata_intent_annotation_\(event) AFTER \(event) ON annotations
                WHEN \(condition) AND EXISTS(SELECT 1 FROM media_items WHERE id = \(ref).itemId)
                  AND (SELECT importing FROM metadata_projection_context WHERE id = 1) = 0
                BEGIN
                    \(captureSQL(item: "\(ref).itemId", field: "annotated", before: before, after: after))
                END;
                """)
        }
        // Combine/reindex can transfer existing annotation rows without INSERT
        // or DELETE. Capture the old/new archive's first/last annotation flags.
        for (name, ref, before, after, condition) in [
            ("from", "OLD", "'true'", "'false'", "NOT EXISTS(SELECT 1 FROM annotations WHERE itemId = OLD.itemId)"),
            ("to", "NEW", "'false'", "'true'", "(SELECT COUNT(*) FROM annotations WHERE itemId = NEW.itemId) = 1")
        ] {
            try db.execute(sql: """
                CREATE TRIGGER metadata_intent_annotation_move_\(name) AFTER UPDATE OF itemId ON annotations
                WHEN OLD.itemId != NEW.itemId AND \(condition)
                  AND EXISTS(SELECT 1 FROM media_items WHERE id = \(ref).itemId)
                  AND (SELECT importing FROM metadata_projection_context WHERE id = 1) = 0
                BEGIN
                    \(captureSQL(item: "\(ref).itemId", field: "annotated", before: before, after: after))
                END;
                """)
        }
    }

    private static func captureSQL(item: String, field: String, before: String, after: String) -> String {
        """
        UPDATE metadata_projection_clock SET revision = revision + 1 WHERE id = 1;
        INSERT INTO metadata_outbox(itemID, field, revision, baseJSON, desiredJSON)
        VALUES (\(item), '\(field)', (SELECT revision FROM metadata_projection_clock WHERE id = 1), \(before), \(after))
        ON CONFLICT(itemID, field) DO UPDATE SET
            revision = excluded.revision,
            baseJSON = CASE WHEN metadata_outbox.state = 'synced' THEN excluded.baseJSON ELSE metadata_outbox.baseJSON END,
            desiredJSON = excluded.desiredJSON, state = 'pending', error = NULL, externalJSON = NULL;
        """
    }

    /// Only call inside the same write transaction as the imported record update.
    static func importing<T>(in db: Database, _ body: () throws -> T) throws -> T {
        try db.execute(sql: "UPDATE metadata_projection_context SET importing = 1 WHERE id = 1")
        do {
            let result = try body()
            try db.execute(sql: "UPDATE metadata_projection_context SET importing = 0 WHERE id = 1")
            return result
        } catch {
            try? db.execute(sql: "UPDATE metadata_projection_context SET importing = 0 WHERE id = 1")
            throw error
        }
    }

    static func acknowledge(_ intent: Intent, in db: Database) throws {
        // A concurrent edit keeps its newer revision and desired value; only its
        // base advances to the value we actually published under the file lock.
        try db.execute(sql: """
            UPDATE metadata_outbox SET baseJSON = ?,
                state = CASE WHEN revision = ? THEN 'synced' ELSE 'pending' END,
                error = NULL, externalJSON = NULL
            WHERE itemID = ? AND field = ? AND revision >= ?
            """, arguments: [intent.desiredJSON, intent.revision, intent.itemID, intent.field, intent.revision])
    }
}
