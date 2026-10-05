import Foundation
import GRDB

enum SafetyAttributes {
    // Keep aligned with PhotoPipeline.SafetyClassifier's verified exact identifiers.
    static let sensitiveIdentifiers: Set<String> = ["sword"]

    static func canonicalize(_ attributes: [MediaAttribute], itemId: UUID) -> [MediaAttribute] {
        let categories = attributes.filter {
            $0.module == PipelineModule.safety.rawValue
                && sensitiveIdentifiers.contains($0.key) && $0.value > 0.1
        }
        return categories + [MediaAttribute(
            itemId: itemId,
            module: .safety,
            key: "is_safe",
            value: categories.contains { $0.value >= 0.5 } ? 0 : 1
        )]
    }

    static func repairLegacyFlags(in db: Database) throws {
        // Freeze this migration's set so future classifier changes cannot alter it.
        // Create missing flags before removing categories to retain category-only items.
        try db.execute(sql: """
            INSERT INTO media_attributes (item_id, module, key, value)
            SELECT DISTINCT item_id, 'safety', 'is_safe', 1
            FROM media_attributes WHERE module = 'safety'
            ON CONFLICT(item_id, module, key) DO NOTHING;

            DELETE FROM media_attributes
            WHERE module = 'safety' AND key NOT IN ('is_safe', 'sword');

            UPDATE media_attributes AS flag
            SET value = CASE WHEN EXISTS (
                SELECT 1 FROM media_attributes AS category
                WHERE category.item_id = flag.item_id AND category.module = 'safety'
                  AND category.key = 'sword' AND category.value >= 0.5
            ) THEN 0 ELSE 1 END
            WHERE flag.module = 'safety' AND flag.key = 'is_safe';
            """)
    }
}
