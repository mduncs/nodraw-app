import Foundation

/// Shared construction helpers for MediaStore `FilterState` used by grid/table browsers.
enum MediaFilterBuilder {
    private static let imageTypeExtensions = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"]
    private static let videoTypeExtensions = ["mp4", "mov", "webm", "m4v", "avi", "mkv"]
    private static let audioTypeExtensions = ["mp3", "m4a", "wav", "aiff", "aif", "flac", "ogg", "opus", "aac"]
    private static let documentTypeExtensions = ["pdf", "doc", "docx", "rtf", "txt"]

    struct ParsedSearchInput: Equatable {
        var freeText: String = ""
        var platform: String?
        var platforms: [String] = []
        var authorQuery: String?
        var authorQueries: [String] = []
        var exactAuthor: String?
        var sourceQuery: String?
        var sourceQueries: [String] = []
        var ocrQuery: String?
        var notesQuery: String?
        var tags: [String] = []
        var tagFilters: [TagFilter] = []
        var folderPath: String?
        var folderPaths: [String] = []
        var hasVideo: Bool?
        var tagsEmpty: Bool?
        var fileExtensions: [String] = []
        var aspectRatio: AspectRatioFilter?
        var aspectRatios: [AspectRatioFilter] = []
        var recentDays: Int?
        var recentDayConstraints: [Int] = []

        var hasStructuredFilters: Bool {
            platform != nil
                || authorQuery != nil
                || exactAuthor != nil
                || sourceQuery != nil
                || ocrQuery != nil
                || notesQuery != nil
                || !tags.isEmpty
                || !tagFilters.isEmpty
                || folderPath != nil
                || hasVideo != nil
                || tagsEmpty != nil
                || !fileExtensions.isEmpty
                || aspectRatio != nil
                || recentDays != nil
        }
    }

    enum UnsupportedSelectionBehavior {
        case keepUnfiltered
        case returnEmpty
    }

    /// Build the base filter from sidebar selection.
    /// Returns nil when the caller requested empty results for unsupported sidebar modes.
    static func makeBaseFilter(
        sidebarSelection: SidebarSelection,
        activeSmartFolder: SmartFolder?,
        unsupportedSelectionBehavior: UnsupportedSelectionBehavior
    ) -> FilterState? {
        var filter = FilterState()

        switch sidebarSelection {
        case .allMedia:
            break
        case .folderYear(let year):
            filter.folderPath = "\(year)-"
        case .folder(let folderName):
            filter.folderPath = folderName
        case .smartFolder:
            filter.smartFolder = activeSmartFolder
        case .board(let id):
            filter.boardId = id
        case .platform(let name):
            filter.platform = name.lowercased()
        case .tag(let name):
            filter.tags = [name]
        case .recentlyDeleted:
            filter.deletionScope = .deletedOnly
            // Recovery must not make deleted rows disappear behind normal
            // content-quality/safety suppression.
            filter.hideJunk = false
            filter.hideSafetyFlagged = false
        case .rediscover:
            filter.rediscoverMode = true
        case .duplicates, .canvas, .visualClusters:
            if unsupportedSelectionBehavior == .returnEmpty {
                return nil
            }
        }

        return filter
    }

    /// Apply search filters, including optional CLIP visual search.
    /// Returns CLIP result IDs when visual mode is active; nil otherwise.
    static func applySearch(
        to filter: inout FilterState,
        filterText: String,
        searchScope: SearchScope,
        visualResultIds: [UUID]? = nil,
        allowVisualSearch: Bool
    ) async throws -> [UUID]? {
        let parsedInput = parseSearchInput(filterText)
        applyStructuredSearch(parsedInput, to: &filter)

        guard !parsedInput.freeText.isEmpty else {
            return nil
        }

        if searchScope == .visual {
            if let visualResultIds {
                filter.clipResultIds = visualResultIds.isEmpty ? [UUID()] : visualResultIds
                return visualResultIds
            }

            guard allowVisualSearch else {
                filter.clipResultIds = [UUID()]
                return []
            }

            if let pipelineQueue = PipelineQueue.sharedIfConfigured {
                let results = try await pipelineQueue.clipSearch(query: parsedInput.freeText, limit: 200)
                let ids = results.map(\.itemId)
                filter.clipResultIds = ids.isEmpty ? [UUID()] : ids
                return ids
            } else {
                filter.clipResultIds = [UUID()]
                return []
            }
        }

        if filter.searchText.isEmpty {
            filter.searchText = parsedInput.freeText
            filter.searchScope = searchScope
        }
        return nil
    }

