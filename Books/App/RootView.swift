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
        // A sidebar on iPad, a tab bar on iPhone.
        .tabViewStyle(.sidebarAdaptable)
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
        .alert(failureSummary.title, isPresented: isShowingFailures) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failureSummary.message)
        }
        .overlay(alignment: .top) {
            Group {
                if library.isImporting {
                    ImportToast(title: progressTitle, systemImage: "arrow.down.circle")
                } else if let notice = library.importNotice {
                    ImportToast(title: notice.title, detail: notice.detail, systemImage: "checkmark.circle")
                        .id(notice.id)
                        .task {
                            AccessibilityNotification.Announcement(notice.title).post()
                            try? await Task.sleep(for: .seconds(2.5))
                            if library.importNotice == notice { library.importNotice = nil }
                        }
                }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        .animation(.smooth, value: library.isImporting)
        .animation(.smooth, value: library.importNotice)
    }

    private var progressTitle: String {
        guard library.importTotal > 1 else { return String(localized: "Adding to Library…") }
        let current = min(library.importCompleted + 1, library.importTotal)
        return String(localized: "Adding \(current) of \(library.importTotal)…")
    }

    private var failureSummary: (title: String, message: String) {
        LibraryStore.failureSummary(library.importFailures)
    }

    private var isShowingFailures: Binding<Bool> {
        Binding {
            !library.importFailures.isEmpty
        } set: { isPresented in
            if !isPresented { library.importFailures.removeAll() }
        }
    }
}

/// The glass capsule at the top of the screen that shows import progress and results.
private struct ImportToast: View {
    let title: String
    var detail: String?
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect()
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
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
