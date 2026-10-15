import Foundation
import ImageIO
import UniformTypeIdentifiers

/// On-disk layout of the library. Each book lives in its own folder:
///
///     <root>/<book id>/book.epub   original file, kept for sharing
///     <root>/<book id>/content/    extracted OCF container that the reader loads
///     <root>/<book id>/cover.jpg   downsampled cover
nonisolated struct BookStorage: Sendable {
    let root: URL

    static let shared = BookStorage(
        root: URL.applicationSupportDirectory.appending(path: "Library", directoryHint: .isDirectory))

    func folder(for id: UUID) -> URL { root.appending(path: id.uuidString, directoryHint: .isDirectory) }
    func contentDirectory(for id: UUID) -> URL { folder(for: id).appending(path: "content", directoryHint: .isDirectory) }
    func originalFile(for id: UUID) -> URL { folder(for: id).appending(path: "book.epub") }
    func coverFile(for id: UUID) -> URL { folder(for: id).appending(path: "cover.jpg") }

    func container(for id: UUID) -> DirectoryContainer { DirectoryContainer(root: contentDirectory(for: id)) }

    func removeBook(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(for: id))
    }
}

/// The result of importing a book, ready to become a `Book` model on the main actor.
nonisolated struct ImportedBook: Sendable {
    let id: UUID
    let metadata: PublicationMetadata
    let epubVersion: String
    let layout: Publication.Layout
    let fileSize: Int64
    let hasOriginalFile: Bool
}

nonisolated struct BookImporter: Sendable {
    let storage: BookStorage

    static let maxCoverDimension: CGFloat = 1000

    /// Copies, validates, and extracts an `.epub` file or an unzipped EPUB folder.
    func importBook(from source: URL) throws -> ImportedBook {
        let id = UUID()
        let folder = storage.folder(for: id)
        let content = storage.contentDirectory(for: id)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let publication: Publication
            let fileSize: Int64
            if isDirectory {
                try fileManager.copyItem(at: source, to: content)
                publication = try EPUBParser.parse(DirectoryContainer(root: content))
                fileSize = Self.directorySize(content)
            } else {
                let original = storage.originalFile(for: id)
                try fileManager.copyItem(at: source, to: original)
                let archive = try ZipArchive(url: original)
                // Parse before extracting so invalid or DRM-protected files fail fast.
                publication = try EPUBParser.parse(archive)
                try archive.extractAll(to: content)
                fileSize = Int64((try? original.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
            try deobfuscateFonts(publication, in: content)
            normalizeEntities(publication, in: content)
            if let coverPath = publication.coverPath {
                writeCover(from: DirectoryContainer(root: content).url(for: coverPath), to: storage.coverFile(for: id))
            }
            return ImportedBook(
                id: id, metadata: publication.metadata, epubVersion: publication.version,
                layout: publication.layout, fileSize: fileSize, hasOriginalFile: !isDirectory)
        } catch {
            storage.removeBook(id)
            throw error
        }
    }

    private func deobfuscateFonts(_ publication: Publication, in content: URL) throws {
        guard !publication.obfuscatedResources.isEmpty else { return }
        let container = DirectoryContainer(root: content)
        let identifier = publication.metadata.identifier ?? ""
        for (path, algorithm) in publication.obfuscatedResources where container.contains(path) {
            let url = container.url(for: path)
            let data = try Data(contentsOf: url)
            try FontDeobfuscator.deobfuscate(data, algorithm: algorithm, identifier: identifier).write(to: url)
        }
    }

    /// Rewrites HTML named entities (`&nbsp;`) as numeric references. They are common in real-world
    /// books but not defined in XHTML, so WebKit's XML parser would otherwise reject the chapter.
    private func normalizeEntities(_ publication: Publication, in content: URL) {
        let container = DirectoryContainer(root: content)
        for item in publication.manifest where item.mediaType == "application/xhtml+xml" && item.remoteURL == nil {
            let url = container.url(for: item.path)
            guard let data = try? Data(contentsOf: url) else { continue }
            let normalized = HTMLEntities.numericized(data)
            if normalized != data { try? normalized.write(to: url, options: .atomic) }
        }
    }

    /// Downsamples the cover with ImageIO so large scans never decode at full size.
    private func writeCover(from source: URL, to destination: URL) {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else { return }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maxCoverDimension,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary),
              let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(output)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let file = enumerator?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}
