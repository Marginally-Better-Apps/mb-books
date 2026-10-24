import SwiftUI

/// Book details, like the Apple Books product page for a book you own.
struct BookDetailView: View {
    let book: Book

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openBook) private var openBook

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    BookCover(book: book, cornerRadius: 6)
                        .frame(height: 280)
                        .padding(.top)
                    VStack(spacing: 6) {
                        Text(book.title)
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                        Text(book.author)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        if let series = book.seriesName {
                            Text(seriesLabel(series))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal)

                    HStack(spacing: 12) {
                        Button {
                            dismiss()
                            openBook(book, "details-\(book.id)")
                        } label: {
                            Text(book.isNew ? "Read" : book.isFinished ? "Read Again" : "Continue")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.glassProminent)
                        Button {
                            book.wantToRead.toggle()
                        } label: {
                            Image(systemName: book.wantToRead ? "checkmark" : "plus")
                                .font(.headline)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel(book.wantToRead ? "Remove from Want to Read" : "Want to Read")
                    }
                    .padding(.horizontal)

                    if let summary = book.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                    }

                    VStack(spacing: 0) {
                        info("Genre", book.subjects.first)
                        info("Released", book.published.map(Self.formatDate))
                        info("Language", book.language.flatMap { Locale.current.localizedString(forIdentifier: $0) })
                        info("Publisher", book.publisher)
                        info("Size", ByteCountFormatStyle().format(book.fileSize))
                        info("Format", String(localized: "EPUB \(book.epubVersion)") + (book.layout == .reflowable ? "" : " · " + layoutName))
                        info("Added", book.dateAdded.formatted(date: .abbreviated, time: .omitted))
                        info("Progress", book.isFinished ? String(localized: "Finished") : book.percentRead.formatted(.percent))
                    }
                    .background(.background.secondary, in: .rect(cornerRadius: 16))
                    .padding(.horizontal)
                }
                .padding(.bottom, 30)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }

    private var layoutName: String {
        book.layout == .roll ? String(localized: "Roll") : String(localized: "Fixed Layout")
    }

    private func seriesLabel(_ series: String) -> String {
        guard let position = book.seriesPosition else { return series }
        return String(localized: "\(series), Book \(position.formatted())")
    }

    @ViewBuilder
    private func info(_ label: LocalizedStringKey, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).multilineTextAlignment(.trailing)
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider().padding(.leading, 16)
        }
    }

    /// Formats W3C dates ("2023", "2023-05", "2023-05-01T…") for display.
    static func formatDate(_ value: String) -> String {
        let trimmed = String(value.prefix(10))
        let formats = [("yyyy-MM-dd", Date.FormatStyle(date: .long, time: .omitted)),
                       ("yyyy-MM", Date.FormatStyle().month(.wide).year()),
                       ("yyyy", Date.FormatStyle().year())]
        for (pattern, style) in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = pattern
            if let date = formatter.date(from: trimmed) { return date.formatted(style) }
        }
        return value
    }
}
