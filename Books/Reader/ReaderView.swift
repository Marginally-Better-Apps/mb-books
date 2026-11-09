import SwiftData
import SwiftUI

/// Opens a book: parses its publication off the main actor, then shows the reader.
struct ReaderView: View {
    let book: Book

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(LibraryStore.self) private var library
    @State private var model: ReaderModel?
    @State private var failure: String?
    @State private var showsSpinner = false
    /// The saved theme, so the book opens on its own page color rather than flashing white first.
    @State private var theme = ReaderPreferences.load().theme

    var body: some View {
        if let model {
            ReaderScreen(model: model)
        } else {
            let palette = theme.palette(dark: colorScheme == .dark)
            // The page color is always there, so the tasks below run even before the spinner appears.
            ZStack {
                palette.backgroundColor.ignoresSafeArea()
                if let failure {
                    ContentUnavailableView {
                        Label("Can't Open Book", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(failure)
                    } actions: {
                        Button("Close") { dismiss() }.buttonStyle(.glassProminent)
                    }
                } else if showsSpinner {
                    ProgressView().controlSize(.large)
                }
            }
            .environment(\.colorScheme, palette.isDark ? .dark : .light)
            .task { await open() }
            .task {
                // Most books open quickly; only show progress for the ones that don't.
                try? await Task.sleep(for: .milliseconds(300))
                showsSpinner = true
            }
        }
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
    /// UI tests turn off auto-hiding so the listening controls don't vanish between finding and tapping them.
    static let keepsControlsVisible = ProcessInfo.processInfo.arguments.contains("-ui-testing")

    @Bindable var model: ReaderModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(OrientationLock.self) private var orientationLock
    @Namespace private var glass
    @State private var isMenuOpen = false

    // Control sizes follow Dynamic Type, capped so the controls stay inside the page margins `ReaderLayout` leaves.
    @ScaledMetric(relativeTo: .body) private var scaledGlyph: CGFloat = 17
    @ScaledMetric(relativeTo: .body) private var scaledButton: CGFloat = 30
    @ScaledMetric(relativeTo: .body) private var scaledMenuButton: CGFloat = 48
    @ScaledMetric(relativeTo: .body) private var scaledRibbon: CGFloat = 22

    private var glyph: CGFloat { min(scaledGlyph, 22) }
    private var button: CGFloat { min(scaledButton, 34) }
    private var menuButton: CGFloat { min(scaledMenuButton, 52) }

    /// The page, its controls, and what they present.
    @ViewBuilder
    private var screen: some View {
        let palette = model.palette
        ZStack {
            palette.backgroundColor.ignoresSafeArea()
            ReaderContainer(model: model)
                .ignoresSafeArea()
                .accessibilityIdentifier("reader.content")
            popoverAnchor
            if model.isScrollMode, model.isChromeVisible {
                scrollBackdrop
                    .transition(.opacity)
            }
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
        // Sheets and popovers are presented apart from the view above, so each takes the theme's appearance itself.
        .sheet(item: $model.sheet) { sheet in
            sheetContent(sheet).readerColorScheme(model.palette)
        }
        .sheet(item: editingNote) { (annotation: Annotation) in
            NoteEditor(annotation: annotation).readerColorScheme(model.palette)
        }
    }

    private var editingNote: Binding<Annotation?> { $model.editingNote }

    @ViewBuilder
    private func sheetContent(_ sheet: ReaderSheet) -> some View {
        switch sheet {
        case .contents: ContentsView(model: model)
        case .themes: ThemesView(model: model, isRegularWidth: horizontalSizeClass == .regular)
        case .search: BookSearchView(model: model)
        case .listen:
            if let session = model.listening { ListenSettingsView(session: session) }
        }
    }

    var body: some View {
        screen
        .onAppear {
            model.isDarkAppearance = colorScheme == .dark
            model.startReadingClock()
        }
        .onChange(of: colorScheme) { _, scheme in model.isDarkAppearance = scheme == .dark }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.startReadingClock() } else { model.stopReadingClock() }
        }
        .onChange(of: model.isChromeVisible) { _, visible in if !visible { setMenu(open: false) } }
        .onChange(of: model.listening?.failureMessage) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
        // While the book is read aloud, the controls step aside after a moment so they don't cover the words being read.
        // Not with VoiceOver, though: the controls would vanish from under its focus.
        .task(id: autoHideState) {
            guard autoHideState == [true, true, false, true, false], !Self.keepsControlsVisible else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            model.hideChrome()
        }
        .onDisappear {
            model.close()
            orientationLock.unlock()
        }
    }

    /// Whether the controls are up, the book is playing, the menu is open, no sheet is up, and VoiceOver is on.
    private var autoHideState: [Bool] {
        let isPlaying = model.listening?.isPlaying == true
        return [model.isChromeVisible, isPlaying, isMenuOpen, model.sheet == nil, voiceOverEnabled]
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
                        .readerColorScheme(model.palette)
                }
                .position(x: rect.midX, y: rect.midY)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: Chrome

    /// Scroll mode runs text under the controls, so while they're up the page color shades it behind them.
    private var scrollBackdrop: some View {
        GeometryReader { proxy in
            let background = model.palette.backgroundColor
            // Solid just past the controls (4 pt from the safe area, then a 44–52 pt button), then fading out.
            let top = proxy.safeAreaInsets.top + 56
            let bottom = proxy.safeAreaInsets.bottom + 60
            let fade: CGFloat = 26
            VStack(spacing: 0) {
                LinearGradient(stops: Self.backdropStops(background, solid: top, fade: fade), startPoint: .top, endPoint: .bottom)
                    .frame(height: top + fade)
                Spacer(minLength: 0)
                LinearGradient(stops: Self.backdropStops(background, solid: bottom, fade: fade), startPoint: .bottom, endPoint: .top)
                    .frame(height: bottom + fade)
            }
            .ignoresSafeArea()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Solid for `solid` points, then easing out over `fade`. It stays nearly opaque where it meets the solid part,
    /// so a line cut by that edge doesn't leave the tops of its letters showing along it.
    private static func backdropStops(_ color: Color, solid: CGFloat, fade: CGFloat) -> [Gradient.Stop] {
        let total = solid + fade
        return [Gradient.Stop(color: color, location: 0)] + [0, 0.25, 0.5, 0.75, 1].map { (t: CGFloat) in
            Gradient.Stop(color: color.opacity(1 - t * t), location: (solid + t * fade) / total)
        }
    }

    private var buttonTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.8))
    }