    static func applyCommonFilters(
        to filter: inout FilterState,
        dateRangeFilter: ClosedRange<Date>?,
        colorFilters: Set<ColorBucket>,
        colorSearchRGB: ColorSearchRGB?,
        starredFilter: Bool?,
        hasOCRFilter: Bool?,
        platformFilter: String?,
        attributeFilters: [AttributeFilter] = [],
        hideJunk: Bool? = nil,
        hideSafetyFlagged: Bool? = nil
    ) {
        if let dateRange = dateRangeFilter {
            addDateConstraint(DateRangeFilter(
                field: .archived,
                range: .between(dateRange.lowerBound, dateRange.upperBound)
            ), to: &filter)
        }

        if !colorFilters.isEmpty {
            filter.colorFilters = colorFilters
        }
        filter.colorSearchRGB = colorSearchRGB
        filter.starred = starredFilter
        filter.hasOCR = hasOCRFilter

        if let platform = platformFilter {
            addPlatformConstraint(platform, to: &filter)
        }

        for attributeFilter in attributeFilters where !filter.attributeFilters.contains(attributeFilter) {
            filter.attributeFilters.append(attributeFilter)
        }

        if let hideJunk {
            filter.hideJunk = hideJunk
        }
        if let hideSafetyFlagged {
            filter.hideSafetyFlagged = hideSafetyFlagged
        }
    }

    static func isSearchTextEligible(_ filterText: String) -> Bool {
        !searchQueryText(from: filterText).isEmpty
    }

    static func searchQueryText(from filterText: String) -> String {
        parseSearchInput(filterText).freeText
    }

    static func hasStructuredSearchFilters(in filterText: String) -> Bool {
        parseSearchInput(filterText).hasStructuredFilters
    }

    static func exactAuthorSearchText(_ author: String) -> String {
        let quoted = String(data: try! JSONEncoder().encode(author), encoding: .utf8)!
        return "author:=\(quoted)"
    }

