import Foundation

/// Words in an utterance, and lining up the words a voice actually said with the words on the page.
nonisolated enum SpeechWords {
    struct Word: Equatable {
        let text: String
        /// Where the word starts, in Unicode scalars (the voice model's tokenizer counts these).
        let scalarOffset: Int
        /// Where the word is, in UTF-16 (the reader's text offsets count these).
        let range: NSRange
    }

    /// Runs of letters and digits, keeping apostrophes inside words ("don't"). Hyphens separate words.
    static func words(in text: String) -> [Word] {
        var words: [Word] = []
        var scalarOffset = 0
        var utf16Offset = 0
        var current: (text: String.UnicodeScalarView, scalar: Int, utf16: Int, length: Int)?
        let scalars = Array(text.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            let isLetter = CharacterSet.alphanumerics.contains(scalar)
            let isInnerApostrophe = (scalar == "'" || scalar == "’") && current != nil
                && index + 1 < scalars.count && CharacterSet.alphanumerics.contains(scalars[index + 1])
            if isLetter || isInnerApostrophe {
                if current == nil { current = (String.UnicodeScalarView(), scalarOffset, utf16Offset, 0) }
                current?.text.append(scalar)
                current?.length += scalar.utf16.count
            } else if let word = current {
                words.append(Word(text: String(word.text), scalarOffset: word.scalar, range: NSRange(location: word.utf16, length: word.length)))
                current = nil
            }
            scalarOffset += 1
            utf16Offset += scalar.utf16.count
        }
        if let word = current {
            words.append(Word(text: String(word.text), scalarOffset: word.scalar, range: NSRange(location: word.utf16, length: word.length)))
        }
        return words
    }

    /// When each word of `text` is spoken, from the words the voice read and their start times.
    ///
    /// The voice reads a cleaned-up version of the text, with numbers written out ("$5" is "five dollars"), so the
    /// two are matched word by word. A page word with no exact match takes the time of the spoken words in its
    /// place, or of the word before it when nothing was said for it.
    static func timings(for text: String, spoken: [(text: String, time: TimeInterval)]) -> [(range: NSRange, time: TimeInterval)] {
        let page = words(in: text)
        guard !page.isEmpty, !spoken.isEmpty else { return [] }
        let pageKeys = page.map { key($0.text) }
        let spokenKeys = spoken.map { key($0.text) }
        // Longest common subsequence of the two word lists.
        var lengths = [[Int]](repeating: [Int](repeating: 0, count: spokenKeys.count + 1), count: pageKeys.count + 1)
        for i in stride(from: pageKeys.count - 1, through: 0, by: -1) {
            for j in stride(from: spokenKeys.count - 1, through: 0, by: -1) {
                lengths[i][j] = pageKeys[i] == spokenKeys[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var matches: [(page: Int, spoken: Int)] = []
        var i = 0, j = 0
        while i < pageKeys.count, j < spokenKeys.count {
            if pageKeys[i] == spokenKeys[j] {
                matches.append((i, j))
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        // Fill the gaps between matches (and before the first and after the last).
        var times = [TimeInterval?](repeating: nil, count: page.count)
        var previous = (page: -1, spoken: -1)
        for anchor in matches + [(page.count, spoken.count)] {
            let pageGap = (previous.page + 1)..<anchor.page
            let spokenGap = (previous.spoken + 1)..<anchor.spoken
            for (offset, index) in pageGap.enumerated() {
                if !spokenGap.isEmpty {
                    times[index] = spoken[spokenGap.lowerBound + offset * spokenGap.count / pageGap.count].time
                } else if previous.spoken >= 0 {
                    times[index] = spoken[previous.spoken].time
                }
            }
            if anchor.page < page.count { times[anchor.page] = spoken[anchor.spoken].time }
            previous = anchor
        }
        var latest = 0.0
        return page.indices.map { index in
            latest = max(latest, times[index] ?? latest)
            return (page[index].range, latest)
        }
    }

    private static func key(_ word: String) -> String {
        word.replacingOccurrences(of: "’", with: "'").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
