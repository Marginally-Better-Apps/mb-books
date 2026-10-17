import Foundation
import NaturalLanguage

/// Text that remembers where each character came from in the document, so cleanup (dropping soft
/// hyphens, collapsing whitespace, rewriting "IV" as "4") never loses the link back to the page.
nonisolated struct MappedText: Sendable {
    private(set) var characters: [Character] = []
    /// UTF-16 offset in the document of each character.
    private(set) var sources: [Int] = []
    /// Whether a character was written by cleanup rather than taken from the document.
    private(set) var synthetic: [Bool] = []

    init() {}

    init(_ text: String, at source: Int) {
        append(text, at: source)
    }

    var string: String { String(characters) }
    var isEmpty: Bool { characters.isEmpty }
    var count: Int { characters.count }

    mutating func append(_ text: String, at source: Int) {
        var offset = source
        for character in text {
            characters.append(character)
            sources.append(offset)
            synthetic.append(false)
            offset += character.utf16.count
        }
    }

    /// Adds text that isn't in the document, such as a space for a line break, attributed to `source`.
    mutating func appendSynthetic(_ text: String, at source: Int) {
        for character in text {
            characters.append(character)
            sources.append(source)
            synthetic.append(true)
        }
    }

    mutating func append(_ other: MappedText) {
        characters += other.characters
        sources += other.sources
        synthetic += other.synthetic
    }

    var lastSource: Int? { sources.last }

    func slice(_ range: Range<Int>) -> MappedText {
        var result = MappedText()
        result.characters = Array(characters[range])
        result.sources = Array(sources[range])
        result.synthetic = Array(synthetic[range])
        return result
    }

    /// Rebuilds the text by mapping each character to zero or more characters with the same source.
    func mapCharacters(_ transform: (Character) -> String?) -> MappedText {
        var result = MappedText()
        for index in characters.indices {
            let replacement = transform(characters[index]) ?? String(characters[index])
            for character in replacement {
                result.characters.append(character)
                result.sources.append(sources[index])
                result.synthetic.append(synthetic[index] || replacement != String(characters[index]))
            }
        }
        return result
    }

    /// Replaces regular-expression matches. The replacement is attributed to the start of each match.
    func replacingMatches(of pattern: NSRegularExpression, with template: (NSTextCheckingResult, String) -> String) -> MappedText {
        let text = string
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return self }
        // Character index for each UTF-16 offset in `text`.
        var characterIndex: [Int] = []
        characterIndex.reserveCapacity(text.utf16.count + 1)
        for (index, character) in characters.enumerated() {
            for _ in 0..<character.utf16.count { characterIndex.append(index) }
        }
        characterIndex.append(characters.count)
        var result = MappedText()
        var cursor = 0
        for match in matches {
            let start = characterIndex[match.range.location]
            let end = characterIndex[match.range.location + match.range.length]
            guard start >= cursor else { continue }
            result.append(slice(cursor..<start))
            let original = String(characters[start..<end])
            let replacement = template(match, original)
            if replacement == original {
                result.append(slice(start..<end))
            } else {
                result.appendSynthetic(replacement, at: start < sources.count ? sources[start] : (sources.last ?? 0))
            }
            cursor = end
        }
        result.append(slice(cursor..<characters.count))
        return result
    }

    /// Collapses runs of whitespace to one space and trims the ends.
    func collapsingWhitespace() -> MappedText {
        var result = MappedText()
        var pendingSpace: Int?
        for index in characters.indices {
            let character = characters[index]
            if character.isWhitespace {
                if pendingSpace == nil { pendingSpace = index }
                continue
            }
            if let space = pendingSpace, !result.isEmpty {
                result.characters.append(" ")
                result.sources.append(sources[space])
                result.synthetic.append(synthetic[space])
            }
            pendingSpace = nil
            result.characters.append(character)
            result.sources.append(sources[index])
            result.synthetic.append(synthetic[index])
        }
        return result
    }

    /// The document range covered by `range`, from its first to its last original character.
    func sourceRange(_ range: Range<Int>) -> (start: Int, end: Int)? {
        let original = range.filter { !synthetic[$0] }
        guard let first = original.first ?? range.first, let last = original.last ?? range.last else { return nil }
        return (sources[first], sources[last] + characters[last].utf16.count)
    }

    /// Anchors for positions where the spoken text stops following the document one-to-one.
    func anchors(_ range: Range<Int>) -> [SpeechUtterance.Anchor] {
        var anchors: [SpeechUtterance.Anchor] = []
        var spoken = 0
        var expected: Int?
        for index in range {
            if sources[index] != expected {
                anchors.append(.init(spoken: spoken, source: sources[index]))
            }
            let width = characters[index].utf16.count
            expected = synthetic[index] ? sources[index] : sources[index] + width
            spoken += width
        }
        return anchors
    }
}

