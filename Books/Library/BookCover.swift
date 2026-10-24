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
                .foregroundStyle(.white)
                .padding(12)
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

/// "NEW", a percentage, or "Finished", shown under covers.
struct BookProgressBadge: View {
    let book: Book

    var body: some View {
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

/// The book actions shared by context menus and "…" buttons.
struct BookActions: View {
    let book: Book
    @Binding var isConfirmingRemoval: Bool
    @Binding var isShowingDetails: Bool
    @Binding var isAddingToCollection: Bool

    @Environment(LibraryStore.self) private var library

    var body: some View {
        Button("Book Details", systemImage: "info.circle") { isShowingDetails = true }
        Divider()
        Button(book.wantToRead ? "Remove from Want to Read" : "Want to Read",
               systemImage: book.wantToRead ? "minus.circle" : "plus.circle") {
            book.wantToRead.toggle()
        }
        Button("Add to Collection…", systemImage: "text.badge.plus") { isAddingToCollection = true }
        if book.isFinished {
            Button("Mark as Still Reading", systemImage: "book") { book.markFinished(false) }
        } else {
            Button("Mark as Finished", systemImage: "checkmark.circle") { book.markFinished(true) }
        }
        if let url = library.shareURL(for: book) {
            ShareLink("Share Book", item: url)
        }
        Divider()
        Button("Remove…", systemImage: "trash", role: .destructive) { isConfirmingRemoval = true }
    }
}

/// Attaches the context menu, details sheet, collection picker, and removal confirmation to a book view.
struct BookInteractions: ViewModifier {
    let book: Book

    @Environment(\.modelContext) private var context
    @Environment(LibraryStore.self) private var library
    @State private var isConfirmingRemoval = false
    @State private var isShowingDetails = false
    @State private var isAddingToCollection = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                BookActions(book: book, isConfirmingRemoval: $isConfirmingRemoval,
                            isShowingDetails: $isShowingDetails, isAddingToCollection: $isAddingToCollection)
            } preview: {
                BookCover(book: book).frame(width: 220)
                    .environment(library)
            }
            .confirmationDialog("Remove “\(book.title)”?", isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
                Button("Remove from Library", role: .destructive) { library.delete([book], from: context) }
            } message: {
                Text("The book, its highlights, notes, and bookmarks will be deleted from this device.")
            }
            .sheet(isPresented: $isShowingDetails) { BookDetailView(book: book) }
            .sheet(isPresented: $isAddingToCollection) { CollectionPicker(books: [book]) }
    }
}

extension View {
    func bookInteractions(_ book: Book) -> some View {
        modifier(BookInteractions(book: book))
    }
}
