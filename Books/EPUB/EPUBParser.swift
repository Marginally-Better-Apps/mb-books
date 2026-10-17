import Foundation

/// Read access to the files of an OCF container, zipped or extracted.
nonisolated protocol PublicationContainer: Sendable {
    func data(at path: String) throws -> Data
    func contains(_ path: String) -> Bool
}

extension ZipArchive: PublicationContainer {
    nonisolated func data(at path: String) throws -> Data { try contents(of: path) }
    nonisolated func contains(_ path: String) -> Bool { entry(path) != nil }
}

/// An extracted EPUB on disk.
nonisolated struct DirectoryContainer: PublicationContainer {
    let root: URL

    func url(for path: String) -> URL {
        path.split(separator: "/").reduce(root) { $0.appending(path: String($1)) }
    }

    func data(at path: String) throws -> Data {
        do { return try Data(contentsOf: url(for: path)) } catch { throw EPUBError.missingResource(path) }
    }

    func contains(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: path).path)
    }
}

nonisolated enum EPUBError: LocalizedError, Equatable {
    case missingContainer
    case missingPackage
    case missingResource(String)
    case emptySpine
    case drmProtected

    var errorDescription: String? {
        switch self {
        case .missingContainer: "This file isn't an EPUB. It has no META-INF/container.xml."
        case .missingPackage: "The EPUB's package document is missing."
        case .missingResource(let path): "The EPUB is missing \(path)."
        case .emptySpine: "The EPUB has no readable content."
        case .drmProtected: "This book is protected by DRM and can't be opened."
        }
    }
}

/// Container-relative URL resolution as defined by OCF.
nonisolated enum EPUBPath {
    /// Splits `href` into a container path and fragment, resolved against the file at `basePath`.
    /// Returns `nil` for references outside the container (e.g. `https:` links).
    static func resolve(_ href: String, relativeTo basePath: String) -> (path: String, fragment: String?)? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if isExternal(trimmed) { return nil }
        var reference = Substring(trimmed)
        var fragment: String?
        if let hash = reference.firstIndex(of: "#") {
            fragment = String(reference[reference.index(after: hash)...]).removingPercentEncoding
            reference = reference[..<hash]
        }
        if let query = reference.firstIndex(of: "?") { reference = reference[..<query] }
        let decoded = String(reference).removingPercentEncoding ?? String(reference)

        if decoded.isEmpty { return (basePath, fragment) }
        var components: [String] = decoded.hasPrefix("/")
            ? []
            : basePath.split(separator: "/").dropLast().map(String.init)
        for component in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(String(component))
            }
        }
        return (components.joined(separator: "/"), fragment?.isEmpty == true ? nil : fragment)
    }

    static func isExternal(_ href: String) -> Bool {
        guard let colon = href.firstIndex(of: ":") else { return false }
        let scheme = href[..<colon]
        return !scheme.isEmpty && !scheme.contains("/") && scheme.allSatisfy { $0.isLetter || $0.isNumber || "+-.".contains($0) }
    }
}