/// Cleanup that applies whatever voice reads the text.
nonisolated enum SpeechText {
    private static let invisible: Set<Character> = [
        "\u{00AD}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{200E}", "\u{200F}",
    ]
    private static let ligatures: [Character: String] = [
        "ﬀ": "ff", "ﬁ": "fi", "ﬂ": "fl", "ﬃ": "ffi", "ﬄ": "ffl", "ﬅ": "st", "ﬆ": "st",
    ]
    private static let superscriptDigits = "⁰¹²³⁴⁵⁶⁷⁸⁹"

    /// Footnote markers typed as text: "word¹", "word[12]", "word[a]".
    private static let inlineMarker = try! NSRegularExpression(
        pattern: "(?<=[\\p{L}\\p{P}])(?:[\(superscriptDigits)]+|\\[(?:\\d{1,3}|[a-z])\\])")
    private static let url = try! NSRegularExpression(
        pattern: "\\b(?:https?://|www\\.)([A-Za-z0-9.-]+\\.[A-Za-z]{2,})(?:[/?#][^\\s]*)?", options: [.caseInsensitive])

    /// Strips invisible characters, ligatures, inline note markers, and long URLs, and collapses whitespace.
    static func clean(_ text: MappedText) -> MappedText {
        var result = text.mapCharacters { character in
            if invisible.contains(character) { return "" }
            if let expanded = ligatures[character] { return expanded }
            if character.isWhitespace { return " " }
            return nil
        }
        result = result.replacingMatches(of: inlineMarker) { _, _ in "" }
        result = result.replacingMatches(of: url) { match, original in
            // Read a link's site, not its path: "https://www.example.com/a?b" becomes "example.com".
            let host = (original as NSString).substring(with: NSRange(location: match.range(at: 1).location - match.range.location,
                                                                      length: match.range(at: 1).length))
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return result.collapsingWhitespace()
    }

    /// Ornaments and rules that mark a section break, like "* * *" or "⁂".
    static func isSceneBreak(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 40 else { return false }
        let ornaments = CharacterSet(charactersIn: "*•·∙~#⁂❦❧☙✻✼✽❋✱✲※§¶°ºo0-–—_=+.:|/\\<>()[]{}♦◆◇○●□■")
        return trimmed.unicodeScalars.allSatisfy { ornaments.contains($0) || CharacterSet.whitespaces.contains($0) }
            && !trimmed.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) || $0 == "." }
    }

    /// Text that is only a page number: "12", "- 12 -", "[xii]", "Page 12", "p. 12".
    static func isPageNumber(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 16 else { return false }
        let pattern = #"^(?:page|pg\.?|p\.)?\s*[\[\(\-–—|·•]*\s*(?:\d{1,4}|[ivxlcdm]{1,7})\s*[\]\)\-–—|·•]*\.?$"#
        return trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Headings

    private static let labelledRoman = try! NSRegularExpression(
        pattern: "^(chapter|part|book|section|act|scene|canto|volume|letter)\\s+([IVXLCDM]{1,7})(?=$|[\\s.:—–-])",
        options: [.caseInsensitive])
    /// A numeral alone, followed by nothing or punctuation, so "I Am Legend" stays as it is.
    private static let loneRoman = try! NSRegularExpression(pattern: "^([IVXLCDM]{1,7})(?=$|[.:—–-])")

    /// "Chapter IV" reads as "Chapter 4", and a heading that is only "XII" as "12", instead of letters.
    static func headingText(_ text: MappedText) -> MappedText {
        let labelled = text.replacingMatches(of: labelledRoman) { match, original in
            let ns = original as NSString
            let offset = match.range.location
            let label = ns.substring(with: NSRange(location: match.range(at: 1).location - offset, length: match.range(at: 1).length))
            let numeral = ns.substring(with: NSRange(location: match.range(at: 2).location - offset, length: match.range(at: 2).length))
            guard let value = romanValue(numeral) else { return original }
            return "\(label) \(value)"
        }
        return labelled.replacingMatches(of: loneRoman) { _, original in
            romanValue(original).map(String.init) ?? original
        }
    }

    static func romanValue(_ numeral: String) -> Int? {
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000]
        let digits = numeral.uppercased().compactMap { values[$0] }
        guard digits.count == numeral.count, !digits.isEmpty else { return nil }
        var total = 0
        for (index, value) in digits.enumerated() {
            if index + 1 < digits.count, value < digits[index + 1] { total -= value } else { total += value }
        }
        // Reject non-canonical forms such as "IIII" or "VX" by round-tripping.
        guard total > 0, total < 4000, romanNumeral(total) == numeral.uppercased() else { return nil }
        return total
    }

    private static func romanNumeral(_ value: Int) -> String {
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                      (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var remaining = value
        var result = ""
        for (amount, symbol) in table {
            while remaining >= amount {
                result += symbol
                remaining -= amount
            }
        }
        return result
    }

    // MARK: - Sentences

    /// Longest stretch handed to a voice at once; longer sentences split at clause boundaries.
    static let maximumUtteranceLength = 320

    /// Splits text into sentences, and over-long sentences at commas, semicolons, and dashes.
    static func sentences(in text: String, language: String?) -> [Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        if let language { tokenizer.setLanguage(NLLanguage(rawValue: language)) }
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            ranges.append(range)
            return true
        }
        if ranges.isEmpty, !text.isEmpty { ranges = [text.startIndex..<text.endIndex] }
        ranges = mergingFragments(ranges, in: text)
        return ranges.flatMap { splitLong($0, in: text) }
    }

    /// Joins fragments the tokenizer split off, such as a lone closing quote or "Mr." before a name.
    private static func mergingFragments(_ ranges: [Range<String.Index>], in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        for range in ranges {
            let piece = text[range].trimmingCharacters(in: .whitespaces)
            let isFragment = !piece.contains { $0.isLetter || $0.isNumber }
                || (result.last.map { text[$0].trimmingCharacters(in: .whitespaces).range(
                    of: #"\b(?:Mr|Mrs|Ms|Dr|St|Mt|Jr|Sr|Prof|Gen|Col|Capt|Lt|Rev|No|vs|Vol|Ch|pp?)\.$"#,
                    options: .regularExpression) != nil } ?? false)
            if isFragment, let last = result.popLast() {
                result.append(last.lowerBound..<range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    private static func splitLong(_ range: Range<String.Index>, in text: String) -> [Range<String.Index>] {
        guard text.distance(from: range.lowerBound, to: range.upperBound) > maximumUtteranceLength else { return [range] }
        let breakers: [Character] = [";", ":", "—", "–", ",", ")"]
        var pieces: [Range<String.Index>] = []
        var start = range.lowerBound
        while text.distance(from: start, to: range.upperBound) > maximumUtteranceLength {
            let limit = text.index(start, offsetBy: maximumUtteranceLength)
            let window = text[start..<limit]
            let minimum = text.index(start, offsetBy: maximumUtteranceLength / 3)
            // Prefer the strongest break in the window, as late as possible.
            var cut: String.Index?
            for breaker in breakers {
                if let index = window.lastIndex(of: breaker), index > minimum {
                    cut = text.index(after: index)
                    break
                }
            }
            if cut == nil, let space = window.lastIndex(of: " "), space > minimum { cut = space }
            let end = cut ?? limit
            pieces.append(start..<end)
            start = end
        }
        pieces.append(start..<range.upperBound)
        return pieces.filter { !text[$0].trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
