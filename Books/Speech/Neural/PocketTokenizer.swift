import Foundation

/// Pocket TTS's text tokenizer: a SentencePiece unigram model with byte fallback, read from the
/// Hugging Face `tokenizer.json` Kyutai ships with the model. Produces the same token IDs as the `tokenizers` library.
nonisolated struct PocketTokenizer: Sendable {
    private static let space: Unicode.Scalar = "▁"

    private let pieces: [String]
    private let ids: [String: Int]
    private let scores: [Float]
    private let byteIDs: [Int]
    private let unknownScore: Float
    private let longestPiece: Int
    let unknownID: Int

    init(url: URL) throws {
        struct File: Decodable {
            struct Model: Decodable {
                let vocab: [Entry]
                let unk_id: Int
            }
            struct Entry: Decodable {
                let piece: String
                let score: Float
                init(from decoder: Decoder) throws {
                    var container = try decoder.unkeyedContainer()
                    piece = try container.decode(String.self)
                    score = try container.decode(Float.self)
                }
            }
            let model: Model
        }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        pieces = file.model.vocab.map(\.piece)
        scores = file.model.vocab.map(\.score)
        unknownID = file.model.unk_id
        var ids: [String: Int] = [:]
        for (id, piece) in pieces.enumerated() where ids[piece] == nil { ids[piece] = id }
        self.ids = ids
        byteIDs = try (0...255).map { byte in
            guard let id = ids[String(format: "<0x%02X>", byte)] else { throw CocoaError(.fileReadCorruptFile) }
            return id
        }
        // As in SentencePiece: an unknown character costs more than any known piece.
        unknownScore = (scores.min() ?? 0) - 10
        longestPiece = pieces.map(\.unicodeScalars.count).max() ?? 1
    }

    static func bundled() throws -> PocketTokenizer {
        guard let url = Bundle.main.url(forResource: "pocket-tokenizer", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try PocketTokenizer(url: url)
    }

    /// Whether `character` has a piece of its own, rather than falling back to bytes the model barely saw in training.
    func knows(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { ids[String($0)] != nil }
    }

    func encode(_ text: String) -> [Int] {
        guard !text.isEmpty else { return [] }
        // Normalizer: prepend "▁"; pre-tokenizer: spaces become "▁" and every "▁" starts a new word.
        let normalized = String(Self.space) + text.replacingOccurrences(of: " ", with: String(Self.space))
        var tokens: [Int] = []
        var word: [Unicode.Scalar] = []
        // Like the reference, this works on Unicode scalars, not grapheme clusters.
        for scalar in normalized.unicodeScalars {
            if scalar == Self.space, !word.isEmpty {
                encodeWord(word, into: &tokens)
                word = []
            }
            word.append(scalar)
        }
        if !word.isEmpty { encodeWord(word, into: &tokens) }
        return tokens
    }

    func decode(_ tokens: [Int]) -> String {
        var bytes: [UInt8] = []
        for token in tokens where pieces.indices.contains(token) {
            let piece = pieces[token]
            if piece.count == 6, piece.hasPrefix("<0x"), piece.hasSuffix(">"), let byte = UInt8(piece.dropFirst(3).prefix(2), radix: 16) {
                bytes.append(byte)
            } else {
                bytes += Array(piece.replacingOccurrences(of: String(Self.space), with: " ").utf8)
            }
        }
        let text = String(decoding: bytes, as: UTF8.self)
        return text.hasPrefix(" ") ? String(text.dropFirst()) : text
    }

    /// Viterbi search for the highest-scoring split of one word into pieces.
    private func encodeWord(_ characters: [Unicode.Scalar], into tokens: inout [Int]) {
        let count = characters.count
        var best = [Float](repeating: -.infinity, count: count + 1)
        // For each end position: where the best piece ending there starts, and its ID (nil when unknown).
        var back = [(start: Int, id: Int?)](repeating: (0, nil), count: count + 1)
        best[0] = 0
        for start in 0..<count where best[start] > -.infinity {
            var piece = String.UnicodeScalarView()
            var hasSingle = false
            for end in (start + 1)...min(count, start + longestPiece) {
                piece.append(characters[end - 1])
                guard let id = ids[String(piece)] else { continue }
                if end == start + 1 { hasSingle = true }
                let score = best[start] + scores[id]
                if score > best[end] {
                    best[end] = score
                    back[end] = (start, id)
                }
            }
            if !hasSingle {
                let score = best[start] + unknownScore
                if score > best[start + 1] {
                    best[start + 1] = score
                    back[start + 1] = (start, nil)
                }
            }
        }
        var path: [(start: Int, id: Int?)] = []
        var end = count
        while end > 0 {
            path.append(back[end])
            end = back[end].start
        }
        for step in path.reversed() {
            if let id = step.id {
                tokens.append(id)
            } else {
                // Byte fallback: an unknown character becomes its UTF-8 bytes.
                tokens += String(characters[step.start]).utf8.map { byteIDs[Int($0)] }
            }
        }
    }
}

/// Getting text ready for Pocket TTS, as Kyutai's reference code does: one sentence-like chunk at a time,
/// capitalized and ending in punctuation, with characters the model never learned replaced.
nonisolated enum PocketText {
    /// The model works on up to about this many tokens at once; longer text is split.
    static let maximumTokens = 50

    private static let replacements: [Character: String] = [
        "’": "'", "‘": "'", "‛": "'", "′": "'", "“": "\"", "”": "\"", "„": "\"", "″": "\"", "«": "\"", "»": "\"",
        "…": "...", "(": ", ", ")": ", ", "[": ", ", "]": ", ", "{": ", ", "}": ", ", "/": " ", "\\": " ",
        "\n": " ", "\r": " ", "\t": " ", "\u{00A0}": " ", "\u{200B}": "", "\u{00AD}": "",
    ]

    /// Typography the model reads well. Characters without a piece of their own lose their accents, or are dropped.
    static func clean(_ text: String, tokenizer: PocketTokenizer) -> String {
        var result = ""
        for character in text {
            if let replacement = replacements[character] {
                result += replacement
            } else if character == " " || tokenizer.knows(character) {
                result.append(character)
            } else {
                let plain = String(character).applyingTransform(.stripDiacritics, reverse: false) ?? ""
                result += plain.allSatisfy(tokenizer.knows) ? plain : " "
            }
        }
        // Brackets turned into commas can leave stray spaces and doubled punctuation.
        result = result.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #",+(?=[,.!?;:])"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"^[\s,]+"#, with: "", options: .regularExpression)
        return result.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// Kyutai's `prepare_text_prompt`: capitalized, ending in sentence punctuation, and how many frames to keep
    /// after the model signals the end (short phrases need a little more).
    static func prepare(_ text: String) -> (text: String, framesAfterEnd: Int) {
        var text = text.trimmingCharacters(in: .whitespaces)
        guard let first = text.first else { return ("", 0) }
        let framesAfterEnd = (text.split(separator: " ").count <= 4 ? 3 : 1) + 2
        if !first.isUppercase { text = first.uppercased() + text.dropFirst() }
        return (terminated(text), framesAfterEnd)
    }

    private static let terminal = Set(".!?…")
    private static let weak = Set(",;:-–—")
    private static let closers = Set("\"'”’)]»")

    private static func terminated(_ text: String) -> String {
        var core = Substring(text)
        while let last = core.last, closers.contains(last) || last == " " { core.removeLast() }
        let closing = text.dropFirst(core.count).trimmingCharacters(in: .whitespaces)
        guard let last = core.last, !terminal.contains(last) else { return text }
        if weak.contains(last) {
            while let end = core.last, weak.contains(end) || end == " " { core.removeLast() }
            return core + "." + closing
        }
        return text + "."
    }

    /// Splits text into chunks of at most `maximumTokens`, at sentence ends where possible, then at commas.
    static func chunks(_ text: String, tokenizer: PocketTokenizer) -> [String] {
        let prepared = prepare(text).text
        let tokens = tokenizer.encode(prepared)
        guard tokens.count > maximumTokens else { return prepared.isEmpty ? [] : [prepared] }
        let sentenceEnds = Set(tokenizer.encode(".!...?").dropFirst())
        let clauseEnds = Set(tokenizer.encode(",;:").dropFirst())
        var segments: [(count: Int, text: String)] = []
        for sentence in Self.segments(of: tokens, endingWith: sentenceEnds) {
            if sentence.count <= maximumTokens {
                segments.append((sentence.count, tokenizer.decode(sentence)))
                continue
            }
            let clauses = Self.segments(of: tokenizer.encode(tokenizer.decode(sentence).trimmingCharacters(in: .whitespaces)),
                                        endingWith: clauseEnds)
            segments += clauses.map { ($0.count, tokenizer.decode($0)) }
        }
        var chunks: [String] = []
        var current = ""
        var currentCount = 0
        for segment in segments {
            if !current.isEmpty, currentCount + segment.count > maximumTokens {
                chunks.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                currentCount = 0
            }
            current += (current.isEmpty ? "" : " ") + segment.text
            currentCount += segment.count
        }
        if !current.isEmpty { chunks.append(current.trimmingCharacters(in: .whitespaces)) }
        return chunks
    }

    /// Runs of tokens, each ending after one or more boundary tokens.
    private static func segments(of tokens: [Int], endingWith boundaries: Set<Int>) -> [[Int]] {
        var segments: [[Int]] = []
        var current: [Int] = []
        var afterBoundary = false
        for token in tokens {
            let isBoundary = boundaries.contains(token)
            if afterBoundary, !isBoundary {
                segments.append(current)
                current = []
            }
            current.append(token)
            afterBoundary = isBoundary
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }
}
