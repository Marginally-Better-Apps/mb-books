import SwiftData
import SwiftUI
import UIKit

/// A book cover at its natural aspect ratio, or a generated cover when the book has none.
struct BookCover: View {
    let book: Book
    var cornerRadius: CGFloat = 4

    @Environment(LibraryStore.self) private var library
    @State private var image: UIImage?
    @State private var didLoad = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(image.size.width / max(image.size.height, 1), contentMode: .fit)
            } else {
                GeneratedCover(title: book.title, author: book.author)
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .opacity(didLoad ? 1 : 0)
            }
        }
        .clipShape(.rect(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.black.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
        .task(id: book.id) {
            image = await CoverCache.shared.image(at: library.coverURL(for: book))
            didLoad = true
        }
        .accessibilityHidden(true)
    }
}

/// Cover art for books without one: a tinted gradient with the title and author, like Apple Books.
struct GeneratedCover: View {
    let title: String
    let author: String

    var body: some View {
        // A stable hash: `hashValue` is randomized per launch.
        let seed = title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let hue = Double(seed % 360) / 360
        LinearGradient(
            colors: [Color(hue: hue, saturation: 0.45, brightness: 0.62), Color(hue: hue, saturation: 0.55, brightness: 0.38)],
            startPoint: .top, endPoint: .bottom)
            .overlay {
                GeometryReader { proxy in
                    Group {
                        // Below about 70 pt the title can't fit without truncating, so small covers show its initial.
                        if proxy.size.width >= 70 {
                            VStack(spacing: 8) {
                                Text(title)
                                    .font(.system(.title3, design: .serif, weight: .semibold))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(5)
                                    .minimumScaleFactor(0.5)
                                Rectangle().fill(.white.opacity(0.5)).frame(width: 28, height: 1)
                                Text(author)
                                    .font(.system(.caption, design: .serif))
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.6)
                            }
                            .padding(12)
                        } else {
                            Text(title.first.map { String($0).uppercased() } ?? "")
                                .font(.system(.title2, design: .serif, weight: .semibold))
                                .minimumScaleFactor(0.5)
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
    }
}

/// Decoded, display-ready covers shared across views.
@MainActor
final class CoverCache {
    static let shared = CoverCache()
    private let cache = NSCache<NSURL, UIImage>()

    func image(at url: URL?) async -> UIImage? {
        guard let url else { return nil }
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let image = await Task.detached(priority: .utility) {
            UIImage(contentsOfFile: url.path)?.preparingForDisplay()
        }.value
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}

/// "NEW", a percentage, or "Finished", shown under covers. VoiceOver reads it through `bookAccessibility`.
struct BookProgressBadge: View {
    let book: Book

    var body: some View {
        badge.accessibilityHidden(true)
    }

    @ViewBuilder
    private var badge: some View {
        if book.isFinished {
            Label("Finished", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        } else if book.isNew {
            Text("NEW")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.tint, in: .capsule)
        } else {
            Text(book.percentRead, format: .percent)
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

extension Book {
    /// "New", "Finished", or a percentage: the badge under a cover, as VoiceOver reads it.
    var progressDescription: String {
        if isFinished { String(localized: "Finished") } else if isNew { String(localized: "New") } else { percentRead.formatted(.percent) }
    }
}

extension View {
    /// Reads a book's cover or row as "Title, Author", with its progress as the value.
    /// Progress badges are hidden from VoiceOver, since this reads them.
    func bookAccessibility(_ book: Book) -> some View {
        accessibilityLabel("\(book.title), \(book.author)")
            .accessibilityValue(book.progressDescription)
    }
}

/// A book in a list: its cover, title, author, and progress, with an optional trailing accessory.
struct BookRow<Accessory: View>: View {
    let book: Book
    let source: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 16) {
            BookCover(book: book)
                .frame(width: 52, height: 78)
                .zoomSource(source)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title).font(.headline).lineLimit(2)
                Text(book.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                BookProgressBadge(book: book).padding(.top, 2)
            }
            Spacer(minLength: 0)
            accessory
        }
        .contentShape(.rect)
    }
}

extension BookRow where Accessory == EmptyView {
    init(book: Book, source: String) {
        self.init(book: book, source: source) { EmptyView() }
    }
}

/// The quiet "…" button beside a cover or row.
struct BookMenuButton: View {
    let book: Book

    @State private var state = BookActionState()

    var body: some View {
        Menu {
            BookActions(book: book, state: $state)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        // Menus take the accent color; this is a quiet secondary control, as in Apple Books.
        .tint(.secondary)
        // A full 44 pt tap target that lays out 36 pt tall, so the row under a cover stays compact.
        .padding(.vertical, -4)
        .padding(.trailing, -10)
        .accessibilityLabel("More for \(book.title)")
        .bookActionPresentations(book, state: $state)
    }
}

/// The book actions shared by context menus and "…" buttons.
struct BookActions: View {
    let book: Book
    @Binding var state: BookActionState

    @Environment(LibraryStore.self) private var library

    var body: some View {
        Button("Book Details", systemImage: "info.circle") { state.isShowingDetails = true }
        Divider()
        Button(book.wantToRead ? "Remove from Want to Read" : "Want to Read",
               systemImage: book.wantToRead ? "bookmark.fill" : "bookmark") {
            book.wantToRead.toggle()
            state.wantToReadChanges += 1
        }
        Button("Add to Collection…", systemImage: "rectangle.stack.badge.plus") { state.isAddingToCollection = true }
        if book.isFinished {
            Button("Mark as Still Reading", systemImage: "book") { book.markFinished(false) }
        } else {
            Button("Mark as Finished", systemImage: "checkmark.circle") {
                book.markFinished(true)
                state.finishes += 1
            }
        }
        if let url = library.shareURL(for: book) {
            ShareLink("Share Book", item: url)
        }
        Divider()
        Button("Remove…", systemImage: "trash", role: .destructive) { state.isConfirmingRemoval = true }
    }
}

/// What a book's actions present, plus counters that trigger their haptics.
struct BookActionState {
    var isConfirmingRemoval = false
    var isShowingDetails = false
    var isAddingToCollection = false
    var wantToReadChanges = 0
    var finishes = 0
}

/// Attaches the details sheet, collection picker, removal confirmation, and haptics that book actions use.
private struct BookActionPresentations: ViewModifier {
    let book: Book
    @Binding var state: BookActionState

    @Environment(\.modelContext) private var context
    @Environment(LibraryStore.self) private var library

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Remove \"\(book.title)\"?", isPresented: $state.isConfirmingRemoval, titleVisibility: .visible) {
                Button("Remove from Library", role: .destructive) { library.delete([book], from: context) }
            } message: {
                Text("The book, its highlights, notes, and bookmarks will be deleted from this device.")
            }
            .sheet(isPresented: $state.isShowingDetails) { BookDetailView(book: book) }
            .sheet(isPresented: $state.isAddingToCollection) { CollectionPicker(books: [book]) }
            .sensoryFeedback(.selection, trigger: state.wantToReadChanges)
            .sensoryFeedback(.success, trigger: state.finishes)
    }
}

/// Attaches the context menu and everything its actions present to a book view.
struct BookInteractions: ViewModifier {
    let book: Book

    @Environment(LibraryStore.self) private var library
    @State private var state = BookActionState()

    func body(content: Content) -> some View {
        content
            .contextMenu {
                BookActions(book: book, state: $state)
            } preview: {
                BookCover(book: book).frame(width: 220)
                    .environment(library)
            }
            .bookActionPresentations(book, state: $state)
    }
}

extension View {
    func bookInteractions(_ book: Book) -> some View {
        modifier(BookInteractions(book: book))
    }

    fileprivate func bookActionPresentations(_ book: Book, state: Binding<BookActionState>) -> some View {
        modifier(BookActionPresentations(book: book, state: state))
    }
}
