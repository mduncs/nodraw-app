import Foundation

/// Shared startup/runtime ownership rules. A numbered name is not an item identity:
/// explicit sidecars and links claim their files before conservative gallery inference.
enum ArchiveAssociationResolver {
    private static let gallerySuffix = try! NSRegularExpression(pattern: #"^(.+)[_-][1-9][0-9]*$"#)
    private static let embed = try! NSRegularExpression(pattern: #"!\[\[([^\]]+)\]\]"#)

    static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func items(in directory: URL, archivePath: URL) -> [URL: ArchiveItemFiles] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )) ?? []
        return resolve(urls, archivePath: archivePath)
    }

    static func files(for metadataURL: URL, archivePath: URL) -> ArchiveItemFiles? {
        let key = URL(fileURLWithPath: canonicalPath(metadataURL)).deletingPathExtension()
        return items(in: metadataURL.deletingLastPathComponent(), archivePath: archivePath)[key]
    }

    static func owner(of mediaURL: URL, archivePath: URL) -> URL? {
        let path = canonicalPath(mediaURL)
        let owners = items(in: mediaURL.deletingLastPathComponent(), archivePath: archivePath).values.filter { files in
            files.mediaFiles.contains { canonicalPath($0) == path }
                || files.contextImage.map { canonicalPath($0) == path } == true
        }.compactMap(\.metadataFile)
        return owners.count == 1 ? owners[0] : nil
    }

    static func resolve(_ input: [URL], archivePath: URL) -> [URL: ArchiveItemFiles] {
        let urls = input.filter { url in
            guard !ArchiveWatcher.isHiddenArchivePath(url, archivePath: archivePath),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
            let ext = url.pathExtension.lowercased()
            return ImportService.supportedExtensions.contains(ext)
                || (ext == "md" && url.lastPathComponent.lowercased() != "index.md")
        }.map { URL(fileURLWithPath: canonicalPath($0)) }.sorted { $0.path < $1.path }
        let allSidecars = urls.filter { $0.pathExtension.lowercased() == "md" }
        let media = urls.filter { $0.pathExtension.lowercased() != "md" }
        let mediaPaths = Set(media.map(\.path))
        let postKeys = Set(allSidecars.filter { !isContext($0) }.map { $0.deletingPathExtension() })
        var absorbed: [URL: URL] = [:]
        for sidecar in allSidecars where isContext(sidecar) {
            guard let source = generatedContextSidecarSource(at: sidecar),
                  mediaPaths.contains(source.path) else { continue }
            let stem = contextStem(source)
            let directory = sidecar.deletingLastPathComponent()
            let exact = directory.appendingPathComponent(stem)
            let numbered = galleryBase(stem).map { directory.appendingPathComponent($0) }
            if postKeys.contains(exact) { absorbed[sidecar] = exact }
            else if let numbered, postKeys.contains(numbered) { absorbed[sidecar] = numbered }
        }
        let sidecars = allSidecars.filter { absorbed[$0] == nil }
        var groups: [URL: ArchiveItemFiles] = [:]
        var exactOwners: [String: URL] = [:]
        var claimed = Set<String>()
        let keys = Set(sidecars.map { $0.deletingPathExtension() })
        for sidecar in sidecars { groups[sidecar.deletingPathExtension()] = ArchiveItemFiles(metadataFile: sidecar) }
        for sidecar in allSidecars {
            if let owner = absorbed[sidecar] { groups[owner]?.absorbedContextSidecars.append(sidecar) }
        }

        func append(_ url: URL, to key: URL) {
            let path = canonicalPath(url)
            claimed.insert(path)
            if isContext(url) {
                // Preserve alternate context captures as media rather than orphaning them.
                if groups[key]?.contextImage == nil { groups[key, default: ArchiveItemFiles()].contextImage = url }
                else if groups[key]?.contextImage != url { groups[key, default: ArchiveItemFiles()].mediaFiles.append(url) }
            } else if groups[key]?.mediaFiles.contains(url) != true {
                groups[key, default: ArchiveItemFiles()].mediaFiles.append(url)
            }
        }

        // Literal sidecar stems are reserved, including import collision suffixes.
        for url in media {
            let literal = url.deletingPathExtension()
            let contextKey = url.deletingLastPathComponent().appendingPathComponent(contextStem(url))
            let owner = keys.contains(literal) ? literal : (isContext(url) && keys.contains(contextKey) ? contextKey : nil)
            if let owner { exactOwners[canonicalPath(url)] = owner; append(url, to: owner) }
        }

        // Explicit embeds may deliberately share an asset, but cannot steal one
        // from its own literal sidecar. Never infer ownership from a remote URL/ID.
        for sidecar in sidecars where !isContext(sidecar) {
            let owner = sidecar.deletingPathExtension()
            for url in embeddedMedia(in: sidecar, archivePath: archivePath) {
                if let exact = exactOwners[canonicalPath(url)], exact != owner { continue }
                let localSidecar = url.deletingPathExtension().appendingPathExtension("md")
                if localSidecar != sidecar && FileManager.default.fileExists(atPath: localSidecar.path) { continue }
                append(url, to: owner)
            }
        }

        // A numbered gallery belongs to its exact unsuffixed sidecar even when
        // that sidecar's own stem ends in a numeric post ID.
        for url in media where !claimed.contains(canonicalPath(url)) {
            guard let base = galleryBase(contextStem(url)) else { continue }
            let owner = url.deletingLastPathComponent().appendingPathComponent(base)
            if keys.contains(owner) { append(url, to: owner) }
        }

        // A gallery family is local to a directory. Multiple sidecars in that
        // family are separate captures; an unclaimed file must not pick one.
        var families: [URL: [URL]] = [:]
        for key in keys {
            let stem = key.lastPathComponent
            let family = key.deletingLastPathComponent().appendingPathComponent(galleryBase(stem) ?? stem)
            families[family, default: []].append(key)
        }
        for url in media where !claimed.contains(canonicalPath(url)) {
            let stem = contextStem(url)
            let family = url.deletingLastPathComponent().appendingPathComponent(galleryBase(stem) ?? stem)
            if let candidates = families[family], candidates.count == 1 {
                append(url, to: candidates[0])
            } else {
                // Keep unowned files separate; do not collapse foo_1 and foo_10
                // before a sidecar supplies actual gallery ownership.
                append(url, to: url.deletingLastPathComponent().appendingPathComponent(stem))
            }
        }
        for key in groups.keys {
            groups[key]?.mediaFiles.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        return groups
    }

    static func galleryBase(_ stem: String) -> String? {
        guard let match = gallerySuffix.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
              let range = Range(match.range(at: 1), in: stem) else { return nil }
        return String(stem[range])
    }

    static func isContext(_ url: URL) -> Bool {
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        return stem.hasSuffix(".context") || stem.hasSuffix("_context")
    }

    static func contextStem(_ url: URL) -> String {
        var stem = url.deletingPathExtension().lastPathComponent
        while stem.lowercased().hasSuffix(".context") { stem.removeLast(".context".count) }
        if stem.lowercased().hasSuffix("_context") { stem.removeLast("_context".count) }
        return stem
    }

    /// Recognizes the minimal header generated for a context screenshot.
    /// Tags can move to its post; authored body, notes, stars and other fields stay separate.
    static func generatedContextSidecarSource(at sidecar: URL) -> URL? {
        guard sidecar.pathExtension.lowercased() == "md", isContext(sidecar),
              let content = try? String(contentsOf: sidecar, encoding: .utf8),
              let bounds = try? FrontmatterWriter.parseBoundaries(content),
              content[bounds.bodyStartIndex...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let yaml = try? SidecarYAML.load(yaml: bounds.yamlText) as? [String: Any] else { return nil }
        let allowed: Set<String> = ["archived", "author", "platform", "source", "starred", "tags"]
        guard Set(yaml.keys).isSubset(of: allowed), yaml["archived"] != nil,
              yaml["starred"] == nil || yaml["starred"] as? Bool == false,
              yaml["tags"] == nil || yaml["tags"] is [String] || yaml["tags"] is String,
              let source = yaml["source"] as? String,
              let url = URL(string: source), url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost",
              url.pathExtension.lowercased() == "png", isContext(url) else { return nil }
        let sibling = sidecar.deletingPathExtension().appendingPathExtension("png")
        let path = canonicalPath(url)
        guard path == canonicalPath(sibling),
              (try? sibling.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func embeddedMedia(in sidecar: URL, archivePath: URL) -> [URL] {
        guard let markdown = try? String(contentsOf: sidecar, encoding: .utf8) else { return [] }
        let body = MetadataParser.extractBody(from: markdown) ?? markdown
        let root = canonicalPath(archivePath) + "/"
        var seen = Set<String>()
        return embed.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: body) else { return nil }
            let target = String(body[range]).components(separatedBy: "|")[0].components(separatedBy: "#")[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { return nil }
            let url: URL
            if target.hasPrefix("file://"), let fileURL = URL(string: target), fileURL.isFileURL { url = fileURL }
            else if target.hasPrefix("/") { url = URL(fileURLWithPath: target) }
            else { url = sidecar.deletingLastPathComponent().appendingPathComponent(target) }
            let path = canonicalPath(url)
            guard path.hasPrefix(root), ImportService.supportedExtensions.contains(url.pathExtension.lowercased()),
                  !isContext(url), FileManager.default.fileExists(atPath: path), seen.insert(path).inserted else { return nil }
            return url.standardizedFileURL
        }
    }
}

enum ArchiveReappearancePolicy {
    static func shouldRestore(_ item: MediaItem) -> Bool {
        item.metadata.deleted && item.deletionReason == .missingFiles
    }
}