nonisolated enum EPUBParser {
    static func parse(_ container: some PublicationContainer) throws -> Publication {
        let packagePath = try packagePath(in: container)
        let package = try MarkupParser.parse(container.data(at: packagePath))
        guard package.name == "package" else { throw EPUBError.missingPackage }
        let obfuscated = try obfuscatedResources(in: container)

        let metadataElement = package.child(named: "metadata")
        let meta = MetaTable(metadataElement)
        let metadata = parseMetadata(metadataElement, package: package, meta: meta)
        let manifest = parseManifest(package.child(named: "manifest"), packagePath: packagePath)
        let manifestByID = Dictionary(manifest.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let globalLayout = layout(meta: meta)
        let spineElement = package.child(named: "spine")
        let spine = parseSpine(spineElement, manifest: manifestByID, globalLayout: globalLayout)
        guard !spine.isEmpty else { throw EPUBError.emptySpine }

        let progression = Publication.ReadingProgression(
            rawValue: spineElement?.attribute("page-progression-direction") ?? "") ?? .auto

        var publication = Publication(
            version: package.attribute("version") ?? "3.0",
            packagePath: packagePath,
            metadata: metadata,
            manifest: manifest,
            spine: spine,
            tableOfContents: [],
            pageList: [],
            landmarks: [],
            layout: globalLayout,
            readingProgression: progression,
            coverPath: coverPath(manifest: manifest, meta: meta, manifestByID: manifestByID),
            navigationDocumentPath: manifest.first { $0.properties.contains("nav") }?.path,
            obfuscatedResources: obfuscated)

        if let navPath = publication.navigationDocumentPath,
           let navigation = try? NavigationParser.parseNavigationDocument(container.data(at: navPath), path: navPath) {
            publication.tableOfContents = navigation.toc
            publication.pageList = navigation.pageList
            publication.landmarks = navigation.landmarks
        }
        if publication.tableOfContents.isEmpty,
           let ncxID = spineElement?.attribute("toc"),
           let ncx = manifestByID[ncxID] ?? manifest.first(where: { $0.mediaType == "application/x-dtbncx+xml" }),
           let data = try? container.data(at: ncx.path) {
            let navigation = (try? NavigationParser.parseNCX(data, path: ncx.path))
            publication.tableOfContents = navigation?.toc ?? []
            if publication.pageList.isEmpty { publication.pageList = navigation?.pageList ?? [] }
        }
        if publication.landmarks.isEmpty {
            publication.landmarks = NavigationParser.parseGuide(package.child(named: "guide"), packagePath: packagePath)
        }
        return publication
    }

    static func packagePath(in container: some PublicationContainer) throws -> String {
        guard let data = try? container.data(at: "META-INF/container.xml") else { throw EPUBError.missingContainer }
        let root = try MarkupParser.parse(data)
        let rootfiles = root.descendants(named: "rootfile")
        let preferred = rootfiles.first { $0.attribute("media-type") == "application/oebps-package+xml" } ?? rootfiles.first
        guard let fullPath = preferred?.attribute("full-path"),
              let resolved = EPUBPath.resolve(fullPath, relativeTo: "")
        else { throw EPUBError.missingPackage }
        return resolved.path
    }

    // MARK: - Metadata

    /// EPUB 3 `meta` elements indexed by property, with `refines` support.
    struct MetaTable {
        struct Entry {
            let property: String
            let value: String
            let refines: String?
            let id: String?
            let scheme: String?
        }

        private(set) var entries: [Entry] = []
        /// EPUB 2 `<meta name content>` pairs.
        private(set) var legacy: [String: String] = [:]

        init(_ metadata: MarkupElement?) {
            for element in metadata?.children(named: "meta") ?? [] {
                if let property = element.attribute("property") {
                    let refines = element.attribute("refines").map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
                    entries.append(Entry(
                        property: property, value: element.normalizedText, refines: refines,
                        id: element.attribute("id"), scheme: element.attribute("scheme")))
                } else if let name = element.attribute("name"), let content = element.attribute("content") {
                    legacy[name] = content
                }
            }
        }

        func global(_ property: String) -> String? {
            entries.first { $0.property == property && $0.refines == nil }?.value
        }

        func refinement(_ property: String, of id: String?) -> String? {
            guard let id else { return nil }
            return entries.first { $0.property == property && $0.refines == id }?.value
        }

        func globals(_ property: String) -> [Entry] {
            entries.filter { $0.property == property && $0.refines == nil }
        }
    }

    private static func parseMetadata(
        _ element: MarkupElement?, package: MarkupElement, meta: MetaTable
    ) -> PublicationMetadata {
        var metadata = PublicationMetadata()
        guard let element else { return metadata }
        func dc(_ name: String) -> [MarkupElement] { element.children(named: name, namespace: XMLNamespace.dc) }

        let titles = dc("title")
        let mainTitle = titles.first { meta.refinement("title-type", of: $0.attribute("id")) == "main" } ?? titles.first
        metadata.title = mainTitle?.normalizedText ?? ""
        metadata.sortTitle = meta.refinement("file-as", of: mainTitle?.attribute("id"))

        let creators = dc("creator")
        func role(_ creator: MarkupElement) -> String? {
            meta.refinement("role", of: creator.attribute("id")) ?? creator.attribute("role", namespace: XMLNamespace.opf)
        }
        let authors = creators.filter { role($0) == nil || role($0) == "aut" }
        metadata.authors = (authors.isEmpty ? creators : authors).map(\.normalizedText).filter { !$0.isEmpty }
        if let first = authors.first ?? creators.first {
            metadata.sortAuthor = meta.refinement("file-as", of: first.attribute("id"))
                ?? first.attribute("file-as", namespace: XMLNamespace.opf)
        }

        let identifiers = dc("identifier")
        let uniqueID = package.attribute("unique-identifier")
        metadata.identifier = (identifiers.first { $0.attribute("id") == uniqueID } ?? identifiers.first)?.normalizedText
        metadata.language = dc("language").first?.normalizedText
        metadata.publisher = dc("publisher").first?.normalizedText
        metadata.summary = dc("description").first.map { strippingTags($0.textContent) }
        metadata.subjects = dc("subject").map(\.normalizedText).filter { !$0.isEmpty }
        metadata.published = dc("date").first?.normalizedText
        metadata.modified = meta.global("dcterms:modified")
        metadata.rights = dc("rights").first?.normalizedText
        metadata.accessibilitySummary = meta.global("schema:accessibilitySummary")
        metadata.mediaActiveClass = meta.global("media:active-class")

        if let series = meta.globals("belongs-to-collection").first(where: {
            let type = meta.refinement("collection-type", of: $0.id)
            return type == nil || type == "series"
        }) {
            metadata.seriesName = series.value
            metadata.seriesPosition = meta.refinement("group-position", of: series.id).flatMap(Double.init)
        } else if let calibreSeries = meta.legacy["calibre:series"] {
            metadata.seriesName = calibreSeries
            metadata.seriesPosition = meta.legacy["calibre:series_index"].flatMap(Double.init)
        }
        return metadata
    }

    static func strippingTags(_ text: String) -> String {
        let stripped = text
            .replacingOccurrences(of: #"<br\s*/?>|</(p|div|li|h[1-6]|blockquote)>"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let decoded = (try? MarkupParser.parse(Data("<t>\(stripped)</t>".utf8)).textContent) ?? stripped
        return decoded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Manifest and spine

    private static func parseManifest(_ element: MarkupElement?, packagePath: String) -> [ManifestItem] {
        (element?.children(named: "item") ?? []).compactMap { item in
            guard let id = item.attribute("id"), let href = item.attribute("href") else { return nil }
            let resolved = EPUBPath.resolve(href, relativeTo: packagePath)
            return ManifestItem(
                id: id,
                path: resolved?.path ?? href,
                mediaType: (item.attribute("media-type") ?? "").lowercased(),
                properties: item.tokens("properties"),
                fallback: item.attribute("fallback"),
                mediaOverlay: item.attribute("media-overlay"),
                remoteURL: resolved == nil ? URL(string: href) : nil)
        }
    }

    private static func layout(meta: MetaTable) -> Publication.Layout {
        let declared = meta.global("rendition:layout")
        if declared == "roll" { return .roll }
        if declared == "pre-paginated" {
            // Pre-3.4 content expressed rolls as pre-paginated + scrolled-continuous.
            return meta.global("rendition:flow") == "scrolled-continuous" ? .roll : .prePaginated
        }
        return .reflowable
    }

    private static func parseSpine(
        _ element: MarkupElement?, manifest: [String: ManifestItem], globalLayout: Publication.Layout
    ) -> [SpineItem] {
        (element?.children(named: "itemref") ?? []).compactMap { itemref in
            guard let idref = itemref.attribute("idref"),
                  let item = renderableItem(idref, in: manifest)
            else { return nil }
            let properties = itemref.tokens("properties")
            var layout = globalLayout
            // Roll layouts ignore spine overrides (EPUB 3.4 §6.3.2).
            if globalLayout != .roll {
                if properties.contains("rendition:layout-pre-paginated") { layout = .prePaginated }
                if properties.contains("rendition:layout-reflowable") { layout = .reflowable }
            }
            return SpineItem(
                item: item,
                linear: itemref.attribute("linear") != "no",
                properties: properties,
                layout: layout)
        }
    }

    /// Follows the manifest fallback chain to a document WebKit can render.
    private static func renderableItem(_ id: String, in manifest: [String: ManifestItem]) -> ManifestItem? {
        var visited: Set<String> = []
        var current = manifest[id]
        while let item = current, !visited.contains(item.id) {
            if item.isRenderable && item.remoteURL == nil { return item }
            visited.insert(item.id)
            current = item.fallback.flatMap { manifest[$0] }
        }
        return manifest[id].flatMap { $0.remoteURL == nil ? $0 : nil }
    }

    private static func coverPath(
        manifest: [ManifestItem], meta: MetaTable, manifestByID: [String: ManifestItem]
    ) -> String? {
        if let item = manifest.first(where: { $0.properties.contains("cover-image") }) { return item.path }
        if let reference = meta.legacy["cover"] {
            if let item = manifestByID[reference], item.isImage { return item.path }
            if let item = manifest.first(where: { $0.path.hasSuffix(reference) && $0.isImage }) { return item.path }
        }
        return manifest.first { $0.isImage && $0.id.localizedCaseInsensitiveContains("cover") }?.path
            ?? manifest.first { $0.isImage && $0.path.localizedCaseInsensitiveContains("cover") }?.path
    }

    // MARK: - Encryption

    /// Maps obfuscated font paths to their algorithm. Any other encryption is DRM.
    static func obfuscatedResources(in container: some PublicationContainer) throws -> [String: FontObfuscation] {
        guard container.contains("META-INF/encryption.xml") else { return [:] }
        let root = try MarkupParser.parse(container.data(at: "META-INF/encryption.xml"))
        var result: [String: FontObfuscation] = [:]
        for encrypted in root.descendants(named: "EncryptedData") {
            let algorithm = encrypted.firstDescendant(named: "EncryptionMethod")?.attribute("Algorithm") ?? ""
            guard let uri = encrypted.firstDescendant(named: "CipherReference")?.attribute("URI"),
                  let path = EPUBPath.resolve(uri, relativeTo: "")?.path
            else { continue }
            guard let obfuscation = FontObfuscation(rawValue: algorithm) else { throw EPUBError.drmProtected }
            result[path] = obfuscation
        }
        return result
    }
}
