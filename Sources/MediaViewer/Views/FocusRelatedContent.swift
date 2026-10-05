import SwiftUI

struct FocusRelatedSections {
    var author: [MediaItem] = []
    var authorTotal = 0
    var similar: [MediaItem] = []
    var folder: [MediaItem] = []
    var tags: [MediaItem] = []

    var authorRemaining: Int { max(0, authorTotal - author.count) }
    var hasPrimaryItems: Bool { !author.isEmpty || !similar.isEmpty }

    static func make(author: [MediaItem], authorTotal: Int, similar: [MediaItem],
                     folder: [MediaItem], tags: [MediaItem], excluding focusedID: UUID? = nil,
                     limit: Int = 12) -> Self {
        var seen = Set([focusedID].compactMap { $0 })
        func take(_ items: [MediaItem]) -> [MediaItem] {
            var result: [MediaItem] = []
            for item in items where result.count < max(0, limit) && seen.insert(item.id).inserted {
                result.append(item)
            }
            return result
        }
        let authors = take(author)
        let similarItems = take(similar)
        let folders = take(folder)
        return Self(author: authors, authorTotal: max(authorTotal, authors.count),
            similar: similarItems, folder: folders, tags: take(tags))
    }
}

/// Renders loaded sections without starting database queries. Snapshot callers can supply
/// static thumbnails; the production sidebar supplies cached media thumbnails by default.
struct FocusRelatedContent: View {
    let item: MediaItem
    let sections: FocusRelatedSections
    var isLoading = false
    @Binding var moreExpanded: Bool
    var onItemSelected: (MediaItem) -> Void
    var onShowAuthor: (String) -> Void
    var thumbnail: ((MediaItem) -> AnyView)?
    /// The Info/Related tabs already name the panel when both are shown.
    var showsHeader = true

    init(item: MediaItem, sections: FocusRelatedSections, isLoading: Bool = false, showsHeader: Bool = true,
         moreExpanded: Binding<Bool> = .constant(false),
         onItemSelected: @escaping (MediaItem) -> Void = { _ in },
         onShowAuthor: @escaping (String) -> Void = { _ in },
         thumbnail: ((MediaItem) -> AnyView)? = nil) {
        self.item = item
        self.sections = sections
        self.isLoading = isLoading
        self.showsHeader = showsHeader
        _moreExpanded = moreExpanded
        self.onItemSelected = onItemSelected
        self.onShowAuthor = onShowAuthor
        self.thumbnail = thumbnail
    }

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                Text("related")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .accessibilityAddTraits(.isHeader)
            }

            if !sections.author.isEmpty, let author = item.metadata.author {
                section(title: "Same author", subtitle: author, icon: "person", items: sections.author)
                if sections.authorRemaining > 0 {
                    Button("\(sections.authorRemaining) more") { onShowAuthor(author) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.accentOrange)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                        .accessibilityLabel("Show \(sections.authorRemaining) more items by \(author)")
                }
            }
            if !sections.similar.isEmpty {
                section(title: "Similar", icon: "sparkles", items: sections.similar)
            }
            if !sections.hasPrimaryItems {
                Text(isLoading ? "Finding related items…" : "No same-author or similar items yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }

            Divider().background(Color.white.opacity(0.1))
            DisclosureGroup(isExpanded: $moreExpanded) {
                if !sections.folder.isEmpty {
                    section(title: "Same folder",
                        subtitle: item.basePath.deletingLastPathComponent().lastPathComponent,
                        icon: "folder", items: sections.folder)
                }
                if !sections.tags.isEmpty {
                    section(title: "Shared tags", icon: "tag", items: sections.tags)
                }
                if sections.folder.isEmpty && sections.tags.isEmpty && !isLoading {
                    Text("No folder or tag matches")
                        .font(.caption).foregroundStyle(.tertiary)
                        .padding(.vertical, 8)
                }
            } label: {
                Text("More (same folder · shared tags)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0x1f1f1f))
    }

    private func section(title: String, subtitle: String? = nil, icon: String,
                         items: [MediaItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().background(Color.white.opacity(0.1))
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption2).foregroundStyle(.secondary)
                Text(title).font(.caption).foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 4)
                Text("\(items.count)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            .padding(.top, 6)
            .accessibilityElement(children: .combine)
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(subtitle)
            }
            LazyVGrid(columns: Self.columns, spacing: 4) {
                ForEach(items) { related in
                    Button { onItemSelected(related) } label: {
                        if let thumbnail { thumbnail(related) }
                        else { AnyView(RelatedItemThumbnail(item: related)) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(related.metadata.author.map { "\($0), \(related.folderName)" } ?? related.folderName)
                    .accessibilityHint("Opens this item")
                }
            }
            .padding(.bottom, 10)
        }
        .padding(.horizontal, 12)
    }
}

private struct RelatedItemThumbnail: View {
    let item: MediaItem
    @State private var isHovered = false

    var body: some View {
        CachedImageView(item: item, size: .small, contentMode: .fill)
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isHovered ? Color.accentOrange.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .help(item.metadata.author ?? item.folderName)
    }
}
