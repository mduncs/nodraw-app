import Foundation

/// Selection identity shared by the hold-to-tag picker and its grid/detail callers.
/// Display spelling must never turn a removal into an addition.
enum TagOverlaySelection {
    static func contains(_ name: String, in tags: [String]) -> Bool {
        let key = TagCanonicalizer.key(name)
        return !key.isEmpty && tags.contains { TagCanonicalizer.key($0) == key }
    }

    static func toggled(_ name: String, in tags: [String]) -> [String] {
        let key = TagCanonicalizer.key(name)
        guard !key.isEmpty else { return tags }
        if contains(name, in: tags) {
            return tags.filter { TagCanonicalizer.key($0) != key }
        }
        return tags + [TagCanonicalizer.displayName(name)]
    }

    static func changes(from old: [String], to new: [String]) -> (added: [String], removed: [String]) {
        func indexed(_ tags: [String]) -> [String: String] {
            Dictionary(tags.compactMap { name in
                let key = TagCanonicalizer.key(name)
                return key.isEmpty ? nil : (key, TagCanonicalizer.displayName(name))
            }, uniquingKeysWith: { first, _ in first })
        }
        let oldByKey = indexed(old), newByKey = indexed(new)
        return (
            newByKey.keys.filter { oldByKey[$0] == nil }.sorted().compactMap { newByKey[$0] },
            oldByKey.keys.filter { newByKey[$0] == nil }.sorted().compactMap { oldByKey[$0] }
        )
    }
}
