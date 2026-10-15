import Foundation

/// Namespaces used across OCF, package, and content documents.
nonisolated enum XMLNamespace {
    static let opf = "http://www.idpf.org/2007/opf"
    static let dc = "http://purl.org/dc/elements/1.1/"
    static let ops = "http://www.idpf.org/2007/ops"
    static let xhtml = "http://www.w3.org/1999/xhtml"
    static let container = "urn:oasis:names:tc:opendocument:xmlns:container"
    static let ncx = "http://www.daisy.org/z3986/2005/ncx/"
    static let encryption = "http://www.w3.org/2001/04/xmlenc#"
    static let smil = "http://www.w3.org/ns/SMIL"
    static let xml = "http://www.w3.org/XML/1998/namespace"
}

/// A minimal, immutable, namespace-aware XML element tree.
nonisolated final class MarkupElement: Sendable {
    struct Attribute: Sendable {
        let name: String
        let namespace: String?
        let value: String
    }

    enum Child: Sendable {
        case element(MarkupElement)
        case text(String)
    }

    let name: String
    let namespace: String?
    let attributes: [Attribute]
    let children: [Child]

    init(name: String, namespace: String?, attributes: [Attribute], children: [Child]) {
        self.name = name
        self.namespace = namespace
        self.attributes = attributes
        self.children = children
    }

    var elements: [MarkupElement] {
        children.compactMap { if case .element(let element) = $0 { element } else { nil } }
    }

    /// Looks up an attribute by local name. Pass a namespace to require it; unprefixed attributes have none.
    func attribute(_ name: String, namespace: String? = nil) -> String? {
        attributes.first { $0.name == name && (namespace == nil || $0.namespace == namespace) }?.value
    }

    func children(named name: String, namespace: String? = nil) -> [MarkupElement] {
        elements.filter { $0.matches(name, namespace) }
    }

    func child(named name: String, namespace: String? = nil) -> MarkupElement? {
        elements.first { $0.matches(name, namespace) }
    }

    /// Depth-first search of all descendants.
    func descendants(named name: String, namespace: String? = nil) -> [MarkupElement] {
        var result: [MarkupElement] = []
        func walk(_ element: MarkupElement) {
            for child in element.elements {
                if child.matches(name, namespace) { result.append(child) }
                walk(child)
            }
        }
        walk(self)
        return result
    }

    func firstDescendant(named name: String, namespace: String? = nil) -> MarkupElement? {
        for child in elements {
            if child.matches(name, namespace) { return child }
            if let match = child.firstDescendant(named: name, namespace: namespace) { return match }
        }
        return nil
    }

    var textContent: String {
        children.map {
            switch $0 {
            case .text(let text): text
            case .element(let element): element.textContent
            }
        }.joined()
    }

    /// Text content with runs of whitespace collapsed, as a reader would display a label.
    var normalizedText: String {
        textContent.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Whitespace-separated tokens of an attribute such as `epub:type` or `properties`.
    func tokens(_ name: String, namespace: String? = nil) -> Set<String> {
        Set((attribute(name, namespace: namespace) ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
    }

    private func matches(_ name: String, _ namespace: String?) -> Bool {
        self.name == name && (namespace == nil || self.namespace == namespace)
    }
}

nonisolated enum MarkupError: LocalizedError {
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let detail): "A book file couldn't be read: \(detail)"
        }
    }
}

nonisolated enum MarkupParser {
    static func parse(_ data: Data) throws -> MarkupElement {
        let builder = TreeBuilder()
        let parser = XMLParser(data: HTMLEntities.numericized(data))
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw MarkupError.malformed(parser.parserError?.localizedDescription ?? "Invalid XML")
        }
        return root
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        private final class Pending {
            let name: String
            let namespace: String?
            let attributes: [MarkupElement.Attribute]
            var children: [MarkupElement.Child] = []

            init(name: String, namespace: String?, attributes: [MarkupElement.Attribute]) {
                self.name = name
                self.namespace = namespace
                self.attributes = attributes
            }
        }

        private var stack: [Pending] = []
        private var prefixes: [String: [String]] = ["xml": [XMLNamespace.xml]]
        private(set) var root: MarkupElement?

        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
            prefixes[prefix, default: []].append(namespaceURI)
        }

        func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
            prefixes[prefix]?.removeLast()
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            let attributes = attributeDict.map { key, value -> MarkupElement.Attribute in
                guard let colon = key.firstIndex(of: ":") else {
                    return .init(name: key, namespace: nil, value: value)
                }
                let prefix = String(key[..<colon])
                let local = String(key[key.index(after: colon)...])
                return .init(name: local, namespace: prefixes[prefix]?.last ?? prefix, value: value)
            }
            let namespace = namespaceURI.flatMap { $0.isEmpty ? nil : $0 }
            stack.append(Pending(name: elementName, namespace: namespace, attributes: attributes))
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard let pending = stack.popLast() else { return }
            let element = MarkupElement(
                name: pending.name, namespace: pending.namespace,
                attributes: pending.attributes, children: pending.children)
            if let parent = stack.last {
                parent.children.append(.element(element))
            } else {
                root = element
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            appendText(string)
        }

        func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) {
            appendText(whitespaceString)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            appendText(String(decoding: CDATABlock, as: UTF8.self))
        }

        private func appendText(_ text: String) {
            guard let current = stack.last else { return }
            if case .text(let previous) = current.children.last {
                current.children[current.children.count - 1] = .text(previous + text)
            } else {
                current.children.append(.text(text))
            }
        }
    }
}

