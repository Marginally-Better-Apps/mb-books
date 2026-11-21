import SwiftData
import SwiftUI

/// Searches the library by title, author, series, subject, and publisher.
struct SearchView: View {
    @Query(sort: \Book.sortTitle) private var books: [Book]
    @State private var query = ""
    @Environment(\.openBook) private var openBook

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    if books.isEmpty {
                        EmptyLibraryView().listRowSeparator(.hidden)
                    } else {
                        Section("Authors") {
                            ForEach(authors, id: \.self) { author in
                                Button(author) { query = author }
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query).listRowSeparator(.hidden)
                } else {
                    Section("Books") {
                        ForEach(results) { book in
                            let source = "search-\(book.id)"
                            HStack(spacing: 16) {
                                Button {
                                    openBook(book, source)
                                } label: {
                                    BookRow(book: book, source: source)
                                }
                                .buttonStyle(.plain)
                                .bookInteractions(book)
                                .bookAccessibility(book)
                                .accessibilityIdentifier("search.\(book.title)")
                                BookMenuButton(book: book)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Your Library")
        }
    }

    private var authors: [String] {
        Array(Set(books.map(\.author))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var results: [Book] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return books.filter { book in
            let haystack = ([book.title, book.author, book.seriesName ?? "", book.publisher ?? ""] + book.subjects)
                .joined(separator: " ")
            return terms.allSatisfy { haystack.localizedStandardContains($0) }
        }
    }
}
