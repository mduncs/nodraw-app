import Foundation

/// Produces the stable lookup key stored in `media_tags`.
///
/// User-facing spelling remains in `tagsJSON`; the junction uses a POSIX, Unicode
/// case-fold followed by NFC so visually equivalent case/composition variants map
/// to the same byte string for SQLite equality and indexed lookups.
enum TagCanonicalizer {
    static func displayName(_ rawValue: String) -> String {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func key(_ rawValue: String) -> String {
        displayName(rawValue)
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    /// A small, deterministic fuzzy matcher for tag pickers. Lower scores are better.
    /// Exact, prefix, word-prefix, and substring matches stay ahead of subsequence matches.
    static func matchScore(query rawQuery: String, candidate rawCandidate: String) -> Int? {
        let query = key(rawQuery)
        let candidate = key(rawCandidate)
        guard !query.isEmpty, !candidate.isEmpty else { return query.isEmpty ? 0 : nil }

        if candidate == query { return 0 }
        if candidate.hasPrefix(query) { return 10 + candidate.count - query.count }

        let wordSeparators = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "-_/>")
        )
        let words = candidate.components(separatedBy: wordSeparators).filter { !$0.isEmpty }
        if let wordIndex = words.firstIndex(where: { $0.hasPrefix(query) }) {
            return 30 + wordIndex * 4 + words[wordIndex].count - query.count
        }

        if let range = candidate.range(of: query) {
            return 60 + candidate.distance(from: candidate.startIndex, to: range.lowerBound)
        }

        var queryIndex = query.startIndex
        var previousMatchOffset: Int?
        var gapPenalty = 0
        var candidateOffset = 0
        for character in candidate {
            guard queryIndex < query.endIndex else { break }
            if character == query[queryIndex] {
                if let previousMatchOffset {
                    gapPenalty += max(0, candidateOffset - previousMatchOffset - 1)
                } else {
                    gapPenalty += candidateOffset
                }
                previousMatchOffset = candidateOffset
                query.formIndex(after: &queryIndex)
            }
            candidateOffset += 1
        }

        guard queryIndex == query.endIndex else { return nil }
        return 100 + gapPenalty + candidate.count - query.count
    }
}
