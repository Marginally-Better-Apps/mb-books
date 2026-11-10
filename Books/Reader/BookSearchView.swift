import SwiftUI

/// Full-text search inside the open book, grouped by chapter.
struct BookSearchView: View {
    @Bindable var model: ReaderModel

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Group {
                        if model.isSearching && model.searchResults.isEmpty {
                            HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
                        } else if model.searchResults.isEmpty, model.searchQuery.count >= 2 {
                            ContentUnavailableView.search(text: model.searchQuery).listRowSeparator(.hidden)
                        }
                        ForEach(groups, id: \.spineIndex) { group in
                            Section {
                                ForEach(group.results) { result in
                                    let isLastShown = result.id == model.lastShownResult
                                    Button {
                                        model.show(result)
                                    } label: {
                                        snippet(result).font(.callout).lineLimit(3)
                                    }
                                    .buttonStyle(.plain)
                                    .id(result.id)
                                    .listRowBackground(isLastShown ? Color.accentColor.opacity(0.12) : Color.clear)
                                    .accessibilityAddTraits(isLastShown ? .isSelected : [])
                                }
                            } header: {
                                header(for: group)
                            }
                        }
                        if model.searchResults.count >= BookSearcher.maxResults {
                            Text("Showing the first \(BookSearcher.maxResults) results.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    // Rows sit on the sheet, which takes the reading theme's appearance, not on a band of their own.
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // Back from a result, the list picks up where the reader left it.
                .onAppear {
                    if let id = model.lastShownResult { proxy.scrollTo(id, anchor: .center) }
                }
            }
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

    /// The chapter's title; the first chapter's header also carries the result count, rather than a section of its own.
    private func header(for group: (spineIndex: Int, title: String?, results: [BookSearchResult])) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(group.title ?? String(localized: "Section \(group.spineIndex + 1)"))
            if group.results.first?.id == model.searchResults.first?.id {
                Spacer()
                Text("^[\(model.searchResults.count) Result](inflect: true)")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("bookSearch.count")
            }
        }
    }

    private func snippet(_ result: BookSearchResult) -> Text {
        let before = (result.continuesBefore ? "…" : "") + result.before
        let after = result.after + (result.continuesAfter ? "…" : "")
        return Text("\(before)\(Text(result.match).bold().foregroundStyle(.tint))\(after)")
    }
}
