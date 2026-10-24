import SwiftData
import SwiftUI
import UniformTypeIdentifiers

enum AppTab: Hashable {
    case home, library, search
}

/// A request to open a book, carrying the zoom transition's source.
struct ReadingSession: Identifiable {
    let book: Book
    let sourceID: String
    var id: UUID { book.id }
}

extension EnvironmentValues {
    /// Opens a book in the reader, zooming from the view tagged with `sourceID`.
    @Entry var openBook: (Book, String) -> Void = { _, _ in }
    @Entry var importBooks: () -> Void = {}
    @Entry var showSettings: () -> Void = {}
    @Entry var readerTransition: Namespace.ID?
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(LibraryStore.self) private var library
    @State private var tab = AppTab.home
    @State private var session: ReadingSession?
    @State private var isImporting = false
    @State private var isShowingSettings = false
    @Namespace private var transition

    static let importTypes: [UTType] = [.epub] + [UTType("org.idpf.epub-folder")].compactMap { $0 }

    var body: some View {
        @Bindable var library = library
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house.fill", value: .home) {
                HomeView()
            }
            .accessibilityIdentifier("tab.home")
            Tab("Library", systemImage: "books.vertical.fill", value: .library) {
                LibraryView()
            }
            .accessibilityIdentifier("tab.library")
            Tab(value: .search, role: .search) {
                SearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .environment(\.openBook) { book, sourceID in session = ReadingSession(book: book, sourceID: sourceID) }
        .environment(\.importBooks) { isImporting = true }
        .environment(\.showSettings) { isShowingSettings = true }
        .environment(\.readerTransition, transition)
        .fullScreenCover(item: $session) { session in
            ReaderView(book: session.book)
                .navigationTransition(.zoom(sourceID: session.sourceID, in: transition))
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: Self.importTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { _ = await library.importBooks(from: urls, into: context) }
        }
        .onOpenURL { url in
            Task {
                let books = await library.importBooks(from: [url], into: context)
                if let book = books.first { session = ReadingSession(book: book, sourceID: "opened-\(book.id)") }
            }
        }
        .alert(item: $library.importError) { failure in
            Alert(title: Text("Couldn't Add “\(failure.fileName)”"), message: Text(failure.message))
        }
        .overlay(alignment: .top) {
            if library.isImporting {
                Label("Adding to Library…", systemImage: "arrow.down.circle")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect()
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.smooth, value: library.isImporting)
    }
}

/// Toolbar buttons shared by the Home and Library tabs.
struct LibraryToolbar: ToolbarContent {
    @Environment(\.showSettings) private var showSettings

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Settings", systemImage: "gearshape") { showSettings() }
                .accessibilityIdentifier("settings.open")
        }
    }
}