    static func parseSearchInput(_ filterText: String) -> ParsedSearchInput {
        let tokens = tokenizeSearchInput(filterText)

        var parsed = ParsedSearchInput()
        var freeTextTokens: [String] = []

        for token in tokens {
            guard let separatorIndex = token.firstIndex(of: ":") else {
                freeTextTokens.append(token)
                continue
            }

            let key = String(token[..<separatorIndex]).lowercased()
            let valueStart = token.index(after: separatorIndex)
            let rawValue = String(token[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = unquoteIfNeeded(rawValue)
            guard !value.isEmpty else {
                freeTextTokens.append(token)
                continue
            }

            let normalizedValue = value.lowercased()

            switch key {
            case "platform":
                parsed.platform = normalizedValue
                parsed.platforms.append(normalizedValue)
            case "author":
                if rawValue.hasPrefix("="),
                   let data = String(rawValue.dropFirst()).data(using: .utf8),
                   let exact = try? JSONDecoder().decode(String.self, from: data),
                   !exact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parsed.exactAuthor = exact
                } else {
                    parsed.authorQuery = value
                    parsed.authorQueries.append(value)
                }
            case "source", "url":
                if parsed.sourceQuery == nil { parsed.sourceQuery = value }
                parsed.sourceQueries.append(value)
            case "ocr":
                parsed.ocrQuery = mergeFieldQuery(existing: parsed.ocrQuery, next: value)
            case "notes", "note":
                parsed.notesQuery = mergeFieldQuery(existing: parsed.notesQuery, next: value)
            case "tag", "tags":
                if normalizedValue == "none" {
                    parsed.tagsEmpty = true
                } else {
                    parsed.tags.append(normalizedValue)
                }
            case "-tag", "not-tag", "exclude-tag":
                parsed.tagFilters.append(TagFilter(name: normalizedValue, polarity: .exclude, scope: .subtree))
            case "tag-only", "tags-only":
                parsed.tagFilters.append(TagFilter(name: normalizedValue, polarity: .include, scope: .exact))
            case "-tag-only", "not-tag-only", "exclude-tag-only":
                parsed.tagFilters.append(TagFilter(name: normalizedValue, polarity: .exclude, scope: .exact))
            case "folder":
                parsed.folderPath = value
                parsed.folderPaths.append(value)
            case "type":
                let fileExtensions = parseTypeFileExtensions(from: normalizedValue)
                if fileExtensions.isEmpty {
                    freeTextTokens.append(token)
                } else {
                    parsed.fileExtensions.append(contentsOf: fileExtensions)
                }
            case "ext", "extension", "format", "file":
                let fileExtensions = parseFileExtensions(from: normalizedValue)
                if fileExtensions.isEmpty {
                    freeTextTokens.append(token)
                } else {
                    parsed.fileExtensions.append(contentsOf: fileExtensions)
                }
            case "ratio", "aspect", "aspectratio", "dims", "dim", "dimensions":
                if let aspectRatio = parseAspectRatioFilter(from: normalizedValue) {
                    parsed.aspectRatio = aspectRatio
                    parsed.aspectRatios.append(aspectRatio)
                } else {
                    freeTextTokens.append(token)
                }
            case "recent":
                if let days = parseRecentDays(normalizedValue) {
                    parsed.recentDays = days
                    parsed.recentDayConstraints.append(days)
                } else {
                    freeTextTokens.append(token)
                }
            default:
                freeTextTokens.append(token)
            }
        }

        parsed.tags = uniquePreservingOrder(parsed.tags)
        parsed.tagFilters = uniquePreservingOrder(parsed.tagFilters)
        parsed.fileExtensions = uniquePreservingOrder(parsed.fileExtensions)
        parsed.freeText = freeTextTokens.joined(separator: " ")
        return parsed
    }

    private static func applyStructuredSearch(_ parsedInput: ParsedSearchInput, to filter: inout FilterState) {
        if let author = parsedInput.exactAuthor { filter.author = author }
        for platform in parsedInput.platforms {
            addPlatformConstraint(platform, to: &filter)
        }

        for authorQuery in parsedInput.authorQueries {
            if filter.authorQuery == nil { filter.authorQuery = authorQuery }
            else if filter.authorQuery != authorQuery && !filter.authorConstraints.contains(authorQuery) {
                filter.authorConstraints.append(authorQuery)
            }
        }

        let sourceQueries = parsedInput.sourceQueries.isEmpty
            ? [parsedInput.sourceQuery].compactMap { $0 }
            : parsedInput.sourceQueries
        for sourceQuery in sourceQueries {
            if filter.sourceQuery == nil { filter.sourceQuery = sourceQuery }
            else if filter.sourceQuery != sourceQuery && !filter.sourceConstraints.contains(sourceQuery) {
                filter.sourceConstraints.append(sourceQuery)
            }
        }

        if let ocrQuery = parsedInput.ocrQuery, filter.ocrQuery == nil {
            filter.ocrQuery = ocrQuery
        }

        if let notesQuery = parsedInput.notesQuery, filter.notesQuery == nil {
            filter.notesQuery = notesQuery
        }

        if !parsedInput.tags.isEmpty {
            filter.tags = uniquePreservingOrder(filter.tags + parsedInput.tags)
        }
        if !parsedInput.tagFilters.isEmpty {
            filter.tagFilters = uniquePreservingOrder(filter.tagFilters + parsedInput.tagFilters)
        }

        for folderPath in parsedInput.folderPaths {
            if filter.folderPath == nil { filter.folderPath = folderPath }
            else if filter.folderPath != folderPath && !filter.folderConstraints.contains(folderPath) {
                filter.folderConstraints.append(folderPath)
            }
        }

        if let hasVideo = parsedInput.hasVideo, filter.hasVideo == nil {
            filter.hasVideo = hasVideo
        }

        if let tagsEmpty = parsedInput.tagsEmpty, filter.tagsEmpty == nil {
            filter.tagsEmpty = tagsEmpty
        }

        if !parsedInput.fileExtensions.isEmpty {
            filter.fileExtensions = uniquePreservingOrder(filter.fileExtensions + parsedInput.fileExtensions)
        }

        for aspectRatio in parsedInput.aspectRatios {
            if filter.aspectRatio == nil { filter.aspectRatio = aspectRatio }
            else if filter.aspectRatio != aspectRatio && !filter.aspectRatioConstraints.contains(aspectRatio) {
                filter.aspectRatioConstraints.append(aspectRatio)
            }
        }

        for recentDays in parsedInput.recentDayConstraints {
            addDateConstraint(DateRangeFilter(field: .archived, range: .lastNDays(recentDays)), to: &filter)
        }
    }

    private static func addPlatformConstraint(_ platform: String, to filter: inout FilterState) {
        let value = platform.lowercased()
        if filter.platform == nil { filter.platform = value }
        else if filter.platform != value && !filter.platformConstraints.contains(value) {
            filter.platformConstraints.append(value)
        }
    }

    private static func addDateConstraint(_ date: DateRangeFilter, to filter: inout FilterState) {
        if filter.dateRange == nil { filter.dateRange = date }
        else if filter.dateRange != date && !filter.dateConstraints.contains(date) {
            filter.dateConstraints.append(date)
        }
    }

    private static func parseAspectRatioFilter(from value: String) -> AspectRatioFilter? {
        switch value {
        case "square":
            return AspectRatioFilter(min: 0.9, max: 1.1)
        case "portrait":
            return AspectRatioFilter(min: 0.0, max: 0.9)
        case "landscape":
            return AspectRatioFilter(min: 1.1, max: 2.5)
        case "panoramic", "wide":
            return AspectRatioFilter(min: 2.5, max: 100.0)
        default:
            break
        }

        let separators = CharacterSet(charactersIn: ":x/")
            .union(CharacterSet(charactersIn: "\u{00D7}"))
        let components = value
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let ratio: Double?
        if components.count == 2,
           let width = Double(components[0]),
           let height = Double(components[1]),
           height > 0 {
            ratio = width / height
        } else {
            ratio = Double(value)
        }

        guard let ratio, ratio > 0, ratio.isFinite else { return nil }
        let tolerance = max(0.03, ratio * 0.03)
        return AspectRatioFilter(min: max(0, ratio - tolerance), max: ratio + tolerance)
    }

    private static func parseRecentDays(_ value: String) -> Int? {
        let trimmedValue: String
        if value.hasSuffix("d") {
            trimmedValue = String(value.dropLast())
        } else {
            trimmedValue = value
        }

        guard let days = Int(trimmedValue), days > 0 else {
            return nil
        }
        return days
    }

    private static func uniquePreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func uniquePreservingOrder(_ values: [TagFilter]) -> [TagFilter] {
        var seen = Set<TagFilter>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func parseFileExtensions(from value: String) -> [String] {
        let parsed = value
            .split(separator: ",")
            .compactMap { component -> String? in
                let normalized = component
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return normalized.isEmpty ? nil : normalized
            }

        return uniquePreservingOrder(parsed)
    }

    private static func parseTypeFileExtensions(from value: String) -> [String] {
        let components = value
            .split { character in
                character == "," || character == "/"
            }
            .map {
                $0
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            }
            .filter { !$0.isEmpty }

        let fileExtensions = components.flatMap { component -> [String] in
            switch component {
            case "image", "images", "photo", "photos", "picture", "pictures":
                return imageTypeExtensions
            case "video", "videos", "movie", "movies":
                return videoTypeExtensions
            case "audio", "audios", "sound", "sounds":
                return audioTypeExtensions
            case "gif", "gifs":
                return ["gif"]
            case "pdf", "pdfs":
                return ["pdf"]
            case "document", "documents", "doc", "docs":
                return documentTypeExtensions
            default:
                return parseFileExtensions(from: component)
            }
        }

        return uniquePreservingOrder(fileExtensions)
    }

    static func tokenizeSearchInput(_ filterText: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var isInsideQuotes = false
        var isEscaped = false

        for character in filterText {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" && isInsideQuotes {
                current.append(character)
                isEscaped = true
                continue
            }
            if character == "\"" {
                isInsideQuotes.toggle()
                current.append(character)
                continue
            }

            if character.isWhitespace && !isInsideQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            current.append(character)
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    private static func unquoteIfNeeded(_ value: String) -> String {
        guard value.count >= 2,
              value.first == "\"",
              value.last == "\"" else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }

    private static func mergeFieldQuery(existing: String?, next: String) -> String {
        guard let existing, !existing.isEmpty else { return next }
        return existing + " " + next
    }
}
