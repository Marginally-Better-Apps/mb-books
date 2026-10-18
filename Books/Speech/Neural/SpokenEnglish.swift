import Foundation

/// Writes numbers and symbols in English text as words, so the voice reads "$45.50" as "forty-five dollars and
/// fifty cents" and 1984 as "nineteen eighty-four" rather than guessing from digits.
nonisolated enum SpokenEnglish {
    private static let currencies: [Character: (String, String)] = ["$": ("dollar", "cent"), "£": ("pound", "pence"), "€": ("euro", "cent")]
    private static let ordinalSuffixes: Set<String> = ["st", "nd", "rd", "th"]

    private static let number = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\d.,])([$£€])?(\d+(?:,\d{3})*(?:\.\d+)?)(st|nd|rd|th|s|'s)?(%)?(?![\p{L}\d])"#)
    private static let shouting = try! NSRegularExpression(pattern: #"\b(?:[A-Z][A-Z']+\b[\s,;:.!?—-]*){3,}"#)

    static func normalize(_ text: String) -> String {
        var text = text
        // "10:30" reads "ten thirty"; "10:00" reads "ten o'clock".
        text = text.replacingOccurrences(of: #"\b(\d{1,2}):00\b"#, with: "$1 o'clock", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\b(\d{1,2}):0(\d)\b"#, with: "$1 oh $2", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\b(\d{1,2}):([1-5]\d)\b"#, with: "$1 $2", options: .regularExpression)
        text = replacing(number, in: text) { match, source in
            let group = { (index: Int) -> String? in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : source.substring(with: range)
            }
            var words = spoken(group(2) ?? "", currency: group(1)?.first, suffix: group(3) ?? "")
            if group(4) != nil { words += " percent" }
            return words
        }
        // Three or more capitalized words in a row are emphasis or small caps, not acronyms to spell out.
        text = replacing(shouting, in: text) { match, source in source.substring(with: match.range).lowercased() }
        for (symbol, word) in [("&", " and "), ("%", " percent "), ("@", " at "), ("+", " plus "), ("=", " equals ")] {
            text = text.replacingOccurrences(of: symbol, with: word)
        }
        for (symbol, (singular, _)) in currencies {
            text = text.replacingOccurrences(of: String(symbol), with: " \(singular)s ")
        }
        return text.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" ([,.;:!?])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func replacing(_ pattern: NSRegularExpression, in text: String,
                                  with replacement: (NSTextCheckingResult, NSString) -> String) -> String {
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += replacement(match, source)
            cursor = match.range.location + match.range.length
        }
        return result + source.substring(from: cursor)
    }

    static func spoken(_ number: String, currency: Character?, suffix: String) -> String {
        let digits = number.replacingOccurrences(of: ",", with: "")
        var suffix = suffix
        var result: String
        if ordinalSuffixes.contains(suffix), let value = Int(digits) {
            result = NumberWords.ordinal(value)
            suffix = ""
        } else if currency == nil, number.count == 4, let value = Int(number), (1000...2099).contains(value) {
            result = NumberWords.year(value)
        } else if let currency, let names = currencies[currency] {
            let parts = digits.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            let whole = Int(parts.first ?? "") ?? 0
            let cents = parts.count > 1 ? Int(String(parts[1].prefix(2)).padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0 : 0
            var pieces: [String] = []
            if whole != 0 || cents == 0 {
                pieces.append(NumberWords.cardinal(whole) + " " + (whole == 1 ? names.0 : names.0 + "s"))
            }
            if cents != 0 {
                pieces.append(NumberWords.cardinal(cents) + " " + (cents == 1 || names.1 == "pence" ? names.1 : names.1 + "s"))
            }
            result = pieces.joined(separator: " and ")
        } else if digits.contains(".") {
            let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
            let whole = parts.first.map(String.init) ?? ""
            result = (whole.isEmpty ? "" : NumberWords.cardinal(Int(whole) ?? 0) + " ") + "point "
                + (parts.count > 1 ? parts[1].map { NumberWords.cardinal(Int(String($0)) ?? 0) }.joined(separator: " ") : "")
        } else if let value = Int(digits), !(digits.count > 9 || (digits.hasPrefix("0") && digits.count > 1)) {
            result = NumberWords.cardinal(value)
        } else {
            // Long digit strings, like phone numbers, read digit by digit.
            result = digits.compactMap { Int(String($0)) }.map(NumberWords.cardinal).joined(separator: " ")
        }
        guard suffix == "s" || suffix == "'s" else { return result }
        // "1990s" reads "nineteen nineties".
        return result.hasSuffix("y") ? result.dropLast() + "ies" : result + "s"
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