    /// Whether the listening controls sit in the bottom row, in place of the page label.
    private var isListenBarDocked: Bool {
        model.listening?.isActive == true && model.isChromeVisible && !isMenuOpen
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                if model.isChromeVisible {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: glyph, weight: .semibold))
                            .frame(width: button, height: button)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Close Book")
                    // The control sizes are capped; the large content viewer shows them bigger instead.
                    .accessibilityShowsLargeContentViewer { Label("Close Book", systemImage: "xmark") }
                    .accessibilityIdentifier("reader.close")
                    .transition(buttonTransition)
                }
                Spacer()
                if model.isChromeVisible {
                    titleSlot
                        .transition(.opacity)
                }
                Spacer()
                if model.isChromeVisible {
                    listenButton
                        .accessibilityLabel(model.isListening ? "Listening Options" : "Listen")
                        .accessibilityShowsLargeContentViewer {
                            Label(model.isListening ? "Listening Options" : "Listen", systemImage: "headphones")
                        }
                        .accessibilityIdentifier("reader.listen")
                        .transition(buttonTransition)
                } else {
                    Color.clear.frame(width: button + 14, height: button + 14)
                }
            }
            // The menu's bookmark button shows the state while the controls are up; the ribbon would cover them.
            .overlay(alignment: .topTrailing) {
                if model.isBookmarked, !model.isChromeVisible {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: min(scaledRibbon, 28)))
                        .foregroundStyle(.tint)
                        .padding(.trailing, 6)
                        .offset(y: -10)
                        .accessibilityLabel("Bookmarked")
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            Spacer()

            HStack {
                Color.clear.frame(width: 44, height: 44)
                Spacer()
                // While the listening bar takes this row, the page position moves up under the title.
                if model.isChromeVisible, !isListenBarDocked {
                    pageLabel(.footnote)
                        .transition(.opacity)
                }
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
        .animation(.smooth(duration: 0.25), value: model.isChromeVisible)
        .animation(.smooth(duration: 0.25), value: model.listening?.isFollowing)
        .animation(.smooth(duration: 0.25), value: model.searchReturn == nil)
        .animation(.smooth(duration: 0.25), value: isListenBarDocked)
    }

    /// The book's title, or a way back once the reader pages away: to the narration, or else to the search results.
    /// While the listening bar is docked, the page position sits underneath.
    @ViewBuilder
    private var titleSlot: some View {
        if let session = model.listening, session.isActive, !session.isFollowing {
            withPageCaption { compact in
                capsuleButton("Return to Narration", systemImage: "arrow.uturn.backward", compact: compact) {
                    session.returnToNarration()
                }
                .accessibilityIdentifier("listen.return")
            }
        } else if model.searchReturn != nil {
            withPageCaption { compact in
                capsuleButton("Results", systemImage: "chevron.backward", compact: compact) {
                    model.returnToSearchResults()
                }
                .accessibilityLabel("Back to Search Results")
                .accessibilityIdentifier("reader.backToResults")
            }
        } else {
            VStack(spacing: 1) {
                Text(model.book.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(model.palette.secondaryColor)
                    .lineLimit(1)
                if isListenBarDocked { pageLabel(.caption2) }
            }
            .frame(maxWidth: 240)
        }
    }

    /// A capsule in the title's place, with the page position under it while the listening bar is docked:
    /// at full size if both fit in the top row, otherwise with a smaller capsule.
    @ViewBuilder
    private func withPageCaption<Capsule: View>(@ViewBuilder _ capsule: (_ compact: Bool) -> Capsule) -> some View {
        let full = capsule(false)
        if isListenBarDocked {
            let compact = capsule(true)
            ViewThatFits(in: .vertical) {
                VStack(spacing: 1) { full; pageLabel(.caption2) }
                VStack(spacing: 1) { compact; pageLabel(.caption2) }
            }
            .frame(maxHeight: button + 14)
        } else {
            full
        }
    }

    private func capsuleButton(_ title: LocalizedStringKey, systemImage: String, compact: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(compact ? .caption.weight(.semibold) : .footnote.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(minHeight: compact ? nil : button)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(compact ? .small : .regular)
    }

    /// "12 of 340", or the pages left in the chapter; tapping switches between them.
    private func pageLabel(_ font: Font) -> some View {
        Button {
            model.showsPagesLeft.toggle()
        } label: {
            Text(model.showsPagesLeft && !model.isFixedLayout && !model.isScrollMode
                 ? model.pagesLeftLabel : model.pageLabel)
                .font(font.monospacedDigit())
                .foregroundStyle(model.palette.secondaryColor)
                .lineLimit(1)
                .contentTransition(.numericText())
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reader.pageLabel")
    }

    /// Tinted while the book is read aloud, so it's clear the button now opens the listening options.
    @ViewBuilder
    private var listenButton: some View {
        let button = Button {
            if model.isListening { model.sheet = .listen } else { model.startListening() }
        } label: {
            Image(systemName: "headphones")
                .font(.system(size: glyph, weight: .semibold))
                .frame(width: self.button, height: self.button)
        }
        .buttonBorderShape(.circle)
        if model.isListening {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.glass)
        }
    }

    private var menuLayer: some View {
        VStack(spacing: 8) {
            Spacer()
            // A sheet that's up shows its own; the Contents sheet does, while it's open.
            if model.sheet == nil, model.editingNote == nil, let deleted = model.recentlyDeleted {
                UndoDeleteBanner(deleted: deleted, undoIdentifier: "reader.undoDelete") { model.undoDelete() }
                    .padding(.horizontal, 16)
                    .transition(UndoDeleteBanner.transition(reduceMotion: reduceMotion))
            }
            if let session = model.listening, let message = session.failureMessage {
                ListeningFailureBanner(message: message, retry: { model.startListening() }, dismiss: { model.stopListening() })
                    .padding(.horizontal, 16)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 8) {
                if isListenBarDocked, let session = model.listening {
                    ListenBar(session: session)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
                Spacer(minLength: 0)
                GlassEffectContainer(spacing: 16) {
                    if isMenuOpen {
                        ReaderMenu(model: model, close: { setMenu(open: false) })
                            .glassEffect(.regular, in: .rect(cornerRadius: 28))
                            .glassEffectID("menu", in: glass)
                            .accessibilityAction(.escape) { setMenu(open: false) }
                    } else if !model.isChromeVisible, let session = model.listening, session.isActive {
                        ListenPill(session: session)
                    } else if model.isChromeVisible {
                        Button {
                            setMenu(open: true)
                        } label: {
                            Image(systemName: "list.bullet")
                                .font(.system(size: glyph + 1, weight: .semibold))
                                .frame(width: menuButton, height: menuButton)
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .glassEffectID("menu", in: glass)
                        .accessibilityLabel("Reading Menu")
                        .accessibilityShowsLargeContentViewer { Label("Reading Menu", systemImage: "list.bullet") }
                        .accessibilityIdentifier("reader.menu")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
        .animation(.smooth(duration: 0.25), value: isListenBarDocked)
        .animation(.smooth(duration: 0.25), value: model.listening?.failureMessage)
        .animation(.smooth(duration: 0.25), value: model.recentlyDeleted)
        .animation(.smooth(duration: 0.25), value: model.sheet == nil)
    }

    private func setMenu(open: Bool) {
        withAnimation(reduceMotion ? .smooth(duration: 0.25) : .bouncy(duration: 0.4)) { isMenuOpen = open }
    }
}

/// Why reading aloud stopped, with a way to try again.
private struct ListeningFailureBanner: View {
    let message: String
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Can't Read Aloud")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Try Again", action: retry)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("listen.retry")
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("listen.dismissFailure")
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .frame(maxWidth: 520)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("listen.failure")
    }
}

/// Offers back a highlight or bookmark for a few seconds after it's deleted, in the reader or the Contents sheet.
struct UndoDeleteBanner: View {
    let deleted: DeletedAnnotation
    let undoIdentifier: String
    let undo: () -> Void

    /// Slides up from the bottom, or only fades with Reduce Motion.
    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    var body: some View {
        HStack {
            Text(deleted.kind == .highlight ? "Highlight Deleted" : "Bookmark Deleted")
                .font(.subheadline.weight(.medium))
            Spacer()
            Button("Undo", action: undo)
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
                .accessibilityIdentifier(undoIdentifier)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: 520)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
    }
}

private extension View {
    /// The reading theme's light or dark appearance, for views presented from the reader. The environment
    /// styles the content, and the presentation itself (the sheet or popover) is overridden to match.
    /// A `preferredColorScheme` here would fight the app's own Appearance setting.
    func readerColorScheme(_ palette: ThemePalette) -> some View {
        environment(\.colorScheme, palette.isDark ? .dark : .light)
            .background(PresentationAppearance(style: palette.isDark ? .dark : .light))
    }
}

/// Sets the interface style of the presentation it's placed in, and only that presentation.
private struct PresentationAppearance: UIViewControllerRepresentable {
    let style: UIUserInterfaceStyle

    func makeUIViewController(context: Context) -> Controller { Controller(style: style) }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.style = style
        controller.apply()
    }

    final class Controller: UIViewController {
        var style: UIUserInterfaceStyle

        init(style: UIUserInterfaceStyle) {
            self.style = style
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            apply()
        }

        /// The presented controller is the root of this controller's parent chain.
        func apply() {
            var root: UIViewController = self
            while let parent = root.parent { root = parent }
            guard root.presentingViewController != nil else { return }
            root.overrideUserInterfaceStyle = style
        }
    }
}

/// The glass reading menu, styled after Apple Books.
private struct ReaderMenu: View {
    @Bindable var model: ReaderModel
    let close: () -> Void

    @Environment(LibraryStore.self) private var library
    @Environment(OrientationLock.self) private var orientationLock
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 290
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 18
    @State private var bookmarkToggles = 0

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
                    bookmarkToggles += 1
                } label: {
                    iconLabel(model.isBookmarked ? "bookmark.fill" : "bookmark",
                              model.isBookmarked ? "Remove Bookmark" : "Bookmark")
                }
                .accessibilityIdentifier("reader.bookmark")
                .sensoryFeedback(.impact(weight: .light), trigger: bookmarkToggles)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)
        }
        // Grows with Dynamic Type, but never wider than the screen.
        .containerRelativeFrame(.horizontal) { length, _ in min(width, 480, length - 32) }
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
            .font(.system(size: min(iconSize, 26), weight: .medium))
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