/// Rewrites common HTML named entities as numeric references so strict XML parsing
/// accepts content documents that rely on an (unloaded) XHTML DTD.
nonisolated enum HTMLEntities {
    static let table: [String: UInt32] = [
        "nbsp": 160, "iexcl": 161, "cent": 162, "pound": 163, "curren": 164, "yen": 165, "brvbar": 166,
        "sect": 167, "uml": 168, "copy": 169, "ordf": 170, "laquo": 171, "not": 172, "shy": 173,
        "reg": 174, "macr": 175, "deg": 176, "plusmn": 177, "sup2": 178, "sup3": 179, "acute": 180,
        "micro": 181, "para": 182, "middot": 183, "cedil": 184, "sup1": 185, "ordm": 186, "raquo": 187,
        "frac14": 188, "frac12": 189, "frac34": 190, "iquest": 191, "Agrave": 192, "Aacute": 193,
        "Acirc": 194, "Atilde": 195, "Auml": 196, "Aring": 197, "AElig": 198, "Ccedil": 199,
        "Egrave": 200, "Eacute": 201, "Ecirc": 202, "Euml": 203, "Igrave": 204, "Iacute": 205,
        "Icirc": 206, "Iuml": 207, "ETH": 208, "Ntilde": 209, "Ograve": 210, "Oacute": 211,
        "Ocirc": 212, "Otilde": 213, "Ouml": 214, "times": 215, "Oslash": 216, "Ugrave": 217,
        "Uacute": 218, "Ucirc": 219, "Uuml": 220, "Yacute": 221, "THORN": 222, "szlig": 223,
        "agrave": 224, "aacute": 225, "acirc": 226, "atilde": 227, "auml": 228, "aring": 229,
        "aelig": 230, "ccedil": 231, "egrave": 232, "eacute": 233, "ecirc": 234, "euml": 235,
        "igrave": 236, "iacute": 237, "icirc": 238, "iuml": 239, "eth": 240, "ntilde": 241,
        "ograve": 242, "oacute": 243, "ocirc": 244, "otilde": 245, "ouml": 246, "divide": 247,
        "oslash": 248, "ugrave": 249, "uacute": 250, "ucirc": 251, "uuml": 252, "yacute": 253,
        "thorn": 254, "yuml": 255, "OElig": 338, "oelig": 339, "Scaron": 352, "scaron": 353,
        "Yuml": 376, "fnof": 402, "circ": 710, "tilde": 732, "ensp": 8194, "emsp": 8195,
        "thinsp": 8201, "zwnj": 8204, "zwj": 8205, "lrm": 8206, "rlm": 8207, "ndash": 8211,
        "mdash": 8212, "lsquo": 8216, "rsquo": 8217, "sbquo": 8218, "ldquo": 8220, "rdquo": 8221,
        "bdquo": 8222, "dagger": 8224, "Dagger": 8225, "bull": 8226, "hellip": 8230, "permil": 8240,
        "prime": 8242, "Prime": 8243, "lsaquo": 8249, "rsaquo": 8250, "oline": 8254, "euro": 8364,
        "trade": 8482, "larr": 8592, "uarr": 8593, "rarr": 8594, "darr": 8595, "harr": 8596,
        "minus": 8722, "infin": 8734, "ne": 8800, "le": 8804, "ge": 8805, "loz": 9674,
        "alpha": 945, "beta": 946, "gamma": 947, "delta": 948, "pi": 960, "sigma": 963, "omega": 969,
    ]

    private static let pattern = try! NSRegularExpression(pattern: "&([A-Za-z][A-Za-z0-9]{1,8});")

    static func numericized(_ data: Data) -> Data {
        guard data.contains(UInt8(ascii: "&")), let text = String(data: data, encoding: .utf8) else { return data }
        let source = text as NSString
        let result = NSMutableString(string: text)
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let name = source.substring(with: match.range(at: 1))
            guard let code = table[name] else { continue }
            result.replaceCharacters(in: match.range, with: "&#\(code);")
        }
        return Data((result as String).utf8)
    }
}
