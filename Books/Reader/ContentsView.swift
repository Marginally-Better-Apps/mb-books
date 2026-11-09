import SwiftData
import SwiftUI

/// Contents, bookmarks, and highlights, with a whole-book progress scrubber.
struct ContentsView: View {
    @Bindable var model: ReaderModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var tab = Tab.contents
    @State private var scrubValue: Double?
    /// The highlight just deleted from the list, offered back for a few seconds.
    @State private var deleted: DeletedHighlight?

    enum Tab: Hashable { case contents, bookmarks, highlights }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Picker("Section", selection: $tab) {
                    Text("Contents").tag(Tab.contents)
                    Text("Bookmarks").tag(Tab.bookmarks)
                    Text("Highlights").tag(Tab.highlights)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)

                switch tab {
                case .contents: contents
                case .bookmarks: annotationList(model.book.bookmarks, empty: bookmarksEmpty)
                case .highlights: annotationList(model.book.highlights, empty: highlightsEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let deleted { undoBanner(deleted) }
            }
            .animation(.smooth(duration: 0.25), value: deleted)
            .task(id: deleted) {
                guard deleted != nil else { return }
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                deleted = nil
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier("contents.close")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDragIndicator(.visible)
    }

    private func undoBanner(_ highlight: DeletedHighlight) -> some View {
        HStack {
            Text("Highlight Deleted").font(.subheadline.weight(.medium))
            Spacer()
            Button("Undo") {
                highlight.restore(to: model.book, in: context)
                model.navigator?.reloadHighlights()
                deleted = nil
            }
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 44)
            .accessibilityIdentifier("contents.undoDelete")
        }
        .padding(.horizontal, 20)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Deletes from the list; a highlight (with its note) can be brought back from the banner.
    private func delete(_ annotation: Annotation) {
        deleted = annotation.kind == .highlight ? DeletedHighlight(annotation) : nil
        model.delete(annotation)
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                BookCover(book: model.book)
                    .frame(width: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.book.title).font(.headline).lineLimit(2)
                    Text(model.book.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            VStack(spacing: 4) {
                Slider(value: Binding(
                    get: { scrubValue ?? model.location.totalProgression },
                    set: { scrubValue = $0 }
                ), in: 0...1) { editing in
                    if !editing, let value = scrubValue {
                        model.go(toTotalProgression: value)
                        scrubValue = nil
                    }
                }
                .accessibilityLabel("Book Progress")
                HStack {
                    Text(model.publication.chapterTitle(forSpineIndex: scrubTarget) ?? "")
                        .lineLimit(1)
                    Spacer()
                    Text("\(Book.wholePercent(scrubValue ?? model.location.totalProgression, opened: true))%")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private var scrubTarget: Int {
        guard let scrubValue else { return model.location.spineIndex }
        return model.progressionMap.location(forTotalProgression: scrubValue).spineIndex
    }

    private var contents: some View {
        let entries = model.publication.flattenedTableOfContents
        let current = currentEntryID(entries)
        return ScrollViewReader { proxy in
            List {
                if entries.isEmpty {
                    ForEach(Array(model.publication.spine.enumerated()), id: \.offset) { index, _ in
                        Button {
                            model.go(to: Locator(spineIndex: index))
                            dismiss()
                        } label: {
                            Text("Section \(index + 1)")
                                .fontWeight(index == model.location.spineIndex ? .semibold : .regular)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(entries, id: \.point.id) { entry in
                    Button {
                        model.go(to: entry.point)
                        dismiss()
                    } label: {
                        HStack {
                            Text(entry.point.title)
                                .fontWeight(entry.point.id == current ? .semibold : .regular)
                                .foregroundStyle(entry.point.path == nil ? .secondary : .primary)
                            Spacer()
                            if entry.point.id == current {
                                Image(systemName: "book.fill").font(.caption).foregroundStyle(.tint)
                            }
                        }
                        .padding(.leading, CGFloat(entry.level) * 18)
                    }
                    .disabled(entry.point.path == nil)
                    .id(entry.point.id)
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
        }
    }

    private func currentEntryID(_ entries: [(point: NavigationPoint, level: Int)]) -> String? {
        var best: String?
        for (point, _) in entries {
            guard let path = point.path, let index = model.publication.spineIndex(forPath: path) else { continue }
            if index <= model.location.spineIndex { best = point.id } else { break }
        }
        return best
    }

    private func annotationList(_ annotations: [Annotation], empty: some View) -> some View {
        List {
            if annotations.isEmpty {
                empty.listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
            ForEach(annotations) { annotation in
                Button {
                    model.go(to: annotation.locator)
                    dismiss()
                } label: {
                    AnnotationRow(annotation: annotation)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(annotation) }
                }
                .contextMenu {
                    if annotation.kind == .highlight {
                        Button("Edit Note", systemImage: "note.text") {
                            dismiss()
                            model.editingNote = annotation
                        }
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = annotation.text }
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(annotation) }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var bookmarksEmpty: some View {
        ContentUnavailableView(
            "No Bookmarks", systemImage: "bookmark",
            description: Text("Tap the bookmark button in the reading menu to save your place."))
    }

    private var highlightsEmpty: some View {
        ContentUnavailableView(
            "No Highlights", systemImage: "highlighter",
            description: Text("Select text and choose Highlight or Add Note."))
    }
}

private struct AnnotationRow: View {
    let annotation: Annotation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(annotation.chapterTitle ?? "")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(annotation.created, format: .dateTime.month(.abbreviated).day().year())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if annotation.kind == .highlight {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(annotation.color.color)
                        .frame(width: 4)
                    Text(annotation.text)
                        .font(.callout)
                        .lineLimit(4)
                }
                if let note = annotation.note, !note.isEmpty {
                    Label(note, systemImage: "note.text")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            } else {
                Label("\(Int((annotation.locator.totalProgression * 100).rounded()))% through the book",
                      systemImage: "bookmark.fill")
                    .font(.callout)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}

/// A deleted highlight's contents, enough to put it back as it was, note included.
struct DeletedHighlight: Equatable {
    let id: UUID
    let created: Date
    let locatorData: Data
    let rangeStart: String?
    let rangeEnd: String?
    let text: String
    let note: String?
    let color: HighlightColor
    let chapterTitle: String?

    init(_ annotation: Annotation) {
        id = annotation.id
        created = annotation.created
        locatorData = annotation.locatorData
        rangeStart = annotation.rangeStart
        rangeEnd = annotation.rangeEnd
        text = annotation.text
        note = annotation.note
        color = annotation.color
        chapterTitle = annotation.chapterTitle
    }

    @discardableResult
    func restore(to book: Book, in context: ModelContext) -> Annotation {
        let annotation = Annotation(
            kind: .highlight, locator: Locator(spineIndex: 0), text: text, chapterTitle: chapterTitle,
            rangeStart: rangeStart, rangeEnd: rangeEnd, color: color)
        annotation.id = id
        annotation.created = created
        annotation.locatorData = locatorData
        annotation.note = note
        context.insert(annotation)
        annotation.book = book
        try? context.save()
        return annotation
    }
}

/// The palette shown after highlighting or when tapping an existing highlight.
struct HighlightMenu: View {
    let model: ReaderModel
    let annotation: Annotation

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title3) private var swatchSize: CGFloat = 28
    /// Deleting asks once, inline: the palette closes with the highlight, so it can't offer Undo afterwards.
    @State private var isConfirmingDelete = false

    private static let colors = HighlightColor.allCases

    /// Every swatch gets at least a 44 pt target; at accessibility sizes they wrap onto two rows.
    private var target: CGFloat { max(44, swatchSize + 16) }
    private var columns: Int { dynamicTypeSize.isAccessibilitySize ? 3 : Self.colors.count }
    /// The actions span the same width as the swatches: four in a row, or two by two at accessibility sizes.
    private var actionWidth: CGFloat { target * CGFloat(columns) / (dynamicTypeSize.isAccessibilitySize ? 2 : 4) }

    var body: some View {
        VStack(spacing: 6) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(stride(from: 0, to: Self.colors.count, by: columns)), id: \.self) { start in
                    GridRow {
                        ForEach(Self.colors[start..<min(start + columns, Self.colors.count)]) { color in
                            swatch(color)
                        }
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: annotation.color)
            if isConfirmingDelete {
                HStack(spacing: 0) {
                    Button("Cancel") { isConfirmingDelete = false }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(.rect)
                    Button("Delete", role: .destructive) { model.delete(annotation) }
                        .fontWeight(.semibold)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(.rect)
                        .accessibilityLabel("Delete Highlight")
                        .accessibilityIdentifier("highlight.confirmDelete")
                }
                .buttonStyle(.plain)
                .frame(width: target * CGFloat(columns))
            } else {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    if dynamicTypeSize.isAccessibilitySize {
                        GridRow { noteAction; copyAction }
                        GridRow { shareAction; deleteAction }
                    } else {
                        GridRow { noteAction; copyAction; shareAction; deleteAction }
                    }
                }
                .font(.title3)
            }
        }
        .padding(10)
        .fixedSize()
    }

    private func swatch(_ color: HighlightColor) -> some View {
        Button {
            model.setColor(color, for: annotation)
        } label: {
            ZStack {
                if color == .underline {
                    Circle().strokeBorder(.secondary, lineWidth: 1)
                    Text("U").font(.callout.weight(.bold)).underline(color: .red)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                } else {
                    Circle().fill(color.color)
                }
                if annotation.color == color {
                    Circle().strokeBorder(.primary, lineWidth: 2.5).padding(-4)
                }
            }
            .frame(width: swatchSize, height: swatchSize)
            .frame(width: target, height: target)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(color.name))
        .accessibilityAddTraits(annotation.color == color ? .isSelected : [])
    }

    private var noteAction: some View {
        action("Note", "note.text") {
            model.popover = nil
            model.editingNote = annotation
        }
    }

    private var copyAction: some View {
        action("Copy", "doc.on.doc") {
            UIPasteboard.general.string = annotation.text
            model.popover = nil
        }
    }

    private var shareAction: some View {
        ShareLink(item: "“\(annotation.text)”\n— \(model.book.title), \(model.book.author)") {
            Label("Share", systemImage: "square.and.arrow.up").labelStyle(.iconOnly)
                .frame(width: actionWidth, height: 44)
                .contentShape(.rect)
        }
    }

    private var deleteAction: some View {
        action("Delete", "trash", role: .destructive) { isConfirmingDelete = true }
            .accessibilityIdentifier("highlight.delete")
    }

    private func action(_ title: LocalizedStringKey, _ image: String, role: ButtonRole? = nil,
                        perform: @escaping () -> Void) -> some View {
        Button(role: role, action: perform) {
            Label(title, systemImage: image).labelStyle(.iconOnly)
                .frame(width: actionWidth, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
    }
}

struct NoteEditor: View {
    @Bindable var annotation: Annotation
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var text: String
    @State private var isConfirmingDiscard = false

    init(annotation: Annotation) {
        self.annotation = annotation
        _text = State(initialValue: annotation.note ?? "")
    }

    /// The note as it would be saved: trimmed, and nil when empty.
    private var editedNote: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Unsaved edits keep the sheet from being swiped away, so a note is never lost by accident.
    private var hasChanges: Bool { editedNote != annotation.note }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2).fill(annotation.color.color).frame(width: 4)
                    Text(annotation.text).font(.callout).foregroundStyle(.secondary).lineLimit(6)
                }
                TextEditor(text: $text)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .accessibilityIdentifier("note.editor")
            }
            .padding()
            .navigationTitle("Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) {
                        if hasChanges { isConfirmingDiscard = true } else { dismiss() }
                    }
                    .accessibilityIdentifier("note.cancel")
                    .confirmationDialog("Discard Note?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
                        Button("Discard Changes", role: .destructive) { dismiss() }
                        Button("Keep Editing", role: .cancel) {}
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        annotation.note = editedNote
                        dismiss()
                    }
                    .accessibilityIdentifier("note.save")
                }
            }
        }
        .onAppear { focused = true }
        .interactiveDismissDisabled(hasChanges)
        .presentationDetents([.medium, .large])
    }
}
