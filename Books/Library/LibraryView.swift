import SwiftData
import SwiftUI

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent, title, author, dateAdded

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .recent: "Recent"
        case .title: "Title"
        case .author: "Author"
        case .dateAdded: "Date Added"
        }
    }

    func sorted(_ books: [Book]) -> [Book] {
        switch self {
        case .recent:
            books.sorted { ($0.lastOpened ?? $0.dateAdded) > ($1.lastOpened ?? $1.dateAdded) }
        case .title:
            books.sorted { $0.sortTitle.localizedStandardCompare($1.sortTitle) == .orderedAscending }
        case .author:
            books.sorted {
                $0.sortAuthor == $1.sortAuthor
                    ? $0.sortTitle.localizedStandardCompare($1.sortTitle) == .orderedAscending
                    : $0.sortAuthor.localizedStandardCompare($1.sortAuthor) == .orderedAscending
            }
        case .dateAdded:
            books.sorted { $0.dateAdded > $1.dateAdded }
        }
    }
}

enum CollectionRoute: Hashable {
    case all, wantToRead, finished
    case custom(UUID)
}

struct LibraryView: View {
    @Query private var books: [Book]

    var body: some View {
        NavigationStack {
            BookBrowser(books: books, sourcePrefix: "library") {
                NavigationLink(value: "collections") {
                    HStack {
                        Label("Collections", systemImage: "rectangle.stack")
                            .font(.body.weight(.medium))
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .background(.background.secondary, in: .rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library.collections")
            }
            .navigationTitle("Library")
            .navigationDestination(for: String.self) { _ in CollectionsView() }
            .navigationDestination(for: CollectionRoute.self) { route in
                CollectionDetailView(route: route)
            }
        }
    }
}

/// A sortable grid or list of books with multi-select editing.
struct BookBrowser<Header: View>: View {
    let books: [Book]
    let sourcePrefix: String
    var collection: BookCollection?
    @ViewBuilder var header: Header

    @Environment(\.modelContext) private var context
    @Environment(LibraryStore.self) private var library
    @Environment(\.importBooks) private var importBooks
    @AppStorage("librarySort") private var sort = LibrarySort.recent
    @AppStorage("libraryUsesList") private var usesList = false
    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var isConfirmingRemoval = false
    @State private var isAddingToCollection = false
    @State private var finishes = 0

    var body: some View {
        let sorted = sort.sorted(books)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header.padding(.horizontal, 20)
                if books.isEmpty {
                    if collection == nil && sourcePrefix == "library" {
                        EmptyLibraryView().padding(.top, 40)
                    } else {
                        ContentUnavailableView("No Books", systemImage: "books.vertical",
                                               description: Text("Books you add to this collection appear here."))
                    }
                } else if usesList {
                    LazyVStack(spacing: 0) {
                        ForEach(sorted) { book in
                            row(for: book)
                            // Aligned with the titles: the row's padding, cover, and spacing.
                            Divider().padding(.leading, 88)
                        }
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 24, alignment: .bottom)],
                              spacing: 28) {
                        ForEach(sorted) { book in cell(for: book) }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.vertical)
        }
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .confirm, action: endSelection)
                        .accessibilityIdentifier("library.selection.done")
                }
                // Every bulk action ends the selection.
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Add to Collection", systemImage: "rectangle.stack.badge.plus") { isAddingToCollection = true }
                        .disabled(selection.isEmpty)
                    Spacer()
                    Button("Mark as Finished", systemImage: "checkmark.circle") {
                        selectedBooks.forEach { $0.markFinished(true) }
                        finishes += 1
                        endSelection()
                    }
                    .disabled(selection.isEmpty)
                    Spacer()
                    if let collection {
                        Button("Remove from Collection", systemImage: "minus.circle") {
                            collection.books.removeAll { selection.contains($0.id) }
                            endSelection()
                        }
                        .disabled(selection.isEmpty)
                    } else {
                        Button("Remove", systemImage: "trash", role: .destructive) { isConfirmingRemoval = true }
                            .disabled(selection.isEmpty)
                    }
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Books", systemImage: "plus") { importBooks() }
                        .accessibilityIdentifier("library.import")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("More", systemImage: "ellipsis") {
                        Button("Select", systemImage: "checkmark.circle") { isSelecting = true }
                            .disabled(books.isEmpty)
                        Picker("View", selection: $usesList) {
                            Label("Grid", systemImage: "square.grid.2x2").tag(false)
                            Label("List", systemImage: "list.bullet").tag(true)
                        }
                        Picker(selection: $sort) {
                            ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                        } label: {
                            Label("Sort By", systemImage: "arrow.up.arrow.down")
                        }
                        .pickerStyle(.menu)
                    }
                    .accessibilityIdentifier("library.more")
                }
                if sourcePrefix == "library" {
                    LibraryToolbar()
                }
            }
        }
        .toolbar(isSelecting ? .hidden : .automatic, for: .tabBar)
        .confirmationDialog(String(inflecting: "Remove ^[\(selection.count) Book](inflect: true)?"),
                            isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
            Button("Remove from Library", role: .destructive) {
                library.delete(selectedBooks, from: context)
                endSelection()
            }
        } message: {
            Text(selection.count == 1
                 ? "The book, its highlights, notes, and bookmarks will be deleted from this device."
                 : "The books, their highlights, notes, and bookmarks will be deleted from this device.")
        }
        .sheet(isPresented: $isAddingToCollection, onDismiss: endSelection) {
            CollectionPicker(books: selectedBooks)
        }
        .sensoryFeedback(.success, trigger: finishes)
    }

    private var selectedBooks: [Book] { books.filter { selection.contains($0.id) } }

    private func endSelection() {
        isSelecting = false
        selection.removeAll()
    }

    private func cell(for book: Book) -> some View {
        let source = "\(sourcePrefix)-\(book.id)"
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                tap(book, source: source)
            } label: {
                Color.clear
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .overlay(alignment: .bottom) {
                        BookCover(book: book).zoomSource(source)
                    }
                    .overlay(alignment: .bottomTrailing) { selectionMark(for: book) }
            }
            .buttonStyle(.plain)
            .bookInteractions(book)
            .bookAccessibility(book)
            .accessibilityAddTraits(isSelecting && selection.contains(book.id) ? .isSelected : [])
            .accessibilityIdentifier("book.\(book.title)")
            HStack {
                BookProgressBadge(book: book)
                Spacer()
                BookMenuButton(book: book)
            }
        }
    }

    private func row(for book: Book) -> some View {
        let source = "\(sourcePrefix)-list-\(book.id)"
        return HStack(spacing: 16) {
            Button {
                tap(book, source: source)
            } label: {
                BookRow(book: book, source: source) { selectionMark(for: book) }
            }
            .buttonStyle(.plain)
            .bookInteractions(book)
            .bookAccessibility(book)
            .accessibilityAddTraits(isSelecting && selection.contains(book.id) ? .isSelected : [])
            .accessibilityIdentifier("book.\(book.title)")
            if !isSelecting { BookMenuButton(book: book) }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func selectionMark(for book: Book) -> some View {
        if isSelecting {
            Image(systemName: selection.contains(book.id) ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, selection.contains(book.id) ? Color.accentColor : .black.opacity(0.3))
                .padding(6)
        }
    }

    @Environment(\.openBook) private var openBook

    private func tap(_ book: Book, source: String) {
        if isSelecting {
            if selection.contains(book.id) { selection.remove(book.id) } else { selection.insert(book.id) }
        } else {
            openBook(book, source)
        }
    }
}

// MARK: - Collections

struct CollectionsView: View {
    @Environment(\.modelContext) private var context
    @Query private var books: [Book]
    @Query(sort: \BookCollection.created) private var collections: [BookCollection]

    var body: some View {
        List {
            Section {
                link(.wantToRead, "Want to Read", "bookmark", books.filter(\.wantToRead).count)
                    .accessibilityIdentifier("collections.wantToRead")
                link(.finished, "Finished", "checkmark.circle", books.filter(\.isFinished).count)
                    .accessibilityIdentifier("collections.finished")
                link(.all, "All Books", "book", books.count)
                    .accessibilityIdentifier("collections.all")
            }
            Section("My Collections") {
                ForEach(collections) { collection in
                    NavigationLink(value: CollectionRoute.custom(collection.id)) {
                        LabeledContent {
                            Text("\(collection.books.count)")
                        } label: {
                            Label(collection.name, systemImage: "rectangle.stack")
                        }
                    }
                }
                .onDelete { offsets in
                    offsets.map { collections[$0] }.forEach(context.delete)
                }
                NewCollectionField()
            }
        }
        .navigationTitle("Collections")
        .toolbar {
            // Only custom collections can be deleted.
            if !collections.isEmpty { EditButton() }
        }
    }

    private func link(_ route: CollectionRoute, _ title: LocalizedStringKey, _ image: String, _ count: Int) -> some View {
        NavigationLink(value: route) {
            LabeledContent {
                Text("\(count)")
            } label: {
                Label(title, systemImage: image)
            }
        }
    }
}

struct CollectionDetailView: View {
    let route: CollectionRoute

    @Query private var books: [Book]
    @Query private var collections: [BookCollection]

    var body: some View {
        let collection: BookCollection? = if case .custom(let id) = route { collections.first { $0.id == id } } else { nil }
        let filtered: [Book] = switch route {
        case .all: books
        case .wantToRead: books.filter(\.wantToRead)
        case .finished: books.filter(\.isFinished)
        case .custom: collection?.books ?? []
        }
        BookBrowser(books: filtered, sourcePrefix: "collection-\(title)", collection: collection) { EmptyView() }
            .navigationTitle(collection?.name ?? title)
    }

    private var title: String {
        switch route {
        case .all: String(localized: "All Books")
        case .wantToRead: String(localized: "Want to Read")
        case .finished: String(localized: "Finished")
        case .custom: ""
        }
    }
}

/// The inline field that names a new collection, the same in Collections and the collection picker.
struct NewCollectionField: View {
    /// Called with the collection just created, so the picker can add its books.
    var onCreate: (BookCollection) -> Void = { _ in }

    @Environment(\.modelContext) private var context
    @State private var name = ""

    var body: some View {
        HStack {
            Label {
                TextField("New Collection", text: $name)
                    .submitLabel(.done)
                    .onSubmit(create)
                    .accessibilityIdentifier("collections.newName")
            } icon: {
                Image(systemName: "rectangle.stack.badge.plus").foregroundStyle(.tint)
            }
            Button("Create", action: create)
                .buttonStyle(.borderless)
                .disabled(trimmedName.isEmpty)
                .accessibilityIdentifier("collections.create")
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private func create() {
        guard !trimmedName.isEmpty else { return }
        let collection = BookCollection(name: trimmedName)
        context.insert(collection)
        onCreate(collection)
        name = ""
    }
}

/// Adds books to user collections. Changes apply as they're made, so the sheet only closes.
struct CollectionPicker: View {
    let books: [Book]

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BookCollection.created) private var collections: [BookCollection]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NewCollectionField { collection in
                        collection.books.append(contentsOf: books)
                    }
                }
                Section {
                    ForEach(collections) { collection in
                        Button {
                            toggle(collection)
                        } label: {
                            HStack {
                                Label(collection.name, systemImage: "rectangle.stack")
                                Spacer()
                                if contains(collection) {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(contains(collection) ? .isSelected : [])
                    }
                }
            }
            .navigationTitle("Add to Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier("collectionPicker.close")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func contains(_ collection: BookCollection) -> Bool {
        books.allSatisfy { book in collection.books.contains { $0.id == book.id } }
    }

    private func toggle(_ collection: BookCollection) {
        if contains(collection) {
            collection.books.removeAll { book in books.contains { $0.id == book.id } }
        } else {
            for book in books where !collection.books.contains(where: { $0.id == book.id }) {
                collection.books.append(book)
            }
        }
    }
}

