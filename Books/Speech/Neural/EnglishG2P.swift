import Foundation
import NaturalLanguage

/// Converts English text to the phonemes Kokoro was trained on, following misaki (hexgrad's G2P for Kokoro,
/// Apache 2.0): a gold and silver pronunciation dictionary, suffix rules for plurals, past tenses, and
/// "-ing", number reading, and a small neural model for words the dictionary doesn't have.
///
/// misaki tags parts of speech with spaCy; here Apple's NaturalLanguage tagger does that job, on device.
nonisolated final class EnglishG2P: @unchecked Sendable {
    enum Entry {
        case single(String)
        /// Pronunciations by part-of-speech tag, with a `DEFAULT`.
        case tagged([String: String?])
    }

    private let golds: [String: Entry]
    private let silvers: [String: Entry]
    private let fallback: G2PFallback?

    init(golds: [String: Entry], silvers: [String: Entry], fallback: G2PFallback?) {
        self.golds = golds
        self.silvers = silvers
        self.fallback = fallback
    }

    /// Loads the bundled US English dictionaries and fallback model.
    static func bundled() throws -> EnglishG2P {
        func resource(_ name: String, _ type: String) throws -> URL {
            guard let url = Bundle.main.url(forResource: name, withExtension: type)
                ?? Bundle(for: EnglishG2P.self).url(forResource: name, withExtension: type)
            else { throw CocoaError(.fileNoSuchFile) }
            return url
        }
        return try load(gold: resource("us_gold", "json"), silver: resource("us_silver", "json"),
                        fallback: try? resource("g2p-en-us", "safetensors"))
    }

    static func load(gold: URL, silver: URL, fallback: URL?) throws -> EnglishG2P {
        func entries(_ url: URL) throws -> [String: Entry] {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            guard let raw = object as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            var entries: [String: Entry] = [:]
            entries.reserveCapacity(raw.count * 2)
            for (word, value) in raw {
                if let text = value as? String {
                    entries[word] = .single(text)
                } else if let tagged = value as? [String: Any] {
                    entries[word] = .tagged(tagged.mapValues { $0 as? String })
                }
            }
            return grow(entries)
        }
        return try EnglishG2P(golds: entries(gold), silvers: entries(silver), fallback: fallback.flatMap { try? G2PFallback(url: $0) })
    }

    /// Adds capitalized and lowercase variants, as misaki's `grow_dictionary` does.
    private static func grow(_ entries: [String: Entry]) -> [String: Entry] {
        var grown = entries
        for (word, entry) in entries where word.count >= 2 {
            let lower = word.lowercased()
            let capitalized = lower.prefix(1).uppercased() + lower.dropFirst()
            if word == lower {
                if word != capitalized, grown[capitalized] == nil { grown[capitalized] = entry }
            } else if word == capitalized, grown[lower] == nil {
                grown[lower] = entry
            }
        }
        return grown
    }

    // MARK: - Phoneme inventory

    static let primaryStress: Character = "ˈ"
    static let secondaryStress: Character = "ˌ"
    static let vowels: Set<Character> = Set("AIOQWYaiuæɑɒɔəɛɜɪʊʌᵻ")
    static let consonants: Set<Character> = Set("bdfhjklmnpstvwzðŋɡɹɾʃʒʤʧθ")
    private static let diphthongs: Set<Character> = Set("AIOQWYʤʧ")
    private static let usTaus: Set<Character> = Set("AIOWYiuæɑəɛɪɹʊʌ")
    /// Punctuation Kokoro's vocabulary keeps.
    static let punctuation: Set<Character> = Set(";:,.!?—…\"“”()")
    private static let nonQuotePunctuation: Set<Character> = Set(";:,.!?—…")
    private static let symbols: [String: String] = ["%": "percent", "&": "and", "+": "plus", "@": "at"]
    private static let currencies: [Character: (String, String)] = ["$": ("dollar", "cent"), "£": ("pound", "pence"), "€": ("euro", "cent")]
    private static let ordinals: Set<String> = ["st", "nd", "rd", "th"]

    // MARK: - Tokens

    struct Token {
        var text: String
        var tag: String
        var whitespace: String
        var phonemes: String?
        var currency: Character?
        var isPunctuation = false
    }

    struct Context {
        var futureVowel: Bool?
        var futureTo = false
    }

    /// Phonemes for `text`, with whitespace and punctuation kept for Kokoro's prosody.
    func phonemize(_ text: String) -> String {
        var tokens = tokenize(Self.prepare(text))
        Self.markPastTense(&tokens)
        var context = Context()
        for index in tokens.indices.reversed() {
            if tokens[index].phonemes == nil {
                tokens[index].phonemes = phonemes(for: tokens[index], context: context)
            }
            context = Self.tokenContext(context, phonemes: tokens[index].phonemes, token: tokens[index])
        }
        var result = ""
        for token in tokens {
            guard let phonemes = token.phonemes else { continue }
            result += phonemes + token.whitespace
        }
        // Kokoro v1.0 uses misaki's v1 symbols for flaps and glottal stops.
        result = result.replacingOccurrences(of: "ɾ", with: "T").replacingOccurrences(of: "ʔ", with: "t")
        return result.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// Normalizes typography and expands things a dictionary can't look up: times, shouting, and ellipses.
    static func prepare(_ text: String) -> String {
        var text = text
            .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "...", with: "…")
            .replacingOccurrences(of: "–", with: "—")
        // "10:30" reads "ten thirty"; "10:00" reads "ten o'clock".
        text = text.replacingOccurrences(of: #"\b(\d{1,2}):00\b"#, with: "$1 o'clock", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\b(\d{1,2}):0(\d)\b"#, with: "$1 oh $2", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\b(\d{1,2}):([1-5]\d)\b"#, with: "$1 $2", options: .regularExpression)
        // Three or more capitalized words in a row are emphasis or small caps, not acronyms.
        let shouting = try! NSRegularExpression(pattern: #"\b(?:[A-Z][A-Z']+\b[\s,;:.!?—-]*){3,}"#)
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in shouting.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += source.substring(with: match.range).lowercased()
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        return curlingQuotes(result)
    }

    /// Straight double quotes become curly ones, which Kokoro was trained on: opening after a space or
    /// the start, closing otherwise.
    static func curlingQuotes(_ text: String) -> String {
        var result = ""
        var previous: Character = " "
        for character in text {
            if character == "\"" {
                result.append(previous.isWhitespace || "([{—".contains(previous) ? "“" : "”")
            } else {
                result.append(character)
            }
            previous = character
        }
        return result
    }

    private static let pastMarkers: Set<String> = [
        "was", "were", "had", "did", "said", "went", "came", "saw", "took", "made", "got", "thought", "told", "knew",
        "found", "felt", "looked", "turned", "asked", "seemed", "left", "began", "stood", "heard", "wrote", "sat",
        "yesterday", "ago", "once", "earlier", "then",
    ]
    private static let presentMarkers: Set<String> = [
        "will", "to", "can", "could", "would", "should", "must", "may", "might", "do", "does", "'ll", "shall", "let",
    ]
    private static let perfectMarkers: Set<String> = ["had", "has", "have", "having", "was", "were", "been", "be", "being", "is", "are"]

    /// The tagger doesn't mark tense, so "read" and similar words take it from the words around them:
    /// "had read", "she read the letter and frowned" read as past; "will read" as present.
    static func markPastTense(_ tokens: inout [Token]) {
        let words = tokens.map { $0.text.lowercased() }
        let sentencePast = words.contains { pastMarkers.contains($0) || ($0.count > 4 && $0.hasSuffix("ed")) }
        for index in tokens.indices where words[index] == "read" && tokens[index].tag.hasPrefix("VB") {
            let previous = tokens[..<index].last { !$0.isPunctuation }?.text.lowercased() ?? ""
            if perfectMarkers.contains(previous) {
                tokens[index].tag = "VBN"
            } else if !presentMarkers.contains(previous), sentencePast {
                tokens[index].tag = "VBD"
            }
        }
    }

    private static let tokenPattern = try! NSRegularExpression(pattern: [
        // Currency amounts and numbers, with ordinal or plural suffixes.
        #"[$£€]?\d+(?:,\d{3})*(?:\.\d+)?(?:st|nd|rd|th|s|'s)?"#,
        // Abbreviations with periods: "U.S.", "e.g.".
        #"(?:\p{L}\.){2,}"#,
        // Words, with internal apostrophes and hyphens, and an optional leading apostrophe ("'em").
        #"'?[\p{L}\p{M}][\p{L}\p{M}\p{N}]*(?:['-][\p{L}\p{M}\p{N}]+)*'?"#,
        #"\.\.\.|…|[—–-]+"#,
        #"\S"#,
    ].joined(separator: "|"))

    private static let knownAbbreviations: Set<String> = ["Mr", "Mrs", "Ms", "Dr", "Jr", "Sr", "St", "Prof", "Mt", "vs", "etc", "No", "Gen", "Capt", "Lt", "Col", "Rev"]

    func tokenize(_ text: String) -> [Token] {
        let source = text as NSString
        let matches = Self.tokenPattern.matches(in: text, range: NSRange(location: 0, length: source.length))
        var tokens: [Token] = []
        var ranges: [NSRange] = []
        var index = 0
        while index < matches.count {
            var range = matches[index].range
            var word = source.substring(with: range)
            // "Mr." keeps its period when the dictionary knows the abbreviation.
            if index + 1 < matches.count, source.substring(with: matches[index + 1].range) == ".",
               matches[index + 1].range.location == range.location + range.length,
               golds[word + "."] != nil || Self.knownAbbreviations.contains(word) {
                range.length += 1
                word += "."
                index += 1
            }
            let end = range.location + range.length
            let next = index + 1 < matches.count ? matches[index + 1].range.location : source.length
            let whitespace = next > end ? " " : ""
            // Single quotation marks around words aren't apostrophes: 'Hello' is "Hello".
            if word.count > 1, word.hasPrefix("'"), golds[word] == nil, silvers[word] == nil {
                word.removeFirst()
                range.location += 1
                range.length -= 1
            }
            if word.count > 1, word.hasSuffix("'"), !word.hasSuffix("s'"), golds[word] == nil, silvers[word] == nil {
                word.removeLast()
                range.length -= 1
            }
            tokens.append(Token(text: word, tag: "", whitespace: whitespace))
            ranges.append(range)
            index += 1
        }
        tagPartsOfSpeech(&tokens, ranges: ranges, in: text)
        assignCurrency(&tokens)
        return tokens
    }

    private func tagPartsOfSpeech(_ tokens: inout [Token], ranges: [NSRange], in text: String) {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)
        var tags: [Int: NLTag] = [:]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .joinContractions]) { tag, range in
            if let tag { tags[NSRange(range, in: text).location] = tag }
            return true
        }
        var sentenceStart = true
        for index in tokens.indices {
            let token = tokens[index]
            let tag = tags[ranges[index].location]
            let first = token.text.first
            if let first, !first.isLetter, !first.isNumber, first != "'", !"$£€".contains(first) {
                tokens[index].isPunctuation = true
                tokens[index].tag = "."
                sentenceStart = ".!?".contains(first) || (sentenceStart && "\"“(".contains(first))
                continue
            }
            var mapped: String
            switch tag {
            case .noun: mapped = "NN"
            case .verb: mapped = "VB"
            case .adjective: mapped = "JJ"
            case .adverb: mapped = "RB"
            case .pronoun: mapped = "PRP"
            case .determiner: mapped = "DT"
            case .preposition: mapped = "IN"
            case .conjunction: mapped = "CC"
            case .number: mapped = "CD"
            case .particle: mapped = token.text.lowercased() == "to" ? "TO" : "RP"
            case .interjection: mapped = "UH"
            default: mapped = first?.isNumber == true ? "CD" : "NN"
            }
            // Capitalized nouns mid-sentence are proper names.
            if mapped == "NN", let first, first.isUppercase, !sentenceStart { mapped = "NNP" }
            if token.text.lowercased() == "to", mapped == "IN" { mapped = "TO" }
            tokens[index].tag = mapped
            sentenceStart = false
        }
    }

    private func assignCurrency(_ tokens: inout [Token]) {
        for index in tokens.indices {
            guard let first = tokens[index].text.first, Self.currencies[first] != nil, tokens[index].text.count > 1 else { continue }
            tokens[index].currency = first
            tokens[index].text.removeFirst()
            tokens[index].tag = "CD"
        }
    }

    static func tokenContext(_ context: Context, phonemes: String?, token: Token) -> Context {
        var vowel = context.futureVowel
        if let phonemes, !phonemes.isEmpty {
            for character in phonemes {
                if nonQuotePunctuation.contains(character) { vowel = nil; break }
                if vowels.contains(character) { vowel = true; break }
                if consonants.contains(character) { vowel = false; break }
            }
        }
        let lower = token.text
        let futureTo = lower == "to" || lower == "To" || (lower == "TO" && (token.tag == "TO" || token.tag == "IN"))
        return Context(futureVowel: vowel, futureTo: futureTo)
    }

    // MARK: - Words

    func phonemes(for token: Token, context: Context) -> String? {
        let text = token.text
        if token.isPunctuation {
            if text == "-" || text.allSatisfy({ $0 == "—" || $0 == "-" }) { return "—" }
            if let symbol = Self.symbols[text] { return lookup(symbol, tag: nil, stress: nil, context: context).0.map { " " + $0 } }
            let kept = String(text.filter { Self.punctuation.contains($0) })
            return kept
        }
        let word = Self.numericizingDigits(text.precomposedStringWithCompatibilityMapping)
        let stress: Double? = word == word.lowercased() ? nil : (word == word.uppercased() ? 2 : 0.5)
        if let (phonemes, _) = getWord(word, tag: token.tag, stress: stress, context: context) {
            return Self.applyStress(appendCurrency(phonemes, token.currency), stress: nil)
        }
        if Self.isNumber(word) {
            return getNumber(word, currency: token.currency)
        }
        // Loanwords with accents are usually in the dictionary without them: "café", "naïve".
        let folded = word.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
        if folded != word, let (phonemes, _) = getWord(folded, tag: token.tag, stress: stress, context: context) {
            return phonemes
        }
        // Hyphenated compounds the dictionary lacks: read each part.
        if word.contains("-") {
            let parts = word.split(separator: "-").map(String.init).filter { !$0.isEmpty }
            let spoken = parts.compactMap { phonemes(for: Token(text: $0, tag: token.tag, whitespace: ""), context: context) }
            return Self.reduceCompoundStress(spoken).joined()
        }
        let letters = word.filter(\.isLetter)
        guard !letters.isEmpty else { return "" }
        // Short all-caps words are initialisms: "FBI".
        if word == word.uppercased(), letters.count <= 5, let spelled = getNNP(letters).0 { return spelled }
        if let fallback {
            let result = fallback.phonemes(for: folded.replacingOccurrences(of: "'", with: ""))
            if !result.isEmpty { return result }
        }
        return getNNP(letters).0
    }

    /// misaki halves the stress of all but the strongest parts of a compound read piece by piece.
    private static func reduceCompoundStress(_ parts: [String]) -> [String] {
        guard parts.count >= 2 else { return parts }
        var result = parts
        let ranked = parts.indices.map { (parts[$0].contains(primaryStress) ? 1 : 0, stressWeight(parts[$0]), $0) }
        if ranked.count == 2, parts[0].count == 1 {
            result[1] = applyStress(result[1], stress: -0.5)
            return result
        }
        guard ranked.filter({ $0.0 == 1 }).count > (ranked.count + 1) / 2 else { return result }
        for item in ranked.sorted(by: { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }).prefix(ranked.count / 2) {
            result[item.2] = applyStress(result[item.2], stress: -0.5)
        }
        return result
    }

    private static func stressWeight(_ phonemes: String) -> Int {
        phonemes.reduce(0) { $0 + (diphthongs.contains($1) ? 2 : 1) }
    }

    /// Other scripts' digits as ASCII digits.
    private static func numericizingDigits(_ word: String) -> String {
        String(word.map { character -> Character in
            guard !character.isASCII, let value = character.wholeNumberValue, value < 10 else { return character }
            return Character(String(value))
        })
    }

    func isKnown(_ word: String, tag: String?) -> Bool {
        if golds[word] != nil || Self.symbols[word] != nil || silvers[word] != nil { return true }
        guard word.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "'" || $0 == "-") }) else { return false }
        if word.count == 1 { return true }
        if word == word.uppercased(), golds[word.lowercased()] != nil { return true }
        let tail = word.dropFirst()
        return tail == tail.uppercased() && word.contains(where: \.isLetter) && tail.contains(where: \.isLetter)
    }

    func lookup(_ word: String, tag: String?, stress: Double?, context: Context?) -> (String?, Int) {
        var word = word
        var tag = tag
        var isNNP: Bool?
        if word == word.uppercased(), golds[word] == nil {
            word = word.lowercased()
            isNNP = tag == "NNP"
        }
        var entry = golds[word]
        var rating = 4
        if entry == nil, isNNP != true {
            entry = silvers[word]
            rating = 3
        }
        var phonemes: String?
        switch entry {
        case .single(let value): phonemes = value
        case .tagged(let values):
            if context != nil, context?.futureVowel == nil, values["None"] != nil {
                tag = "None"
            } else if let current = tag, values[current] == nil {
                tag = Self.parentTag(current)
            }
            phonemes = (tag.flatMap { values[$0] } ?? values["DEFAULT"]) ?? nil
        case nil: phonemes = nil
        }
        if phonemes == nil || (isNNP == true && !(phonemes?.contains(Self.primaryStress) ?? false)) {
            let spelled = getNNP(word)
            if spelled.0 != nil { return spelled }
        }
        return (phonemes.map { Self.applyStress($0, stress: stress) }, rating)
    }

    static func parentTag(_ tag: String) -> String {
        if tag.hasPrefix("VB") { return "VERB" }
        if tag.hasPrefix("NN") { return "NOUN" }
        if tag.hasPrefix("ADV") || tag.hasPrefix("RB") { return "ADV" }
        if tag.hasPrefix("ADJ") || tag.hasPrefix("JJ") { return "ADJ" }
        return tag
    }

    /// Spells a word letter by letter, stressing the last letter: "FBI" → "ˌɛfbˌiˈI".
    func getNNP(_ word: String) -> (String?, Int) {
        var parts: [String] = []
        for character in word where character.isLetter {
            guard case .single(let value) = golds[String(character).uppercased()] else { return (nil, 0) }
            parts.append(value)
        }
        guard !parts.isEmpty else { return (nil, 0) }
        let joined = Self.applyStress(parts.joined(), stress: 0)
        guard let last = joined.lastIndex(of: Self.secondaryStress) else { return (joined, 3) }
        var result = joined
        result.replaceSubrange(last...last, with: String(Self.primaryStress))
        return (result, 3)
    }

    func specialCase(_ word: String, tag: String, stress: Double?, context: Context) -> (String?, Int)? {
        switch word {
        case "a", "A":
            return (tag == "DT" ? "ɐ" : "ˈA", 4)
        case "am", "Am", "AM":
            if tag.hasPrefix("NN") { return getNNP(word) }
            if context.futureVowel == nil || word != "am" || (stress ?? 0) > 0, case .single(let value) = golds["am"] {
                return (value, 4)
            }
            return ("ɐm", 4)
        case "an", "An", "AN":
            if word == "AN", tag.hasPrefix("NN") { return getNNP(word) }
            return ("ɐn", 4)
        case "I":
            if tag == "PRP" { return ("\(Self.secondaryStress)I", 4) }
        case "by", "By", "BY":
            if Self.parentTag(tag) == "ADV" { return ("bˈI", 4) }
        case "to", "To", "TO":
            guard word != "TO" || tag == "TO" || tag == "IN" else { return nil }
            switch context.futureVowel {
            case nil: if case .single(let value) = golds["to"] { return (value, 4) }; return ("tə", 4)
            case false: return ("tə", 4)
            case true: return ("tʊ", 4)
            }
        case "in", "In", "IN":
            guard word != "IN" || tag != "NNP" else { return nil }
            let mark = context.futureVowel == nil || tag != "IN" ? String(Self.primaryStress) : ""
            return (mark + "ɪn", 4)
        case "the", "The", "THE":
            guard word != "THE" || tag == "DT" else { return nil }
            return (context.futureVowel == true ? "ði" : "ðə", 4)
        case "used", "Used", "USED":
            guard case .tagged(let values) = golds["used"] else { return nil }
            if tag.hasPrefix("VB") || tag == "JJ", context.futureTo, let past = values["VBD"] ?? nil { return (past, 4) }
            return ((values["DEFAULT"] ?? nil), 4)
        default:
            break
        }
        if tag == "IN", word.lowercased().range(of: #"^vs\.?$"#, options: .regularExpression) != nil {
            return lookup("versus", tag: nil, stress: nil, context: context)
        }
        if let symbol = Self.symbols[word] { return lookup(symbol, tag: nil, stress: nil, context: context) }
        // Dotted abbreviations of short parts: "U.S." → "U S".
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if trimmed.contains("."), word.replacingOccurrences(of: ".", with: "").allSatisfy(\.isLetter),
           (word.split(separator: ".").map(\.count).max() ?? 0) < 3 {
            return getNNP(word)
        }
        return nil
    }

    func getWord(_ word: String, tag: String, stress: Double?, context: Context) -> (String, Int)? {
        if let special = specialCase(word, tag: tag, stress: stress, context: context) {
            return special.0.map { ($0, special.1) }
        }
        var word = word
        let lower = word.lowercased()
        if word.count > 1, word.replacingOccurrences(of: "'", with: "").allSatisfy(\.isLetter), word != lower,
           tag != "NNP" || word.count > 7, golds[word] == nil, silvers[word] == nil,
           word == word.uppercased() || word.dropFirst() == word.dropFirst().lowercased(),
           golds[lower] != nil || silvers[lower] != nil
            || stemS(lower, tag: tag, stress: stress, context: context) != nil
            || stemEd(lower, tag: tag, stress: stress, context: context) != nil
            || stemIng(lower, tag: tag, stress: stress, context: context) != nil {
            word = lower
        }
        if isKnown(word, tag: tag) {
            let result = lookup(word, tag: tag, stress: stress, context: context)
            return result.0.map { ($0, result.1) }
        }
        if word.hasSuffix("s'"), isKnown(String(word.dropLast(2)) + "'s", tag: tag) {
            let result = lookup(String(word.dropLast(2)) + "'s", tag: tag, stress: stress, context: context)
            return result.0.map { ($0, result.1) }
        }
        if word.hasSuffix("'"), isKnown(String(word.dropLast()), tag: tag) {
            let result = lookup(String(word.dropLast()), tag: tag, stress: stress, context: context)
            return result.0.map { ($0, result.1) }
        }
        if let result = stemS(word, tag: tag, stress: stress, context: context) { return result }
        if let result = stemEd(word, tag: tag, stress: stress, context: context) { return result }
        if let result = stemIng(word, tag: tag, stress: stress ?? 0.5, context: context) { return result }
        return nil
    }

    // MARK: - Suffixes

    private func suffixS(_ stem: String?) -> String? {
        guard let stem, let last = stem.last else { return nil }
        if "ptkfθ".contains(last) { return stem + "s" }
        if "szʃʒʧʤ".contains(last) { return stem + "ᵻz" }
        return stem + "z"
    }

    func stemS(_ word: String, tag: String?, stress: Double?, context: Context?) -> (String, Int)? {
        guard word.count >= 3, word.hasSuffix("s") else { return nil }
        let stem: String
        if !word.hasSuffix("ss"), isKnown(String(word.dropLast()), tag: tag) {
            stem = String(word.dropLast())
        } else if (word.hasSuffix("'s") || (word.count > 4 && word.hasSuffix("es") && !word.hasSuffix("ies"))),
                  isKnown(String(word.dropLast(2)), tag: tag) {
            stem = String(word.dropLast(2))
        } else if word.count > 4, word.hasSuffix("ies"), isKnown(String(word.dropLast(3)) + "y", tag: tag) {
            stem = String(word.dropLast(3)) + "y"
        } else {
            return nil
        }
        let (phonemes, rating) = lookup(stem, tag: tag, stress: stress, context: context)
        return suffixS(phonemes).map { ($0, rating) }
    }

    private func suffixEd(_ stem: String?) -> String? {
        guard let stem, let last = stem.last else { return nil }
        if "pkfθʃsʧ".contains(last) { return stem + "t" }
        if last == "d" { return stem + "ᵻd" }
        if last != "t" { return stem + "d" }
        if stem.count < 2 { return stem + "ɪd" }
        let previous = stem[stem.index(stem.endIndex, offsetBy: -2)]
        if Self.usTaus.contains(previous) { return String(stem.dropLast()) + "ɾᵻd" }
        return stem + "ᵻd"
    }

    func stemEd(_ word: String, tag: String?, stress: Double?, context: Context?) -> (String, Int)? {
        guard word.count >= 4, word.hasSuffix("d") else { return nil }
        let stem: String
        if !word.hasSuffix("dd"), isKnown(String(word.dropLast()), tag: tag) {
            stem = String(word.dropLast())
        } else if word.count > 4, word.hasSuffix("ed"), !word.hasSuffix("eed"), isKnown(String(word.dropLast(2)), tag: tag) {
            stem = String(word.dropLast(2))
        } else {
            return nil
        }
        let (phonemes, rating) = lookup(stem, tag: tag, stress: stress, context: context)
        return suffixEd(phonemes).map { ($0, rating) }
    }

    private func suffixIng(_ stem: String?) -> String? {
        guard let stem, !stem.isEmpty else { return nil }
        if stem.count > 1, stem.last == "t", Self.usTaus.contains(stem[stem.index(stem.endIndex, offsetBy: -2)]) {
            return String(stem.dropLast()) + "ɾɪŋ"
        }
        return stem + "ɪŋ"
    }

    func stemIng(_ word: String, tag: String?, stress: Double?, context: Context?) -> (String, Int)? {
        guard word.count >= 5, word.hasSuffix("ing") else { return nil }
        let base = String(word.dropLast(3))
        let stem: String
        if word.count > 5, isKnown(base, tag: tag) {
            stem = base
        } else if isKnown(base + "e", tag: tag) {
            stem = base + "e"
        } else if word.count > 5, word.range(of: #"([bcdgklmnprstvxz])\1ing$|cking$"#, options: .regularExpression) != nil,
                  isKnown(String(word.dropLast(4)), tag: tag) {
            stem = String(word.dropLast(4))
        } else {
            return nil
        }
        let (phonemes, rating) = lookup(stem, tag: tag, stress: stress, context: context)
        return suffixIng(phonemes).map { ($0, rating) }
    }

    // MARK: - Stress

    static func applyStress(_ phonemes: String, stress: Double?) -> String {
        guard let stress else { return phonemes }
        let hasPrimary = phonemes.contains(primaryStress)
        let hasSecondary = phonemes.contains(secondaryStress)
        let hasVowel = phonemes.contains { vowels.contains($0) }
        if stress < -1 {
            return phonemes.filter { $0 != primaryStress && $0 != secondaryStress }
        }
        if stress == -1 || ((stress == 0 || stress == -0.5) && hasPrimary) {
            return String(phonemes.filter { $0 != secondaryStress }.map { $0 == primaryStress ? secondaryStress : $0 })
        }
        if (stress == 0 || stress == 0.5 || stress == 1), !hasPrimary, !hasSecondary {
            return hasVowel ? restress(String(secondaryStress) + phonemes) : phonemes
        }
        if stress >= 1, !hasPrimary, hasSecondary {
            return String(phonemes.map { $0 == secondaryStress ? primaryStress : $0 })
        }
        if stress > 1, !hasPrimary, !hasSecondary {
            return hasVowel ? restress(String(primaryStress) + phonemes) : phonemes
        }
        return phonemes
    }

    /// Moves each stress mark to sit just before the vowel it stresses.
    private static func restress(_ phonemes: String) -> String {
        let characters = Array(phonemes)
        var positioned: [(Double, Character)] = characters.enumerated().map { (Double($0.offset), $0.element) }
        for (index, character) in characters.enumerated() where character == primaryStress || character == secondaryStress {
            if let vowel = characters[index...].firstIndex(where: { vowels.contains($0) }) {
                positioned[index] = (Double(vowel) - 0.5, character)
            }
        }
        return String(positioned.sorted { $0.0 < $1.0 }.map(\.1))
    }

    // MARK: - Numbers

    static func isNumber(_ word: String) -> Bool {
        guard word.contains(where: \.isNumber) else { return false }
        var core = word
        for suffix in ["ing", "'d", "ed", "'s", "st", "nd", "rd", "th", "s"] where core.hasSuffix(suffix) {
            core = String(core.dropLast(suffix.count))
            break
        }
        return core.allSatisfy { $0.isNumber || $0 == "," || $0 == "." }
    }

    private func appendCurrency(_ phonemes: String, _ currency: Character?) -> String {
        guard let currency, let names = Self.currencies[currency] else { return phonemes }
        return "\(phonemes) \(dictionaryWord(names.0 + "s"))"
    }

    /// A word from the dictionary, or from the fallback model if it isn't there (never spelled out).
    private func dictionaryWord(_ text: String) -> String {
        if let (phonemes, _) = getWord(text, tag: "NN", stress: nil, context: Context()) { return phonemes }
        return fallback?.phonemes(for: text) ?? text
    }

    private func spoken(_ words: String) -> String {
        words.split(whereSeparator: { !$0.isLetter }).compactMap { word -> String? in
            let piece = String(word)
            guard piece != "and" else { return nil }
            return lookup(piece, tag: nil, stress: piece == "point" ? -2 : nil, context: nil).0
        }.joined(separator: " ")
    }

    func getNumber(_ word: String, currency: Character?) -> String {
        var number = word
        var suffix = ""
        if let match = number.range(of: #"[a-z']+$"#, options: .regularExpression) {
            suffix = String(number[match])
            number.removeSubrange(match)
        }
        let digitsOnly = number.replacingOccurrences(of: ",", with: "")
        var result: String
        if Self.ordinals.contains(suffix), let value = Int(digitsOnly) {
            result = spoken(NumberWords.ordinal(value))
            suffix = ""
        } else if currency == nil, number.count == 4, let value = Int(number), (1000...2099).contains(value) {
            result = spoken(NumberWords.year(value))
        } else if let currency, let names = Self.currencies[currency] {
            let parts = digitsOnly.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            let whole = Int(parts.first ?? "") ?? 0
            let cents = parts.count > 1 ? Int(String(parts[1].prefix(2)).padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0 : 0
            var pieces: [String] = []
            if whole != 0 || cents == 0 {
                pieces.append(spoken(NumberWords.cardinal(whole)))
                pieces.append(dictionaryWord(whole == 1 ? names.0 : names.0 + "s"))
            }
            if cents != 0 {
                if !pieces.isEmpty, let and = lookup("and", tag: nil, stress: nil, context: nil).0 { pieces.append(and) }
                pieces.append(spoken(NumberWords.cardinal(cents)))
                pieces.append(dictionaryWord(cents == 1 || names.1 == "pence" ? names.1 : names.1 + "s"))
            }
            result = pieces.filter { !$0.isEmpty }.joined(separator: " ")
        } else if digitsOnly.contains(".") {
            let parts = digitsOnly.split(separator: ".", omittingEmptySubsequences: false)
            let whole = parts.first.map(String.init) ?? ""
            var words = whole.isEmpty ? "" : NumberWords.cardinal(Int(whole) ?? 0)
            words += " point " + (parts.count > 1 ? parts[1].map { NumberWords.cardinal(Int(String($0)) ?? 0) }.joined(separator: " ") : "")
            result = spoken(words)
        } else if let value = Int(digitsOnly) {
            // Long digit strings without commas, like phone numbers, read digit by digit.
            if digitsOnly.count > 9 || (digitsOnly.hasPrefix("0") && digitsOnly.count > 1) {
                result = spoken(digitsOnly.map { NumberWords.cardinal(Int(String($0)) ?? 0) }.joined(separator: " "))
            } else {
                result = spoken(NumberWords.cardinal(value))
            }
        } else {
            result = spoken(digitsOnly.compactMap { Int(String($0)) }.map(NumberWords.cardinal).joined(separator: " "))
        }
        switch suffix {
        case "s", "'s": return suffixS(result) ?? result
        case "ed", "'d": return suffixEd(result) ?? result
        case "ing": return suffixIng(result) ?? result
        default: return result
        }
    }
}

/// English number words, independent of the device's locale.
nonisolated enum NumberWords {
    private static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                               "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    private static let scales: [(Int, String)] = [(1_000_000_000_000, "trillion"), (1_000_000_000, "billion"),
                                                  (1_000_000, "million"), (1_000, "thousand")]

    static func cardinal(_ value: Int) -> String {
        if value < 0 { return "minus " + cardinal(-value) }
        if value < 20 { return ones[value] }
        if value < 100 { return tens[value / 10] + (value % 10 == 0 ? "" : "-" + ones[value % 10]) }
        if value < 1000 {
            return ones[value / 100] + " hundred" + (value % 100 == 0 ? "" : " " + cardinal(value % 100))
        }
        for (scale, name) in scales where value >= scale {
            return cardinal(value / scale) + " " + name + (value % scale == 0 ? "" : " " + cardinal(value % scale))
        }
        return String(value)
    }

    static func ordinal(_ value: Int) -> String {
        let words = cardinal(value)
        let irregular = ["one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth",
                         "nine": "ninth", "twelve": "twelfth"]
        let separators = CharacterSet(charactersIn: " -")
        let lastRange = words.rangeOfCharacter(from: separators, options: .backwards)
        let prefix = lastRange.map { String(words[..<$0.upperBound]) } ?? ""
        let last = lastRange.map { String(words[$0.upperBound...]) } ?? words
        if let replacement = irregular[last] { return prefix + replacement }
        if last.hasSuffix("y") { return prefix + last.dropLast() + "ieth" }
        return prefix + last + "th"
    }

    /// Years read in pairs: 1984 "nineteen eighty-four", 1905 "nineteen oh five", 2005 "two thousand five".
    static func year(_ value: Int) -> String {
        guard value >= 1000, value < 10000 else { return cardinal(value) }
        let high = value / 100
        let low = value % 100
        if value % 1000 < 10, (2000...2009).contains(value) || value % 1000 == 0 {
            return cardinal(value)
        }
        if low == 0 { return cardinal(high) + " hundred" }
        if low < 10 { return cardinal(high) + " oh " + cardinal(low) }
        return cardinal(high) + " " + cardinal(low)
    }
}
