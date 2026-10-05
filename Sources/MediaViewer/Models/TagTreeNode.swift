import SwiftUI

/// Lightweight wrapper for tree display and keyboard-driven tag selection.
/// Not stored -- computed from TagDefinition + TagSettings tree methods.
struct TagTreeNode: Identifiable {
    let definition: TagDefinition
    var children: [TagTreeNode]
    var depth: Int
    var keyBinding: Character?  // assigned dynamically during tagging mode

    var id: UUID { definition.id }
    var name: String { definition.name }
    var color: Color { definition.color }
    var isLeaf: Bool { children.isEmpty }

    /// Build a full tree from TagSettings
    @MainActor
    static func buildTree(from settings: TagSettings) -> [TagTreeNode] {
        return buildLevel(parentId: nil, depth: 0, settings: settings)
    }

    @MainActor
    private static func buildLevel(parentId: UUID?, depth: Int, settings: TagSettings) -> [TagTreeNode] {
        let tags = parentId == nil ? settings.rootTags() : settings.children(of: parentId!)
        return tags.map { tag in
            TagTreeNode(
                definition: tag,
                children: buildLevel(parentId: tag.id, depth: depth + 1, settings: settings),
                depth: depth,
                keyBinding: nil
            )
        }
    }

    /// Key sequence for keyboard mapping: 1-9, 0, then q-p
    static let keySequence: [Character] = [
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "0",
        "q", "w", "e", "r", "t", "y", "u", "i", "o", "p"
    ]

    /// Assign sibling-level key bindings. Valid explicit overrides claim their key first;
    /// remaining nodes receive the first free key in the stable sequence.
    static func assignKeyBindings(to nodes: inout [TagTreeNode]) {
        var claimed = Set<Character>()
        for index in nodes.indices {
            nodes[index].keyBinding = nil
            guard let preferred = TagSettings.normalizedShortcut(nodes[index].definition.shortcutKey),
                  claimed.insert(preferred).inserted else { continue }
            nodes[index].keyBinding = preferred
        }

        var available = keySequence.filter { !claimed.contains($0) }.makeIterator()
        for index in nodes.indices where nodes[index].keyBinding == nil {
            guard let key = available.next() else { break }
            nodes[index].keyBinding = key
        }
    }
}
