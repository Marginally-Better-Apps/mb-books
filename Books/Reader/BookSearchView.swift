import SwiftUI

/// Full-text search inside the open book, grouped by chapter.
struct BookSearchView: View {
    @Bindable var model: ReaderModel

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List {
                if model.isSearching && model.searchResults.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
                } else if model.searchResults.isEmpty, model.searchQuery.count >= 2 {
                    ContentUnavailableView.search(text: model.searchQuery).listRowSeparator(.hidden)
                }
                if !model.searchResults.isEmpty {
                    Section {
                    } header: {
                        Text("^[\(model.searchResults.count) Result](inflect: true)")
                            .accessibilityIdentifier("bookSearch.count")
                    }
                }
                ForEach(groups, id: \.spineIndex) { group in
                    Section {
                        ForEach(group.results) { result in
                            Button {
                                model.show(result)
                            } label: {
                                snippet(result).font(.callout).lineLimit(3)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text(group.title ?? String(localized: "Section \(group.spineIndex + 1)"))
                    }
                }
                if model.searchResults.count >= BookSearcher.maxResults {
                    Text("Showing the first \(BookSearcher.maxResults) results.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .searchable(text: $model.searchQuery, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Book")
            .searchFocused($focused)
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .navigationTitle("Search Book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier("bookSearch.close")
                }
            }
            .task(id: model.searchQuery) {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await model.performSearch()
            }
            .onAppear { focused = model.searchQuery.isEmpty }
        }
        .presentationDetents([.large])
    }

    private var groups: [(spineIndex: Int, title: String?, results: [BookSearchResult])] {
        var output: [(Int, String?, [BookSearchResult])] = []
        for result in model.searchResults {
            if output.last?.0 == result.spineIndex {
                output[output.count - 1].2.append(result)
            } else {
                output.append((result.spineIndex, result.chapterTitle, [result]))
            }
        }
        return output
    }

    private func snippet(_ result: BookSearchResult) -> Text {
        Text("…\(result.before)\(Text(result.match).bold().foregroundStyle(.tint))\(result.after)…")
    }
}
