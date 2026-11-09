import Foundation
import Observation
import OSLog
import SwiftData

/// Coordinates imports and removals between files on disk and the SwiftData library.
@Observable
final class LibraryStore {
    private static let logger = Logger(subsystem: "com.mbbooks.MBBooks", category: "Import")

    let storage: BookStorage
    /// Files queued and finished across every import in progress, for "Adding 3 of 10…".
    private(set) var importTotal = 0
    private(set) var importCompleted = 0
    /// Files that couldn't be added, shown together in one alert.
    var importFailures: [ImportFailure] = []
    /// A brief confirmation after an import: books added, or already in the library.
    var importNotice: ImportNotice?

    struct ImportFailure: Identifiable {
        let id = UUID()
        let fileName: String
        let message: String
    }

    struct ImportNotice: Identifiable, Equatable {
        let id = UUID()
        let title: String
        var detail: String?
    }

    init(storage: BookStorage = .shared) {
        self.storage = storage
    }

    var isImporting: Bool { importCompleted < importTotal }

    /// Imports files off the main actor and inserts them into the library.
    /// Returns the imported (or already present) books in order.
    @discardableResult
    func importBooks(from urls: [URL], into context: ModelContext) async -> [Book] {
        var imported: [Book] = []
        var added = 0
        var duplicates = 0
        importTotal += urls.count
        for url in urls {
            defer { importCompleted += 1 }
            let importer = BookImporter(storage: storage)
            let scoped = url.startAccessingSecurityScopedResource()
            let result = await Task.detached(priority: .userInitiated) {
                Result(catching: { try importer.importBook(from: url) })
            }.value
            if scoped { url.stopAccessingSecurityScopedResource() }

            switch result {
            case .success(let book):
                let (book, isDuplicate) = insert(book, into: context)
                imported.append(book)
                if isDuplicate { duplicates += 1 } else { added += 1 }
            case .failure(let error):
                reportFailure(error, fileName: url.lastPathComponent)
            }
        }
        // Overlapping imports share one count until the last of them finishes.
        if importCompleted >= importTotal {
            importTotal = 0
            importCompleted = 0
        }
        try? context.save()
        if let notice = Self.notice(fileCount: urls.count, added: added, duplicates: duplicates) {
            importNotice = notice
        }
        return imported
    }

    /// Queues a failure for the import alert. The technical detail goes to the log, not the reader.
    func reportFailure(_ error: any Error, fileName: String) {
        Self.logger.error("Couldn't import \(fileName, privacy: .public): \(String(describing: error), privacy: .public)")
        importFailures.append(ImportFailure(fileName: fileName, message: Self.reason(for: error)))
    }

    /// A short, plain-language reason a file couldn't be added.
    static func reason(for error: any Error) -> String {
        switch error {
        case is EPUBError, is ZipError: error.localizedDescription
        case is MarkupError: String(localized: "The book is damaged or incomplete.")
        default: String(localized: "The file couldn’t be read.")
        }
    }

    /// The import alert's title and message, naming each file when several failed.
    static func failureSummary(_ failures: [ImportFailure]) -> (title: String, message: String) {
        guard failures.count > 1 else {
            let failure = failures.first
            return (String(localized: "Couldn’t Add “\(failure?.fileName ?? "")”"), failure?.message ?? "")
        }
        let title = String(inflecting: "Couldn’t Add ^[\(failures.count) Book](inflect: true)")
        let message = failures.map { "\($0.fileName): \($0.message)" }.joined(separator: "\n\n")
        return (title, message)
    }

    /// Confirms multi-book imports and explains files that were already in the library.
    /// A single new book needs no notice: it appears in the library, or opens straight away.
    static func notice(fileCount: Int, added: Int, duplicates: Int) -> ImportNotice? {
        let existing = String(inflecting: "^[\(duplicates) Book](inflect: true) Already in Your Library")
        if added == 0 {
            guard duplicates > 0 else { return nil }
            return ImportNotice(title: duplicates == 1 ? String(localized: "Already in Your Library") : existing)
        }
        guard fileCount > 1 else { return nil }
        return ImportNotice(title: String(inflecting: "Added ^[\(added) Book](inflect: true)"),
                            detail: duplicates > 0 ? existing : nil)
    }

    private func insert(_ imported: ImportedBook, into context: ModelContext) -> (book: Book, isDuplicate: Bool) {
        if let duplicate = existingBook(matching: imported.metadata, in: context) {
            storage.removeBook(imported.id)
            return (duplicate, true)
        }
        let book = Book(
            id: imported.id, metadata: imported.metadata, epubVersion: imported.epubVersion,
            layout: imported.layout, fileSize: imported.fileSize, hasOriginalFile: imported.hasOriginalFile)
        context.insert(book)
        return (book, false)
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

extension String {
    /// A localized string with automatic grammar agreement applied, for places that take plain strings
    /// such as alert titles: `String(inflecting: "Remove ^[\(count) Book](inflect: true)?")`.
    init(inflecting key: String.LocalizationValue) {
        self = String(AttributedString(localized: key).characters)
    }
}
