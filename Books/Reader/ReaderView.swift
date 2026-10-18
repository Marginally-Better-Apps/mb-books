import SwiftData
import SwiftUI

/// Opens a book: parses its publication off the main actor, then shows the reader.
struct ReaderView: View {
    let book: Book

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryStore.self) private var library
    @State private var model: ReaderModel?
    @State private var failure: String?

    var body: some View {
        Group {
            if let model {
                ReaderScreen(model: model)
            } else if let failure {
                ContentUnavailableView {
                    Label("Can't Open Book", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Close") { dismiss() }.buttonStyle(.glassProminent)
                }
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .task { await open() }
    }

    private func open() async {
        guard model == nil else { return }
        let container = library.storage.container(for: book.id)
        let result = await Task.detached(priority: .userInitiated) {
            Result(catching: {
                let publication = try EPUBParser.parse(container)
                ContentNormalizer.normalizeIfNeeded(publication, in: container.root)
                return publication
            })
        }.value
        switch result {
        case .success(let publication):
            model = ReaderModel(book: book, publication: publication, container: container, context: context)
        case .failure(let error):
            failure = error.localizedDescription
        }
    }
}

private struct ReaderScreen: View {
    @Bindable var model: ReaderModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(OrientationLock.self) private var orientationLock
    @Namespace private var glass
    @State private var isMenuOpen = false

    var body: some View {
        let palette = model.palette
        ZStack {
            palette.backgroundColor.ignoresSafeArea()
            ReaderContainer(model: model)
                .ignoresSafeArea()
                .accessibilityIdentifier("reader.content")
            popoverAnchor
            chrome
            if isMenuOpen {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { setMenu(open: false) }
            }
            menuLayer
        }
        .environment(\.colorScheme, palette.isDark ? .dark : .light)
        .statusBarHidden(!model.isChromeVisible)
        .persistentSystemOverlays(model.isChromeVisible ? .automatic : .hidden)
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .contents: ContentsView(model: model)
            case .themes: ThemesView(model: model, isRegularWidth: horizontalSizeClass == .regular)
            case .search: BookSearchView(model: model)
            case .listen:
                if let session = model.listening { ListenSettingsView(session: session) }
            }
        }
        .sheet(item: $model.editingNote) { annotation in
            NoteEditor(annotation: annotation)
        }
        .onAppear {
            model.isDarkAppearance = colorScheme == .dark
            model.startReadingClock()
        }
        .onChange(of: colorScheme) { _, scheme in model.isDarkAppearance = scheme == .dark }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.startReadingClock() } else { model.stopReadingClock() }
        }
        .onChange(of: model.isChromeVisible) { _, visible in if !visible { setMenu(open: false) } }
        // While the book is read aloud, the controls step aside after a moment so they don't cover the words being read.
        .task(id: [model.isChromeVisible, model.listening?.isPlaying == true, isMenuOpen, model.sheet == nil]) {
            guard model.isChromeVisible, model.listening?.isPlaying == true, !isMenuOpen, model.sheet == nil else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            model.hideChrome()
        }
        .onDisappear {
            model.close()
            orientationLock.unlock()
        }
    }

    /// An invisible view covering the popover's target, such as a highlight. `reader.js` reports rects
    /// in full-screen coordinates, so the anchor lives in a full-screen layer rather than the safe area.
    private var popoverAnchor: some View {
        GeometryReader { _ in
            let rect = model.popover?.rect ?? .zero
            Color.clear
                .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                .popover(item: $model.popover) { popover in
                    ReaderPopoverContent(model: model, popover: popover)
                        .presentationCompactAdaptation(.popover)
                }
                .position(x: rect.midX, y: rect.midY)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: Chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                if model.isChromeVisible {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Close Book")
                    .accessibilityIdentifier("reader.close")
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                Spacer()
                if model.isChromeVisible {
                    Text(model.book.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(model.palette.secondaryColor)
                        .lineLimit(1)
                        .frame(maxWidth: 240)
                        .transition(.opacity)
                }
                Spacer()
                if model.isChromeVisible {
                    Button {
                        if model.isListening { model.sheet = .listen } else { model.startListening() }
                    } label: {
                        Image(systemName: model.isListening ? "headphones.circle.fill" : "headphones")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel(model.isListening ? "Listening Options" : "Listen")
                    .accessibilityIdentifier("reader.listen")
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
            }
            .overlay(alignment: .topTrailing) {
                if model.isBookmarked {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.red)
                        .padding(.trailing, 6)
                        .offset(y: -10)
                        .accessibilityLabel("Bookmarked")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            Spacer()

            HStack {
                Color.clear.frame(width: 44, height: 44)
                Spacer()
                if model.isChromeVisible {
                    Button {
                        model.showsPagesLeft.toggle()
                    } label: {
                        Text(model.showsPagesLeft && !model.isFixedLayout && !model.isScrollMode
                             ? model.pagesLeftLabel : model.pageLabel)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(model.palette.secondaryColor)
                            .contentTransition(.numericText())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("reader.pageLabel")
                    .transition(.opacity)
                }
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
        .animation(.smooth(duration: 0.25), value: model.isChromeVisible)
    }

    private var menuLayer: some View {
        VStack {
            Spacer()
            if let session = model.listening, session.isActive, model.isChromeVisible, !isMenuOpen {
                ListenBar(session: session) { model.sheet = .listen }
                    .padding(.bottom, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack {
                Spacer()
                GlassEffectContainer(spacing: 16) {
                    if isMenuOpen {
                        ReaderMenu(model: model, close: { setMenu(open: false) })
                            .glassEffect(.regular, in: .rect(cornerRadius: 28))
                            .glassEffectID("menu", in: glass)
                    } else if !model.isChromeVisible, let session = model.listening, session.isActive {
                        ListenPill(session: session)
                    } else if model.isChromeVisible {
                        Button {
                            setMenu(open: true)
                        } label: {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 48, height: 48)
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .glassEffectID("menu", in: glass)
                        .accessibilityLabel("Reading Menu")
                        .accessibilityIdentifier("reader.menu")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func setMenu(open: Bool) {
        withAnimation(.bouncy(duration: 0.4)) { isMenuOpen = open }
    }
}

/// The glass reading menu, styled after Apple Books.
private struct ReaderMenu: View {
    @Bindable var model: ReaderModel
    let close: () -> Void

    @Environment(LibraryStore.self) private var library
    @Environment(OrientationLock.self) private var orientationLock

    var body: some View {
        VStack(spacing: 0) {
            row("Contents", detail: "\(model.progressPercent)%", systemImage: "list.bullet", id: "contents") { model.sheet = .contents }
            Divider().padding(.leading, 20)
            row("Search Book", systemImage: "magnifyingglass", id: "search") { model.sheet = .search }
            Divider().padding(.leading, 20)
            row("Themes & Settings", systemImage: "textformat.size", id: "themes") { model.sheet = .themes }
            Divider()
            HStack(spacing: 0) {
                if let url = library.shareURL(for: model.book) {
                    ShareLink(item: url) {
                        iconLabel("square.and.arrow.up", "Share")
                    }
                    Divider().frame(height: 40)
                }
                Button {
                    orientationLock.toggle()
                } label: {
                    iconLabel(orientationLock.isLocked ? "lock.rotation" : "lock.open.rotation",
                              orientationLock.isLocked ? "Unlock Rotation" : "Lock Rotation")
                }
                Divider().frame(height: 40)
                Button {
                    model.toggleBookmark()
                } label: {
                    iconLabel(model.isBookmarked ? "bookmark.fill" : "bookmark",
                              model.isBookmarked ? "Remove Bookmark" : "Bookmark")
                }
                .accessibilityIdentifier("reader.bookmark")
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)
        }
        .frame(width: 290)
        .padding(.vertical, 6)
    }

    private func row(_ title: LocalizedStringKey, detail: String? = nil, systemImage: String, id: String,
                     action: @escaping () -> Void) -> some View {
        Button {
            close()
            action()
        } label: {
            HStack {
                Text(title).font(.body)
                if let detail {
                    Text(detail).font(.body).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: systemImage).font(.body.weight(.medium))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reader.menu.\(id)")
    }

    private func iconLabel(_ systemImage: String, _ label: LocalizedStringKey) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: 40)
            .contentShape(.rect)
            .accessibilityLabel(label)
    }
}

/// Hosts `ReaderViewController`.
private struct ReaderContainer: UIViewControllerRepresentable {
    let model: ReaderModel

    func makeUIViewController(context: Context) -> ReaderViewController {
        ReaderViewController(model: model)
    }

    func updateUIViewController(_ controller: ReaderViewController, context: Context) {}
}

private struct ReaderPopoverContent: View {
    let model: ReaderModel
    let popover: ReaderPopover

    var body: some View {
        switch popover.content {
        case .footnote(let text):
            ScrollView {
                Text(text)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(idealWidth: 320, maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)
        case .highlight(let id):
            if let annotation = model.annotation(id: id) {
                HighlightMenu(model: model, annotation: annotation)
            }
        }
    }
}
