import Foundation
import Yams
import os.log

// MARK: - Parse Result

/// Result of parsing a metadata file - supports partial success
enum ParseResult: Equatable {
    case success(MediaMetadata)
    case partial(MediaMetadata, errors: [String])
    case failed(errors: [String])

    var metadata: MediaMetadata? {
        switch self {
        case .success(let m), .partial(let m, _):
            return m
        default:
            return nil
        }
    }

    var errors: [String] {
        switch self {
        case .success:
            return []
        case .partial(_, let errors), .failed(let errors):
            return errors
        }
    }

    var parseStatus: ParseStatus {
        switch self {
        case .success: return .success
        case .partial: return .partial
        case .failed: return .failed
        }
    }
}

// MARK: - Parse Status

/// Status of metadata parsing for a MediaItem
enum ParseStatus: String, Codable, Equatable, Hashable {
    case success
    case partial
    case failed
}

// MARK: - Metadata Parser

private let logger = Logger(subsystem: "com.nodraw.app", category: "MetadataParser")

/// Parses YAML frontmatter from .md files in MediaArchive
struct MetadataParser {

    /// Captures the canonical path and lightweight on-disk fingerprint used by the
    /// persistent parse-failure cache. A missing/unreadable file has no cache identity.
    static func sidecarIdentity(
        fileAt url: URL,
        fileManager: FileManager = .default
    ) -> SidecarFileIdentity? {
        SidecarFileIdentity.current(for: url, fileManager: fileManager)
    }

