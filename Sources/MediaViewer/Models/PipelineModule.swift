import Foundation

// MARK: - Pipeline Module

/// ML analysis modules available in the photo pipeline.
/// Each module writes results to the `media_attributes` EAV table
/// with module as the namespace and key as the specific label/property.
enum PipelineModule: String, CaseIterable, Codable, Sendable {
    case scene
    case object
    case face
    case safety
    case quality
    case curation
    case junk
    case meme
    case caption
    case fingerprint
    case bodyPose = "body_pose"
    case animal
    case document
    case barcode
}

// MARK: - Attribute Filter

/// Filter condition for querying `media_attributes`.
/// Generates an EXISTS subquery for composition with other WHERE clauses.
struct AttributeFilter: Equatable, Sendable {
    let module: PipelineModule
    let key: String
    let minValue: Double
    let maxValue: Double?

    init(module: PipelineModule, key: String, minValue: Double = 0, maxValue: Double? = nil) {
        self.module = module
        self.key = key
        self.minValue = minValue
        self.maxValue = maxValue
    }

    /// Generate SQL EXISTS subquery for this filter.
    /// Returns (sql, arguments) for composition.
    func sqlCondition() -> (sql: String, arguments: [any Sendable]) {
        var sql = """
            EXISTS (
                SELECT 1 FROM media_attributes
                WHERE media_attributes.item_id = media_items.id
                  AND media_attributes.module = ?
                  AND media_attributes.key = ?
                  AND media_attributes.value >= ?
            """
        var args: [any Sendable] = [module.rawValue, key, minValue]

        if let maxValue = maxValue {
            sql += "\n          AND media_attributes.value <= ?"
            args.append(maxValue)
        }

        sql += "\n    )"
        return (sql, args)
    }
}

// MARK: - Pipeline Status

/// Processing status for an item in the ML pipeline.
enum PipelineStatus: String, Codable, Sendable {
    case none
    case phase1
    case phase2
    case complete
    case failed
}
