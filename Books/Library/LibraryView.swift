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
                        Label("Collections", systemImage: "square.stack")
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
                            Divider().padding(.leading, 96)
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
                    Button("Done", systemImage: "checkmark") {
                        isSelecting = false
                        selection.removeAll()
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Add to Collection", systemImage: "text.badge.plus") { isAddingToCollection = true }
                        .disabled(selection.isEmpty)
                    Spacer()
                    Button("Mark as Finished", systemImage: "checkmark.circle") {
                        selectedBooks.forEach { $0.markFinished(true) }
                        isSelecting = false
                        selection.removeAll()
                    }
                    .disabled(selection.isEmpty)
                    Spacer()
                    if let collection {
                        Button("Remove from Collection", systemImage: "minus.circle") {
                            collection.books.removeAll { selection.contains($0.id) }
                            selection.removeAll()
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
                        Picker("Sort By", selection: $sort) {
                            ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
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
        .confirmationDialog("Remove \(selection.count) Books?", isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
            Button("Remove from Library", role: .destructive) {
                library.delete(selectedBooks, from: context)
                selection.removeAll()
                isSelecting = false
            }
        } message: {
            Text("The books, their highlights, notes, and bookmarks will be deleted from this device.")
        }
        .sheet(isPresented: $isAddingToCollection) {
            CollectionPicker(books: selectedBooks)
        }
    }

    private var selectedBooks: [Book] { books.filter { selection.contains($0.id) } }

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
            .accessibilityLabel(book.title)
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
                HStack(spacing: 16) {
                    BookCover(book: book)
                        .frame(width: 60, height: 90, alignment: .center)
                        .zoomSource(source)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(book.title).font(.headline).lineLimit(2)
                        Text(book.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        BookProgressBadge(book: book).padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                    selectionMark(for: book)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .bookInteractions(book)
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

/// The "…" button under a cover.
private struct BookMenuButton: View {
    let book: Book

    @Environment(\.modelContext) private var context
    @Environment(LibraryStore.self) private var library
    @State private var isConfirmingRemoval = false
    @State private var isShowingDetails = false
    @State private var isAddingToCollection = false

    var body: some View {
        Menu {
            BookActions(book: book, isConfirmingRemoval: $isConfirmingRemoval,
                        isShowingDetails: $isShowingDetails, isAddingToCollection: $isAddingToCollection)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 36)
                .contentShape(.rect)
        }
        // Menus take the accent color; this is a quiet secondary control, as in Apple Books.
        .tint(.secondary)
        .padding(.trailing, -10)
        .accessibilityLabel("More for \(book.title)")
        .confirmationDialog("Remove “\(book.title)”?", isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
            Button("Remove from Library", role: .destructive) { library.delete([book], from: context) }
        }
        .sheet(isPresented: $isShowingDetails) { BookDetailView(book: book) }
        .sheet(isPresented: $isAddingToCollection) { CollectionPicker(books: [book]) }
    }
}

// MARK: - Collections

struct CollectionsView: View {
    @Environment(\.modelContext) private var context
    @Query private var books: [Book]
    @Query(sort: \BookCollection.created) private var collections: [BookCollection]
    @State private var isNaming = false
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                link(.wantToRead, "Want to Read", "bookmark", books.filter(\.wantToRead).count)
                link(.finished, "Finished", "checkmark.circle", books.filter(\.isFinished).count)
                link(.all, "Books", "book", books.count)
            }
            Section("My Collections") {
                ForEach(collections) { collection in
                    NavigationLink(value: CollectionRoute.custom(collection.id)) {
                        LabeledContent {
                            Text("\(collection.books.count)")
                        } label: {
                            Label(collection.name, systemImage: "list.bullet")
                        }
                    }
                }
                .onDelete { offsets in
                    offsets.map { collections[$0] }.forEach(context.delete)
                }
                Button("New Collection…", systemImage: "plus") { isNaming = true }
            }
        }
        .navigationTitle("Collections")
        .toolbar { EditButton() }
        .alert("New Collection", isPresented: $isNaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { context.insert(BookCollection(name: name)) }
                newName = ""
            }
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
        case .all: String(localized: "Books")
        case .wantToRead: String(localized: "Want to Read")
        case .finished: String(localized: "Finished")
        case .custom: ""
        }
    }
}

/// Adds books to user collections.
struct CollectionPicker: View {
    let books: [Book]

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BookCollection.created) private var collections: [BookCollection]
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New Collection", text: $newName)
                            .onSubmit(create)
                        Button("Create", action: create)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section {
                    ForEach(collections) { collection in
                        Button {
                            toggle(collection)
                        } label: {
                            HStack {
                                Text(collection.name)
                                Spacer()
                                if contains(collection) {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Add to Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
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

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let collection = BookCollection(name: name)
        context.insert(collection)
        collection.books.append(contentsOf: books)
        newName = ""
    }
}