    /// Parse a .md file and extract MediaMetadata with graceful error handling
    /// - Parameter url: Path to the .md file
    /// - Returns: ParseResult with metadata and any errors
    static func parseGracefully(fileAt url: URL) -> ParseResult {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            return parseGracefully(content: content, sourceFile: url)
        } catch {
            // File read error - try to create synthetic metadata from filename
            if let synthetic = createSyntheticMetadata(from: url) {
                return .partial(synthetic, errors: ["Failed to read file: \(error.localizedDescription)"])
            }
            return .failed(errors: ["Failed to read file: \(error.localizedDescription)"])
        }
    }

    /// Parse content string with graceful error handling
    static func parseGracefully(content: String, sourceFile: URL? = nil) -> ParseResult {
        // Extract frontmatter between --- delimiters
        guard let frontmatter = extractFrontmatter(from: content) else {
            // No frontmatter - create synthetic from filename if available
            if let url = sourceFile {
                if let synthetic = createSyntheticMetadata(from: url) {
                    return .partial(synthetic, errors: ["No frontmatter found"])
                }
            }
            return .failed(errors: ["No frontmatter found"])
        }

        // Parse YAML
        let yaml: [String: Any]
        do {
            guard let parsed = try SidecarYAML.load(yaml: frontmatter) as? [String: Any] else {
                if let url = sourceFile, let synthetic = createSyntheticMetadata(from: url) {
                    return .partial(synthetic, errors: ["Invalid YAML structure"])
                }
                return .failed(errors: ["Invalid YAML structure"])
            }
            yaml = parsed
        } catch {
            if let url = sourceFile, let synthetic = createSyntheticMetadata(from: url) {
                return .partial(synthetic, errors: ["YAML parse error: \(error.localizedDescription)"])
            }
            return .failed(errors: ["YAML parse error: \(error.localizedDescription)"])
        }

        // Parse with error collection
        return parseYAMLGracefully(yaml, sourceFile: sourceFile)
    }

    /// Parse a .md file and extract MediaMetadata (throws on error)
    /// - Parameter url: Path to the .md file
    /// - Returns: Parsed metadata or nil if parsing fails
    static func parse(fileAt url: URL) throws -> MediaMetadata {
        let content = try String(contentsOf: url, encoding: .utf8)
        return try parse(content: content, sourceFile: url)
    }

    /// Async variant — offloads file I/O and YAML parsing to a background executor.
    /// Use this from async contexts (FSEvents handler, initial scan) to keep the
    /// main thread/actor free.
    static func parseAsync(fileAt url: URL) async throws -> MediaMetadata {
        try await Task.detached(priority: .utility) {
            try parse(fileAt: url)
        }.value
    }

    /// Async graceful variant — same offloading, returns ParseResult.
    static func parseGracefullyAsync(fileAt url: URL) async -> ParseResult {
        await Task.detached(priority: .utility) {
            parseGracefully(fileAt: url)
        }.value
    }

    /// Parse content string with frontmatter (throws on error)
    static func parse(content: String, sourceFile: URL? = nil) throws -> MediaMetadata {
        // Extract frontmatter between --- delimiters
        guard let frontmatter = extractFrontmatter(from: content) else {
            throw ParserError.noFrontmatter(sourceFile)
        }

        // Parse YAML
        guard let yaml = try SidecarYAML.load(yaml: frontmatter) as? [String: Any] else {
            throw ParserError.invalidYAML(sourceFile)
        }

        return try parseYAML(yaml, sourceFile: sourceFile)
    }

    // MARK: - Private

    private static func parsedAuthor(_ yaml: [String: Any], source: URL) -> String? {
        for key in ["author", "username", "user", "creator"] {
            if let value = yaml[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
        }
        return authorFromStatusURL(source)
    }

    static func authorFromStatusURL(_ source: URL) -> String? {
        guard ["http", "https"].contains(source.scheme?.lowercased() ?? ""),
              let host = source.host?.lowercased(),
              ["x.com", "www.x.com", "mobile.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com"].contains(host) else { return nil }
        let parts = source.path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[1] == "status",
              !parts[2].isEmpty, parts[2].allSatisfy({ $0.isASCII && $0.isNumber }),
              parts[0].range(of: #"^[A-Za-z0-9_]{1,15}$"#, options: .regularExpression) != nil,
              !["i", "home", "intent", "share", "search", "explore", "notifications", "messages", "settings"].contains(parts[0].lowercased()) else { return nil }
        return parts[0]
    }

    private static let originalDateAliases = ["date", "originalDate", "created", "tweet_date", "post_date", "date_taken"]

    /// Extract frontmatter from markdown content
    /// Frontmatter is delimited by --- at start and end.
    /// Closing --- must be on its own line (followed by \n, \r\n, or EOF).
    static func extractFrontmatter(from content: String) -> String? {
        // Normalize CRLF → LF (Swift treats \r\n as a single grapheme cluster,
        // which breaks substring searches for \n delimiters)
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)

        // Must start with ---
        guard trimmed.hasPrefix("---") else {
            return nil
        }

        // Find the closing --- (must be at start of line, followed by newline or EOF)
        let afterOpening = trimmed.dropFirst(3)
        var searchStart = afterOpening.startIndex

        while searchStart < afterOpening.endIndex {
            if let match = afterOpening.range(of: "\n---", range: searchStart..<afterOpening.endIndex) {
                let afterClose = match.upperBound
                // Verify followed by \n or EOF
                if afterClose >= afterOpening.endIndex ||
                   afterOpening[afterClose] == "\n" {
                    return String(afterOpening[..<match.lowerBound])
                }
                searchStart = match.upperBound
                continue
            }

            break  // No more matches
        }

        return nil
    }

    /// Parse YAML dictionary into MediaMetadata
    private static func parseYAML(_ yaml: [String: Any], sourceFile: URL?) throws -> MediaMetadata {
        // Required: source URL
        guard let sourceString = yaml["source"] as? String,
              let source = URL(string: sourceString) else {
            throw ParserError.missingRequired("source", sourceFile)
        }

        // Platform - normalize aliases and fall back to source URL host detection
        let platform = (yaml["platform"] as? String).map(normalizePlatformName) ?? extractPlatform(from: source)

        // Author - various possible keys
        let author = parsedAuthor(yaml, source: source)

        // Dates - handle various formats (tweet_date/post_date from server sidecars)
        let originalDate = originalDateAliases.lazy.compactMap { parseDate(yaml[$0]) }.first
        let downloadDate = parseDate(yaml["download_date"] ?? yaml["downloadDate"])
        let importDate = parseDate(yaml["import_date"] ?? yaml["importDate"])
        let archivedDate = parseDate(yaml["archived"] ?? yaml["archivedDate"] ?? yaml["saved"])
            ?? downloadDate
            ?? importDate
            ?? Date()

        // User data
        let (starred, tags, notes) = userValues(yaml)

        // Vault-persisted state flags
        let deleted = yaml["deleted"] as? Bool ?? false
        let annotated = yaml["annotated"] as? Bool ?? false

        // Source context fields
        let subreddit = yaml["subreddit"] as? String
        let boardName = yaml["board_name"] as? String
        let blogName = yaml["blog_name"] as? String
        let channelName = yaml["channel_name"] as? String
        let artistName = yaml["artist_name"] as? String
        let galleryName = yaml["gallery_name"] as? String
            ?? yaml["group_name"] as? String
            ?? yaml["album_title"] as? String
        let sourceTags = parseTags(yaml["source_tags"])
        let uploadDate = parseDate(yaml["upload_date"])
        let viewCount = yaml["view_count"] as? Int
        let likeCount = yaml["like_count"] as? Int
            ?? yaml["score"] as? Int

        return MediaMetadata(
            source: source,
            platform: platform,
            author: author,
            originalDate: originalDate,
            archivedDate: archivedDate,
            downloadDate: downloadDate,
            importDate: importDate,
            starred: starred,
            tags: tags,
            notes: notes,
            deleted: deleted,
            annotated: annotated,
            subreddit: subreddit,
            boardName: boardName,
            blogName: blogName,
            channelName: channelName,
            artistName: artistName,
            galleryName: galleryName,
            sourceTags: sourceTags.isEmpty ? nil : sourceTags,
            uploadDate: uploadDate,
            viewCount: viewCount,
            likeCount: likeCount
        )
    }

    /// Parse YAML with graceful error handling - collects errors instead of throwing
    private static func parseYAMLGracefully(_ yaml: [String: Any], sourceFile: URL?) -> ParseResult {
        var errors: [String] = []

        // Source URL - try to extract, fall back to synthetic if missing
        let source: URL
        if let sourceString = yaml["source"] as? String,
           let parsedSource = URL(string: sourceString) {
            source = parsedSource
        } else {
            // Try synthetic from filename
            if let url = sourceFile, let synthetic = createSyntheticMetadata(from: url) {
                errors.append("Missing or invalid 'source' field")
                // Use synthetic source
                source = synthetic.source
            } else {
                return .failed(errors: ["Missing required 'source' field and cannot create synthetic"])
            }
        }

        // Platform - normalize aliases and fall back to source URL host detection
        let platform = (yaml["platform"] as? String).map(normalizePlatformName) ?? extractPlatform(from: source)

        // Author - various possible keys
        let author = parsedAuthor(yaml, source: source)

        // Dates - handle various formats with ambiguous date detection (tweet_date/post_date from server sidecars)
        let dateResult = originalDateAliases.lazy.map { parseDateAmbiguous(yaml[$0]) }.first { $0.date != nil }
            ?? parseDateAmbiguous(originalDateAliases.lazy.compactMap { yaml[$0] }.first)
        let originalDate = dateResult.date
        if let warning = dateResult.warning {
            errors.append(warning)
        }

        let downloadDate = parseDate(yaml["download_date"] ?? yaml["downloadDate"])
        let importDate = parseDate(yaml["import_date"] ?? yaml["importDate"])
        let archivedResult = parseDateAmbiguous(yaml["archived"] ?? yaml["archivedDate"] ?? yaml["saved"])
        let archivedDate = archivedResult.date ?? downloadDate ?? importDate ?? Date()
        if let warning = archivedResult.warning {
            errors.append(warning)
        }

        // User data
        let (starred, tags, notes) = userValues(yaml)

        // Vault-persisted state flags
        let deleted = yaml["deleted"] as? Bool ?? false
        let annotated = yaml["annotated"] as? Bool ?? false

        // Source context fields
        let subreddit = yaml["subreddit"] as? String
        let boardName = yaml["board_name"] as? String
        let blogName = yaml["blog_name"] as? String
        let channelName = yaml["channel_name"] as? String
        let artistName = yaml["artist_name"] as? String
        let galleryName = yaml["gallery_name"] as? String
            ?? yaml["group_name"] as? String
            ?? yaml["album_title"] as? String
        let sourceTags = parseTags(yaml["source_tags"])
        let uploadDate = parseDate(yaml["upload_date"])
        let viewCount = yaml["view_count"] as? Int
        let likeCount = yaml["like_count"] as? Int
            ?? yaml["score"] as? Int

        let metadata = MediaMetadata(
            source: source,
            platform: platform,
            author: author,
            originalDate: originalDate,
            archivedDate: archivedDate,
            downloadDate: downloadDate,
            importDate: importDate,
            starred: starred,
            tags: tags,
            notes: notes,
            originalDateString: dateResult.originalString,
            deleted: deleted,
            annotated: annotated,
            subreddit: subreddit,
            boardName: boardName,
            blogName: blogName,
            channelName: channelName,
            artistName: artistName,
            galleryName: galleryName,
            sourceTags: sourceTags.isEmpty ? nil : sourceTags,
            uploadDate: uploadDate,
            viewCount: viewCount,
            likeCount: likeCount
        )

        if errors.isEmpty {
            return .success(metadata)
        } else {
            return .partial(metadata, errors: errors)
        }
    }

    /// Create synthetic metadata from filename patterns
    /// Handles patterns like: twitter_username_2025-01-15_abc123.md
    static func createSyntheticMetadata(from url: URL) -> MediaMetadata? {
        let filename = url.deletingPathExtension().lastPathComponent

        // Try to extract platform from filename prefix
        var platform = "unknown"
        var author: String? = nil
        var date: Date? = nil

        // Pattern: platform_username_date_id or similar
        let parts = filename.split(separator: "_").map(String.init)

        // Check for known platform prefixes
        let knownPlatforms = ["twitter", "instagram", "reddit", "youtube", "tiktok", "tumblr", "bluesky", "bsky"]
        if let first = parts.first?.lowercased(), knownPlatforms.contains(first) {
            platform = normalizePlatformName(first)
        }

        // Try to extract date from folder name (YYYY-MM format)
        let folderName = url.deletingLastPathComponent().lastPathComponent
        if let folderDate = parseFolderDate(folderName) {
            date = folderDate
        }

        // Try to find a date pattern in the filename parts
        for part in parts {
            if let parsedDate = parseDate(part) {
                date = parsedDate
                break
            }
        }

        // Extract username if pattern matches platform_username_...
        if parts.count >= 2 && knownPlatforms.contains(parts[0].lowercased()) {
            author = parts[1]
        }

        // Create synthetic source URL from filename
        let syntheticSource = URL(string: "file://\(url.path)") ?? URL(string: "file:///unknown")!

        return MediaMetadata(
            source: syntheticSource,
            platform: platform,
            author: author,
            originalDate: date,
            archivedDate: Date(),
            starred: false,
            tags: [],
            notes: nil
        )
    }

    /// Parse folder name like "2025-01" into a date
    private static func parseFolderDate(_ folderName: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: folderName)
    }

    /// Normalize known platform aliases to a canonical platform name.
    private static func normalizePlatformName(_ platform: String) -> String {
        let normalized = platform
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "bsky", "bluesky":
            return "bluesky"
        default:
            return normalized
        }
    }

    /// Extract platform from URL host
    private static func extractPlatform(from url: URL) -> String {
        guard let host = url.host?.lowercased() else {
            return "unknown"
        }

        // Common platform mappings
        let platformMap: [String: String] = [
            "twitter.com": "twitter",
            "x.com": "twitter",
            "mobile.twitter.com": "twitter",
            "instagram.com": "instagram",
            "reddit.com": "reddit",
            "old.reddit.com": "reddit",
            "youtube.com": "youtube",
            "youtu.be": "youtube",
            "tiktok.com": "tiktok",
            "tumblr.com": "tumblr",
            "bsky.app": "bluesky",
            "bsky.social": "bluesky",
            "pinterest.com": "pinterest",
            "flickr.com": "flickr",
            "500px.com": "500px",
            "artstation.com": "artstation",
            "deviantart.com": "deviantart",
            "behance.net": "behance",
            "dribbble.com": "dribbble",
            "unsplash.com": "unsplash",
            "pexels.com": "pexels",
        ]

        // Check direct match
        if let platform = platformMap[host] {
            return normalizePlatformName(platform)
        }

        // Check suffix match (handles subdomains)
        for (domain, platform) in platformMap {
            if host.hasSuffix(".\(domain)") || host == domain {
                return normalizePlatformName(platform)
            }
        }

        // Extract domain name as fallback
        let parts = host.split(separator: ".")
        if parts.count >= 2 {
            return normalizePlatformName(String(parts[parts.count - 2]))
        }

        return "unknown"
    }

    /// Result of ambiguous date parsing
    struct DateParseResult {
        let date: Date?
        let warning: String?
        let originalString: String?
    }

    /// Parse date with ambiguous format detection (DD/MM vs MM/DD)
    /// Returns warning when format is ambiguous and US format was assumed
    private static func parseDateAmbiguous(_ value: Any?) -> DateParseResult {
        guard let value = value else {
            return DateParseResult(date: nil, warning: nil, originalString: nil)
        }

        // Already a Date
        if let date = value as? Date {
            return DateParseResult(date: date, warning: nil, originalString: nil)
        }

        // String date
        guard let string = value as? String else {
            return DateParseResult(date: nil, warning: nil, originalString: nil)
        }

        // Check for slash-separated date that might be ambiguous
        if string.contains("/") {
            let parts = string.split(separator: "/").map(String.init)
            if parts.count >= 2 {
                if let firstNum = Int(parts[0]), let secondNum = Int(parts[1]) {
                    // If first number > 12, it must be DD/MM/YYYY (European)
                    if firstNum > 12 && secondNum <= 12 {
                        // Unambiguously European format
                        if let date = Self.europeanSlashDateFormatter.date(from: string) {
                            return DateParseResult(date: date, warning: nil, originalString: string)
                        }
                    }
                    // If second number > 12, it must be MM/DD/YYYY (US)
                    else if secondNum > 12 && firstNum <= 12 {
                        // Unambiguously US format
                        if let date = Self.slashDateFormatter.date(from: string) {
                            return DateParseResult(date: date, warning: nil, originalString: string)
                        }
                    }
                    // Both <= 12: ambiguous - try US format but log warning
                    else if firstNum <= 12 && secondNum <= 12 {
                        if let date = Self.slashDateFormatter.date(from: string) {
                            logger.warning("Ambiguous date '\(string)' - defaulted to US format (MM/DD/YYYY)")
                            return DateParseResult(
                                date: date,
                                warning: "Ambiguous date '\(string)' - assumed US format (MM/DD/YYYY)",
                                originalString: string
                            )
                        }
                    }
                }
            }
        }

        // Try standard formats
        let date = parseDate(value)
        return DateParseResult(date: date, warning: nil, originalString: string)
    }

    /// Parse date from various formats
    private static func parseDate(_ value: Any?) -> Date? {
        guard let value = value else { return nil }

        // Already a Date
        if let date = value as? Date {
            return date
        }

        // String date
        guard let string = value as? String else { return nil }

        // Try various formats
        let formatters: [DateFormatter] = [
            Self.iso8601Formatter,
            Self.simpleDateFormatter,
            Self.dateTimeFormatter,
            Self.exifDateTimeFormatter,
            Self.slashDateFormatter,
            Self.europeanSlashDateFormatter,
        ]

        for formatter in formatters {
            if let date = formatter.date(from: string) {
                return date
            }
        }

        // Try ISO8601DateFormatter for full ISO format
        if let date = ISO8601DateFormatter().date(from: string) {
            return date
        }

        return nil
    }

    /// User fields shared by parsing and durable projection conflict checks.
    static func userValues(_ yaml: [String: Any]) -> (starred: Bool, tags: [String], notes: String?) {
        (
            yaml["starred"] as? Bool ?? yaml["favorite"] as? Bool ?? false,
            parseTags(yaml["tags"]),
            yaml["notes"] as? String ?? yaml["description"] as? String
        )
    }

    /// Parse tags from various formats
    private static func parseTags(_ value: Any?) -> [String] {
        guard let value = value else { return [] }

        // Array of strings
        if let array = value as? [String] {
            return array.map { $0.trimmingCharacters(in: .whitespaces) }
        }

        // Comma-separated string
        if let string = value as? String {
            return string
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        return []
    }

    // MARK: - Date Formatters

    private static let iso8601Formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let simpleDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let exifDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let slashDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd/yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let europeanSlashDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

// MARK: - Errors

enum ParserError: Error, LocalizedError {
    case noFrontmatter(URL?)
    case invalidYAML(URL?)
    case missingRequired(String, URL?)
    case invalidDate(String, URL?)

    var errorDescription: String? {
        switch self {
        case .noFrontmatter(let url):
            return "No frontmatter found in \(url?.lastPathComponent ?? "content")"
        case .invalidYAML(let url):
            return "Invalid YAML in \(url?.lastPathComponent ?? "content")"
        case .missingRequired(let field, let url):
            return "Missing required field '\(field)' in \(url?.lastPathComponent ?? "content")"
        case .invalidDate(let value, let url):
            return "Invalid date '\(value)' in \(url?.lastPathComponent ?? "content")"
        }
    }
}

// MARK: - Body Extraction

extension MetadataParser {
    /// Extract the body content (after frontmatter)
    static func extractBody(from content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.hasPrefix("---") else {
            return content // No frontmatter, entire content is body
        }

        // Find closing ---
        let afterOpening = trimmed.dropFirst(3)

        // Try both line ending styles
        for delimiter in ["\n---\n", "\r\n---\r\n", "\n---"] {
            if let range = afterOpening.range(of: delimiter) {
                let body = afterOpening[range.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return body.isEmpty ? nil : body
            }
        }

        return nil
    }

    /// Extract wikilinks from markdown content
    /// Returns array of linked items (without [[ ]])
    static func extractWikilinks(from content: String) -> [String] {
        let pattern = #"\[\[([^\]]+)\]\]"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, range: range)

        return matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: content) else {
                return nil
            }
            return String(content[range])
        }
    }
}

