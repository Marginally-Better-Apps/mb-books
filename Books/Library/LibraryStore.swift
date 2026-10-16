import Foundation
import Observation
import SwiftData

/// Coordinates imports and removals between files on disk and the SwiftData library.
@Observable
final class LibraryStore {
    let storage: BookStorage
    private(set) var activeImports = 0
    var importError: ImportFailure?

    struct ImportFailure: Identifiable {
        let id = UUID()
        let fileName: String
        let message: String
    }

    init(storage: BookStorage = .shared) {
        self.storage = storage
    }

    var isImporting: Bool { activeImports > 0 }

    /// Imports files off the main actor and inserts them into the library.
    /// Returns the imported (or already present) books in order.
    @discardableResult
    func importBooks(from urls: [URL], into context: ModelContext) async -> [Book] {
        var imported: [Book] = []
        for url in urls {
            activeImports += 1
            defer { activeImports -= 1 }
            let importer = BookImporter(storage: storage)
            let scoped = url.startAccessingSecurityScopedResource()
            let result = await Task.detached(priority: .userInitiated) {
                Result(catching: { try importer.importBook(from: url) })
            }.value
            if scoped { url.stopAccessingSecurityScopedResource() }

            switch result {
            case .success(let book):
                imported.append(insert(book, into: context))
            case .failure(let error):
                importError = ImportFailure(fileName: url.lastPathComponent, message: error.localizedDescription)
            }
        }
        try? context.save()
        return imported
    }

    private func insert(_ imported: ImportedBook, into context: ModelContext) -> Book {
        if let duplicate = existingBook(matching: imported.metadata, in: context) {
            storage.removeBook(imported.id)
            return duplicate
        }
        let book = Book(
            id: imported.id, metadata: imported.metadata, epubVersion: imported.epubVersion,
            layout: imported.layout, fileSize: imported.fileSize, hasOriginalFile: imported.hasOriginalFile)
        context.insert(book)
        return book
    }

    /// Books with the same identifier and title are treated as the same book, as Apple Books does.
    private func existingBook(matching metadata: PublicationMetadata, in context: ModelContext) -> Book? {
        guard let identifier = metadata.identifier, !identifier.isEmpty else { return nil }
        let title = metadata.title
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.identifier == identifier && $0.title == title })
        return try? context.fetch(descriptor).first
    }

    func delete(_ books: [Book], from context: ModelContext) {
        for book in books {
            storage.removeBook(book.id)
            context.delete(book)
        }
        try? context.save()
    }

    func coverURL(for book: Book) -> URL? {
        let url = storage.coverFile(for: book.id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func shareURL(for book: Book) -> URL? {
        guard book.hasOriginalFile else { return nil }
        let original = storage.originalFile(for: book.id)
        // Share under the book's title rather than "book.epub".
        let safeTitle = book.title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined()
        let link = FileManager.default.temporaryDirectory.appending(path: "\(safeTitle).epub")
        try? FileManager.default.removeItem(at: link)
        do {
            try FileManager.default.linkItem(at: original, to: link)
            return link
        } catch {
            return original
        }
    }
}
