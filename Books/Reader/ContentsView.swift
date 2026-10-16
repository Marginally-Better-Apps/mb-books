import SwiftData
import SwiftUI

/// Contents, bookmarks, and highlights, with a whole-book progress scrubber.
struct ContentsView: View {
    @Bindable var model: ReaderModel

    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.contents
    @State private var scrubValue: Double?

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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", systemImage: "xmark") { dismiss() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDragIndicator(.visible)
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
                    Text("\(Int(((scrubValue ?? model.location.totalProgression) * 100).rounded()))%")
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
            }
            .listStyle(.plain)
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
                empty.listRowSeparator(.hidden)
            }
            ForEach(annotations) { annotation in
                Button {
                    model.go(to: annotation.locator)
                    dismiss()
                } label: {
                    AnnotationRow(annotation: annotation)
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) { model.delete(annotation) }
                }
                .contextMenu {
                    if annotation.kind == .highlight {
                        Button("Edit Note", systemImage: "note.text") {
                            dismiss()
                            model.editingNote = annotation
                        }
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = annotation.text }
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) { model.delete(annotation) }
                }
            }
        }
        .listStyle(.plain)
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

/// The palette shown after highlighting or when tapping an existing highlight.
struct HighlightMenu: View {
    let model: ReaderModel
    let annotation: Annotation

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                ForEach(HighlightColor.allCases) { color in
                    Button {
                        model.setColor(color, for: annotation)
                    } label: {
                        ZStack {
                            if color == .underline {
                                Circle().strokeBorder(.secondary, lineWidth: 1)
                                Text("U").font(.callout.weight(.bold)).underline(color: .red)
                            } else {
                                Circle().fill(color.color)
                            }
                            if annotation.color == color {
                                Circle().strokeBorder(.primary, lineWidth: 2.5).padding(-4)
                            }
                        }
                        .frame(width: 28, height: 28)
                    }
                    .accessibilityLabel(Text(color.name))
                }
            }
            HStack(spacing: 0) {
                action("Note", "note.text") {
                    model.popover = nil
                    model.editingNote = annotation
                }
                action("Copy", "doc.on.doc") {
                    UIPasteboard.general.string = annotation.text
                    model.popover = nil
                }
                ShareLink(item: "“\(annotation.text)”\n— \(model.book.title), \(model.book.author)") {
                    Label("Share", systemImage: "square.and.arrow.up").labelStyle(.iconOnly)
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                action("Delete", "trash", role: .destructive) { model.delete(annotation) }
            }
            .font(.title3)
        }
        .padding(14)
        .frame(width: 280)
    }

    private func action(_ title: LocalizedStringKey, _ image: String, role: ButtonRole? = nil,
                        perform: @escaping () -> Void) -> some View {
        Button(role: role, action: perform) {
            Label(title, systemImage: image).labelStyle(.iconOnly).frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
    }
}

struct NoteEditor: View {
    @Bindable var annotation: Annotation
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var text = ""

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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        annotation.note = trimmed.isEmpty ? nil : trimmed
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            text = annotation.note ?? ""
            focused = true
        }
        .presentationDetents([.medium, .large])
    }
}