// MARK: - Batch Processing

extension MetadataParser {
    /// Parse multiple files concurrently
    static func parseFiles(_ urls: [URL]) async -> [URL: Result<MediaMetadata, Error>] {
        await withTaskGroup(of: (URL, Result<MediaMetadata, Error>).self) { group in
            for url in urls {
                group.addTask {
                    do {
                        let metadata = try parse(fileAt: url)
                        return (url, .success(metadata))
                    } catch {
                        return (url, .failure(error))
                    }
                }
            }

            var results: [URL: Result<MediaMetadata, Error>] = [:]
            for await (url, result) in group {
                results[url] = result
            }
            return results
        }
    }
}

// MARK: - Frontmatter Writing

extension MetadataParser {
    /// Create a new .md file with frontmatter for an orphan media file
    /// - Parameters:
    ///   - mediaURL: Path to the media file (image/video)
    ///   - tags: Initial tags to set
    /// - Returns: URL of the created .md file
    @discardableResult
    static func createMetadataFile(forMediaAt mediaURL: URL, source: URL? = nil, tags: [String] = [], archivedDate: Date? = nil, platform: String? = nil, author: String? = nil) throws -> URL {
        let mdURL = mediaURL.deletingPathExtension().appendingPathExtension("md")

        // Don't overwrite existing files
        guard !FileManager.default.fileExists(atPath: mdURL.path) else {
            throw WriterError.fileExists
        }

        // Build minimal frontmatter
        var yaml: [String: Any] = [
            "source": source?.absoluteString ?? "file://\(mediaURL.path)",
            "archived": ISO8601DateFormatter().string(from: archivedDate ?? Date()),
            "starred": false
        ]

        if let platform = platform {
            yaml["platform"] = platform
        }
        if let author = author {
            yaml["author"] = author
        }
        if !tags.isEmpty {
            yaml["tags"] = tags
        }

        let frontmatter = try Yams.dump(object: yaml, allowUnicode: true, sortKeys: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let content = "---\n\(frontmatter)\n---\n"
        try content.write(to: mdURL, atomically: true, encoding: .utf8)

        return mdURL
    }

    /// Create a derivative .md sidecar for a trimmed clip, inheriting parent metadata.
    /// - Parameters:
    ///   - mediaURL: Path to the new trimmed media file
    ///   - parentMetadata: The parent item's metadata to inherit from
    ///   - parentMetadataPath: Path to the parent's .md file (stored as derivedFrom)
    /// - Returns: URL of the created .md file
    @discardableResult
    static func createDerivativeMetadataFile(
        forMediaAt mediaURL: URL,
        parentMetadata: MediaMetadata,
        parentMetadataPath: URL
    ) throws -> URL {
        let mdURL = mediaURL.deletingPathExtension().appendingPathExtension("md")

        // Don't overwrite existing files
        guard !FileManager.default.fileExists(atPath: mdURL.path) else {
            throw WriterError.fileExists
        }

        // Build frontmatter inheriting parent fields
        var yaml: [String: Any] = [
            "source": parentMetadata.source.absoluteString,
            "platform": parentMetadata.platform,
            "archived": ISO8601DateFormatter().string(from: Date()),
            "starred": false,
            "derivedFrom": parentMetadataPath.path,
        ]

        if let author = parentMetadata.author {
            yaml["author"] = author
        }

        if let originalDate = parentMetadata.originalDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            yaml["date"] = formatter.string(from: originalDate)
        }

        if !parentMetadata.tags.isEmpty {
            yaml["tags"] = parentMetadata.tags
        }

        if let notes = parentMetadata.notes {
            yaml["notes"] = notes
        }

        let frontmatter = try Yams.dump(object: yaml, allowUnicode: true, sortKeys: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let content = "---\n\(frontmatter)\n---\n"
        try content.write(to: mdURL, atomically: true, encoding: .utf8)

        return mdURL
    }
}

// MARK: - Writer Errors

enum WriterError: Error, LocalizedError {
    case fileExists

    var errorDescription: String? {
        switch self {
        case .fileExists:
            return "Metadata file already exists"
        }
    }
}
