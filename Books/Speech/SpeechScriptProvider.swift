import Foundation
import OSLog

/// Choices a reader made about what to read in one book, overriding the extractor.
nonisolated struct SpeechOverrides: Codable, Sendable, Equatable {
    /// Spine items read even though the extractor skipped them.
    var included: Set<Int> = []
    /// Spine items skipped even though the extractor would read them.
    var excluded: Set<Int> = []
}

/// Builds speech for a book a chapter at a time, so listening can start right away, or all at once
/// for preparing an audiobook. Page images are read with OCR, and the results are kept on disk.
actor SpeechScriptProvider {
    private static let logger = Logger(subsystem: "com.mbbooks.MBBooks", category: "Speech")
    private static let ocrVersion = 1

    nonisolated let publication: Publication
    nonisolated let container: DirectoryContainer
    /// `<book>/speech`, for OCR results and overrides.
    nonisolated let folder: URL
    private let extractor: SpeechExtractor
    private var chapters: [Int: SpeechChapter] = [:]
    private var recognized: [Int: [ScanReader.Line]] = [:]
    private(set) var overrides: SpeechOverrides

    init(publication: Publication, container: DirectoryContainer, folder: URL) {
        self.publication = publication
        self.container = container
        self.folder = folder
        extractor = SpeechExtractor(publication: publication, container: container)
        overrides = (try? Data(contentsOf: folder.appending(path: "overrides.json")))
            .flatMap { try? JSONDecoder().decode(SpeechOverrides.self, from: $0) } ?? SpeechOverrides()
    }

    var spineCount: Int { publication.spine.count }

    func chapter(_ spineIndex: Int) async -> SpeechChapter {
        if let cached = chapters[spineIndex] { return cached }
        guard publication.spine.indices.contains(spineIndex) else { return SpeechChapter(spineIndex: spineIndex) }
        let item = publication.spine[spineIndex]
        var chapter: SpeechChapter
        if item.item.isXHTML, let data = try? container.data(at: item.item.path) {
            chapter = extractor.chapter(spineIndex: spineIndex, item: item, data: data)
        } else {
            chapter = SpeechChapter(spineIndex: spineIndex, skipReason: item.linear ? .empty : .auxiliary)
        }
        if chapter.utterances.isEmpty, chapter.skipReason == .empty || chapter.skipReason == nil,
           let image = pageImage(for: item, data: try? container.data(at: item.item.path)) {
            chapter = await scannedChapter(spineIndex: spineIndex, image: image)
        }
        chapters[spineIndex] = chapter
        return chapter
    }

    func isReadable(_ chapter: SpeechChapter) -> Bool {
        if overrides.excluded.contains(chapter.spineIndex) { return false }
        if overrides.included.contains(chapter.spineIndex) { return !chapter.utterances.isEmpty }
        return !chapter.isSkipped && !chapter.utterances.isEmpty
    }

    /// The first chapter to read at or after (or before) `spineIndex`.
    func readableChapter(from spineIndex: Int, forward: Bool = true) async -> SpeechChapter? {
        var index = spineIndex
        while publication.spine.indices.contains(index) {
            let chapter = await chapter(index)
            if isReadable(chapter) { return chapter }
            index += forward ? 1 : -1
        }
        return nil
    }

    /// Every chapter, in order, reporting progress as it goes (OCR can take a while).
    func script(progress: @Sendable (Double) -> Void = { _ in }) async -> SpeechScript {
        var result: [SpeechChapter] = []
        for index in publication.spine.indices {
            guard !Task.isCancelled else { break }
            var chapter = await chapter(index)
            if !isReadable(chapter) {
                chapter.skipReason = chapter.skipReason ?? .auxiliary
            } else {
                chapter.skipReason = nil
            }
            result.append(chapter)
            progress(Double(index + 1) / Double(max(1, publication.spine.count)))
        }
        return SpeechScript(chapters: result)
    }

    func setIncluded(_ spineIndex: Int, _ included: Bool) {
        let chapter = chapters[spineIndex]
        let readsByDefault = chapter.map { !$0.isSkipped && !$0.utterances.isEmpty } ?? true
        overrides.included.remove(spineIndex)
        overrides.excluded.remove(spineIndex)
        if included, !readsByDefault { overrides.included.insert(spineIndex) }
        if !included, readsByDefault { overrides.excluded.insert(spineIndex) }
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(overrides).write(to: folder.appending(path: "overrides.json"), options: .atomic)
        } catch {
            Self.logger.error("Couldn't save speech overrides: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Page images

    /// The image a page shows, if it's an image or a fixed-layout page that only wraps one.
    private func pageImage(for item: SpineItem, data: Data?) -> URL? {
        if item.item.isImage, !item.item.isSVG { return container.url(for: item.item.path) }
        let isFixed = item.layout != .reflowable || publication.layout != .reflowable
        guard isFixed || item.item.isSVG, let data, let root = try? MarkupParser.parse(data) else { return nil }
        let images = root.descendants(named: "img").compactMap { $0.attribute("src") }
            + root.descendants(named: "image").compactMap {
                $0.attribute("href", namespace: "http://www.w3.org/1999/xlink") ?? $0.attribute("href")
            }
        guard let source = images.first, let target = EPUBPath.resolve(source, relativeTo: item.item.path),
              container.contains(target.path)
        else { return nil }
        return container.url(for: target.path)
    }

    private func scannedChapter(spineIndex: Int, image: URL) async -> SpeechChapter {
        var chapter = SpeechChapter(spineIndex: spineIndex, title: publication.chapterTitle(forSpineIndex: spineIndex))
        guard let lines = await lines(spineIndex: spineIndex, image: image) else {
            chapter.skipReason = .empty
            return chapter
        }
        // Running heads repeat from page to page; count margin lines on the pages around this one.
        var margins: [String: Int] = [:]
        for neighbor in (spineIndex - 3)...(spineIndex + 3) where neighbor != spineIndex {
            for line in recognized[neighbor] ?? loadRecognized(neighbor) ?? [] where ScanReader.isMargin(line) {
                let stripped = line.text.replacingOccurrences(of: #"^\d{1,4}\s+|\s+\d{1,4}$"#, with: "", options: .regularExpression)
                margins[ScanReader.marginKey(stripped), default: 0] += 1
            }
        }
        let context = ScanReader.Context(
            bookTitle: publication.metadata.title, authors: publication.metadata.authors,
            chapterTitle: chapter.title, marginText: margins.filter { !$0.key.isEmpty })
        let page = ScanReader.layout(lines, context: context)
        chapter.omissions = page.omissions
        for paragraph in page.paragraphs {
            let cleaned = SpeechText.clean(MappedText(paragraph, at: 0)).string
            for range in SpeechText.sentences(in: cleaned, language: publication.metadata.language) {
                let sentence = cleaned[range].trimmingCharacters(in: .whitespaces)
                guard sentence.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                chapter.utterances.append(SpeechUtterance(
                    spineIndex: spineIndex, text: sentence, start: nil, end: nil, kind: .scan,
                    language: publication.metadata.language, pauseAfter: 0))
            }
            if !chapter.utterances.isEmpty { chapter.utterances[chapter.utterances.count - 1].pauseAfter = 0.35 }
        }
        if chapter.utterances.isEmpty { chapter.skipReason = .empty }
        return chapter
    }

    private func lines(spineIndex: Int, image: URL) async -> [ScanReader.Line]? {
        if let cached = recognized[spineIndex] ?? loadRecognized(spineIndex) { return cached }
        do {
            let lines = try await ScanReader.recognize(imageAt: image, language: publication.metadata.language)
            recognized[spineIndex] = lines
            let url = recognizedURL(spineIndex)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(lines).write(to: url, options: .atomic)
            return lines
        } catch {
            Self.logger.error("OCR failed for spine item \(spineIndex): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func recognizedURL(_ spineIndex: Int) -> URL {
        folder.appending(path: "ocr-v\(Self.ocrVersion)/\(spineIndex).json")
    }

    private func loadRecognized(_ spineIndex: Int) -> [ScanReader.Line]? {
        guard let data = try? Data(contentsOf: recognizedURL(spineIndex)),
              let lines = try? JSONDecoder().decode([ScanReader.Line].self, from: data)
        else { return nil }
        recognized[spineIndex] = lines
        return lines
    }
}
