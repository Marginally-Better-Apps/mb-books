import AVFoundation
import SwiftUI

/// Playback controls, docked in the reader's bottom row beside the menu button while listening.
/// The reader's headphones button opens the listening options.
struct ListenBar: View {
    let session: ListeningSession

    // Sizes grow with Dynamic Type, but only so far: the bar must still fit beside the menu button on a
    // 375 pt wide iPhone, and stay inside the page's bottom margin.
    @ScaledMetric(relativeTo: .body) private var scaledGlyph: CGFloat = 17
    @ScaledMetric(relativeTo: .body) private var scaledPlayGlyph: CGFloat = 22
    @ScaledMetric(relativeTo: .body) private var scaledControl: CGFloat = 44

    private var glyph: CGFloat { min(scaledGlyph, 21) }
    private var playGlyph: CGFloat { min(scaledPlayGlyph, 26) }
    private var side: CGFloat { min(scaledControl, 46) }

    var body: some View {
        HStack(spacing: 4) {
            control("backward.fill", label: "Previous Sentence", id: "listen.back") { session.skip(by: -1) }
            Button {
                session.togglePlayback()
            } label: {
                ZStack {
                    if session.state == .loading || session.isWaiting {
                        ProgressView()
                    } else {
                        Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: playGlyph, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: side + 8, height: side + 4)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(session.isPlaying ? "Pause" : "Play")
            .accessibilityShowsLargeContentViewer {
                Label(session.isPlaying ? "Pause" : "Play", systemImage: session.isPlaying ? "pause.fill" : "play.fill")
            }
            .accessibilityIdentifier("listen.playPause")
            control("forward.fill", label: "Next Sentence", id: "listen.forward") { session.skip(by: 1) }
            Menu {
                Picker("Speed", selection: Binding(
                    get: { session.preferences.speed }, set: { session.preferences.speed = $0 })) {
                    ForEach(ListeningPreferences.speeds, id: \.self) { speed in
                        Text(Self.speedLabel(speed)).tag(speed)
                    }
                }
            } label: {
                Text(Self.speedLabel(session.preferences.speed))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: side + 4, height: side)
                    .contentShape(.rect)
            }
            // Primary like the buttons beside it, rather than the accent a menu takes by default.
            .tint(.primary)
            .accessibilityLabel("Speed")
            .accessibilityShowsLargeContentViewer {
                Label("Speed \(Self.speedLabel(session.preferences.speed))", systemImage: "gauge.with.dots.needle.67percent")
            }
            .accessibilityIdentifier("listen.speed")
            // Not an X: that's Close Book, just above.
            control("stop.fill", label: "Stop Listening", id: "listen.stop") { session.stop() }
        }
        .padding(.horizontal, 8)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func control(_ systemImage: String, label: LocalizedStringKey, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: glyph, weight: .medium))
                .frame(width: side, height: side)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        // The glyphs stop growing with Dynamic Type; the large content viewer shows them bigger instead.
        .accessibilityShowsLargeContentViewer { Label(label, systemImage: systemImage) }
        .accessibilityIdentifier(id)
    }

    static func speedLabel(_ speed: Double) -> String {
        speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}

/// A play/pause button that stays on the page while listening and the chrome is hidden.
struct ListenPill: View {
    let session: ListeningSession

    @ScaledMetric(relativeTo: .body) private var glyph: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 44

    var body: some View {
        Button {
            session.togglePlayback()
        } label: {
            ZStack {
                if session.state == .loading || session.isWaiting {
                    ProgressView()
                } else {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: min(glyph, 20), weight: .semibold))
                }
            }
            // Capped to stay inside the page's bottom margin.
            .frame(width: min(side, 52), height: min(side, 52))
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(session.isPlaying ? "Pause" : "Play")
        .accessibilityShowsLargeContentViewer {
            Label(session.isPlaying ? "Pause" : "Play", systemImage: session.isPlaying ? "pause.fill" : "play.fill")
        }
        .accessibilityIdentifier("listen.pill")
    }
}

/// Listening options: the voice, speed, following along, and what gets read.
struct ListenSettingsView: View {
    @Bindable var session: ListeningSession

    @Environment(\.dismiss) private var dismiss
    /// Opens at medium so the page being read stays in view; the long voice list takes the full height.
    @State private var detent = PresentationDetent.medium

    var body: some View {
        NavigationStack {
            Form {
                Section("Playback") {
                    NavigationLink {
                        VoicePicker(session: session)
                            .onAppear { detent = .large }
                    } label: {
                        LabeledContent("Voice", value: voiceName)
                    }
                    .accessibilityIdentifier("listen.voice")
                    Picker("Speed", selection: $session.preferences.speed) {
                        ForEach(ListeningPreferences.speeds, id: \.self) { speed in
                            Text(ListenBar.speedLabel(speed)).tag(speed)
                        }
                    }
                    Toggle("Follow Along", isOn: $session.preferences.followsAlong)
                        .accessibilityIdentifier("listen.follow")
                }

                Section {
                    NavigationLink {
                        SpeechContentsView(session: session)
                    } label: {
                        Label("What's Read Aloud", systemImage: "text.badge.checkmark")
                    }
                    .accessibilityIdentifier("listen.contents")
                } footer: {
                    Text("Page numbers, notes, captions, code listings, and front and back matter like the copyright page and index are left out.")
                }
            }
            .navigationTitle("Listening")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier("listen.done")
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .onAppear { session.prewarm() }
        .onDisappear { VoicePreview.shared.stop() }
    }

    /// The voice that reads now: a natural voice once they're installed, otherwise the Apple voice. While they
    /// download, the chosen natural voice, so the choice reads as kept.
    private var voiceName: String {
        if case .downloading = NeuralVoiceStore.shared.state, session.supportsNaturalVoices,
           let natural = session.preferences.naturalVoice {
            return String(localized: "\(natural.name) (after download)")
        }
        return switch session.resolvedVoice {
        case .natural(let voice): voice.name
        case .system(let identifier):
            SystemVoices.voice(for: session.language, preferred: identifier)?.name ?? String(localized: "Default")
        }
    }
}

/// Every voice that can read the book, with samples to hear before choosing.
private struct VoicePicker: View {
    @Bindable var session: ListeningSession

    /// Until the natural voices are installed, the Apple voices come first: they're the ones that read right now.
    /// Decided when the list opens, so finishing a download doesn't reorder it under the reader's finger.
    @State private var listsNaturalVoicesFirst = NeuralVoiceStore.shared.isReady

    var body: some View {
        Form {
            if listsNaturalVoicesFirst {
                if session.supportsNaturalVoices { NaturalVoicesSection(session: session) }
                SystemVoicesSection(session: session)
            } else {
                SystemVoicesSection(session: session)
                if session.supportsNaturalVoices { NaturalVoicesSection(session: session) }
            }
        }
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: voiceSelection)
        .onDisappear { VoicePreview.shared.stop() }
    }

    /// The chosen natural voice and Apple voice, so picking either gives a tap of feedback.
    private var voiceSelection: [String?] {
        let natural: String? = if case .natural(let id) = session.preferences.voice { id } else { nil }
        return [natural, session.preferences.systemVoice(for: session.language)]
    }
}

/// A row in the voice list: a preview button, the name, and a checkmark when chosen. A voice that needs the natural
/// voices downloaded first shows nothing extra; the section's download row and footer already say so.
private struct VoiceRow: View {
    enum Status { case available, needsDownload, pending }

    let name: String
    let detail: String
    let isSelected: Bool
    var status = Status.available
    let isPreviewing: Bool
    let id: String
    let preview: () -> Void
    let select: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: preview) {
                Image(systemName: isPreviewing ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .padding(.leading, -8)
            .accessibilityLabel(isPreviewing ? "Stop Sample" : "Play Sample of \(name)")
            .accessibilityIdentifier("voice.preview.\(id)")
            Button(action: select) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).foregroundStyle(.primary)
                        Text(status == .pending ? String(localized: "Will be used after download") : detail)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    switch status {
                    case .needsDownload:
                        EmptyView()
                    case .pending:
                        Image(systemName: "clock").foregroundStyle(.secondary)
                    case .available:
                        if isSelected {
                            Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
                        }
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityHint(status == .needsDownload ? Text("Downloads the natural voices") : Text(verbatim: ""))
            .accessibilityIdentifier("voice.select.\(id)")
        }
    }
}

private struct NaturalVoicesSection: View {
    @Bindable var session: ListeningSession
    private var store: NeuralVoiceStore { .shared }
    private var preview: VoicePreview { .shared }

    /// The voice tapped before the natural voices are downloaded, while asking to download them.
    @State private var downloadCandidate: NeuralVoiceCatalog.Voice?

    var body: some View {
        Section {
            if !store.isReady { VoiceModelRow() }
            ForEach(NeuralVoiceCatalog.voices) { voice in
                VoiceRow(
                    name: voice.name, detail: voice.description,
                    isSelected: session.resolvedVoice == .natural(voice) || status(of: voice) == .pending,
                    status: status(of: voice),
                    isPreviewing: preview.isPlaying(voice.id), id: voice.id,
                    preview: {
                        session.pause()
                        preview.toggle(voice)
                    },
                    select: {
                        // Downloading is a choice of its own: ask first, and never start reading.
                        if store.isReady || store.isDownloading {
                            session.preferences.voice = .natural(voice.id)
                        } else {
                            downloadCandidate = voice
                        }
                    })
            }
        } header: {
            Text("Natural Voices")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if !store.isReady && !store.isDownloading {
                    Text("Play a sample to hear any voice. Natural voices are a one-time download.")
                }
                Text("Natural voices run entirely on this device, so nothing you read is sent anywhere. They read English books.")
            }
        }
        .confirmationDialog(
            "Download Natural Voices?", isPresented: Binding(
                get: { downloadCandidate != nil }, set: { if !$0 { downloadCandidate = nil } }),
            titleVisibility: .visible, presenting: downloadCandidate
        ) { voice in
            Button("Download") {
                // The chosen voice reads once the download finishes; until then the Apple voice stands in.
                session.preferences.voice = .natural(voice.id)
                store.download()
            }
            .accessibilityIdentifier("listen.confirmDownload")
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The natural voices are \(ByteCountFormatStyle().format(NeuralVoiceCatalog.downloadSize)) and run on this device. Wi-Fi is recommended.")
        }
        .onChange(of: store.state) { _, state in
            if state == .ready { session.voiceDidChange() }
        }
    }

    private func status(of voice: NeuralVoiceCatalog.Voice) -> VoiceRow.Status {
        switch store.state {
        case .ready: .available
        case .downloading: session.preferences.naturalVoice == voice ? .pending : .available
        case .notDownloaded, .failed: .needsDownload
        }
    }
}

private struct SystemVoicesSection: View {
    @Bindable var session: ListeningSession
    private var preview: VoicePreview { .shared }

    private var voices: [AVSpeechSynthesisVoice] { SystemVoices.voices(for: session.language) }

    /// The Apple voice that reads, checked even when it's standing in for natural voices not yet downloaded.
    private var selectedIdentifier: String? {
        guard case .system(let identifier) = session.resolvedVoice else { return nil }
        return SystemVoices.voice(for: session.language, preferred: identifier)?.identifier
    }

    var body: some View {
        Section {
            ForEach(voices, id: \.identifier) { voice in
                VoiceRow(
                    name: voice.name, detail: Self.detail(voice),
                    isSelected: selectedIdentifier == voice.identifier,
                    isPreviewing: preview.isPlaying(voice.identifier), id: voice.identifier,
                    preview: {
                        session.pause()
                        preview.toggle(voice)
                    },
                    select: {
                        session.preferences.setSystemVoice(voice.identifier, for: session.language)
                        session.preferences.voice = .system
                    })
            }
        } header: {
            Text("Apple Voices")
        } footer: {
            if SystemVoices.hasOnlyCompactVoices(for: session.language) {
                Text("For more natural Apple voices, download Enhanced or Premium voices in Settings › Accessibility › Spoken Content › Voices.")
            }
        }
    }

    static func detail(_ voice: AVSpeechSynthesisVoice) -> String {
        let language = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
        let quality = switch voice.quality {
        case .premium: String(localized: "Premium")
        case .enhanced: String(localized: "Enhanced")
        default: String(localized: "Basic")
        }
        return "\(language) · \(quality)"
    }
}

/// Downloads the natural voices, or shows that they're ready.
struct VoiceModelRow: View {
    private var store: NeuralVoiceStore { .shared }

    var body: some View {
        switch store.state {
        case .notDownloaded:
            Button {
                store.download()
            } label: {
                HStack {
                    Label("Download Natural Voices", systemImage: "arrow.down.circle")
                    Spacer()
                    // Plain secondary here would be the button's dimmed tint, too faint to read.
                    Text(ByteCountFormatStyle().format(NeuralVoiceCatalog.downloadSize)).foregroundStyle(Color(.secondaryLabel))
                }
            }
            .accessibilityIdentifier("listen.downloadModel")
        case .downloading(let fraction):
            HStack {
                ProgressView(value: fraction) {
                    Text("Downloading Natural Voices")
                } currentValueLabel: {
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                }
                Button("Cancel", systemImage: "xmark.circle.fill") { store.cancelDownload() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Label("Natural Voices Installed", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).font(.footnote).foregroundStyle(.red)
                Button("Try Again") { store.download() }
            }
        }
    }
}

/// Every part of the book with text, named from its table of contents, whether it's read, and what was left out,
/// with switches to change it.
struct SpeechContentsView: View {
    let session: ListeningSession

    @State private var sections: [SpeechSection] = []
    @State private var isLoading = true

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            ForEach(sections) { section in
                Toggle(isOn: Binding(
                    get: { section.isRead },
                    set: { included in
                        Task {
                            await session.provider.setIncluded(section.spineIndex, included)
                            await load()
                        }
                    })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.title).lineLimit(2)
                            .foregroundStyle(section.isRead ? .primary : .secondary)
                        Text(section.summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("contents.\(section.spineIndex)")
            }
        }
        .navigationTitle("What's Read Aloud")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        let script = await session.provider.script()
        let overrides = await session.provider.overrides
        sections = SpeechSection.sections(script: script, publication: session.provider.publication, overrides: overrides)
        isLoading = false
    }
}

/// A row of "What's Read Aloud": one document of the book that has text.
nonisolated struct SpeechSection: Identifiable, Equatable, Sendable {
    let spineIndex: Int
    let title: String
    let isRead: Bool
    let summary: String

    var id: Int { spineIndex }

    /// Sections in reading order, titled from the table of contents. Documents with no text (covers, image
    /// pages) are left out, since there's nothing to choose.
    static func sections(script: SpeechScript, publication: Publication, overrides: SpeechOverrides) -> [SpeechSection] {
        var tocTitles: [String: [String]] = [:]
        for (point, _) in publication.flattenedTableOfContents {
            guard let path = point.path, !point.title.isEmpty else { continue }
            tocTitles[path, default: []].append(point.title)
        }
        return script.chapters.compactMap { chapter in
            guard !chapter.utterances.isEmpty, publication.spine.indices.contains(chapter.spineIndex) else { return nil }
            let path = publication.spine[chapter.spineIndex].item.path
            let titles = chapterTitles(tocTitles[path] ?? [])
            let title: String
            if let first = titles.first {
                // A document holding several chapters, as many converted books have: name the span.
                title = titles.count > 2 ? "\(first) – \(titles[titles.count - 1])" : titles.joined(separator: ", ")
            } else if let heading = chapter.title, !heading.isEmpty {
                title = heading
            } else if let reason = chapter.skipReason {
                title = reason.title
            } else {
                title = String(chapter.utterances[0].text.prefix(60))
            }
            let isRead: Bool
            if overrides.excluded.contains(chapter.spineIndex) {
                isRead = false
            } else if overrides.included.contains(chapter.spineIndex) {
                isRead = true
            } else {
                isRead = !chapter.isSkipped
            }
            var parts: [String] = []
            if !isRead {
                parts.append(chapter.skipReason.map { String(localized: "Skipped: \($0.title)") } ?? String(localized: "Skipped"))
            } else {
                let minutes = max(1, Int((Double(chapter.characterCount) / 15 / 60).rounded()))
                parts.append(minutes >= 60
                    ? Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
                    : String(localized: "\(minutes) min"))
            }
            if let omitted = omissionSummary(chapter.omissions) { parts.append(omitted) }
            return SpeechSection(spineIndex: chapter.spineIndex, title: title, isRead: isRead, summary: parts.joined(separator: " · "))
        }
    }

    private static let chapterPattern = try! NSRegularExpression(
        // swiftlint:disable:next line_length
        pattern: #"^(?:chapter|part|book|volume|letter|act|section|stave|canto|preface|prologue|epilogue|introduction|appendix|afterword|foreword)\b|^[ivxlcdm]+\.?$|^\d+\.?$"#,
        options: [.caseInsensitive])

    /// Table of contents titles for one document, tidied: when some look like chapters ("CHAPTER XI.", "Preface"),
    /// only those are kept, since converted books also list illustrations and captions there.
    static func chapterTitles(_ titles: [String]) -> [String] {
        let cleaned = titles.map(tidy).filter { !$0.isEmpty }
        let chapters = cleaned.filter {
            chapterPattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
        }
        return chapters.isEmpty ? cleaned : chapters
    }

    /// "CHAPTER XI." becomes "Chapter XI": no shouting, no trailing period.
    static func tidy(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, ".,;:".contains(last) { text.removeLast() }
        let letters = text.filter(\.isLetter)
        guard letters.count > 3, letters == letters.uppercased() else { return text }
        return text.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            // Keep roman numerals as they are.
            if word.allSatisfy({ "IVXLCDM".contains($0) }) { return String(word) }
            return word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    /// "Skips 12 page numbers and 3 note references": the most common omissions.
    static func omissionSummary(_ omissions: [SpeechOmission]) -> String? {
        var counts: [SpeechSkipReason: Int] = [:]
        for omission in omissions { counts[omission.reason, default: 0] += 1 }
        let top: [(SpeechSkipReason, Int)] = counts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key.rawValue < rhs.key.rawValue : lhs.value > rhs.value
        }.map { ($0.key, $0.value) }
        guard !top.isEmpty else { return nil }
        let items = top.prefix(3).map { reason, count in countedOmission(reason, count) }
        return String(localized: "Skips \(items.formatted(.list(type: .and)))")
    }

    /// "1 note reference", "3 note references": a count with its noun agreeing, through automatic grammar agreement.
    static func countedOmission(_ reason: SpeechSkipReason, _ count: Int) -> String {
        let phrase: AttributedString = switch reason {
        case .auxiliary: AttributedString(localized: "^[\(count) supplementary passage](inflect: true)")
        case .cover: AttributedString(localized: "^[\(count) cover](inflect: true)")
        case .titlePage: AttributedString(localized: "^[\(count) title page](inflect: true)")
        case .copyright: AttributedString(localized: "^[\(count) copyright notice](inflect: true)")
        case .tableOfContents: AttributedString(localized: "^[\(count) table of contents](inflect: true)")
        case .index: AttributedString(localized: "^[\(count) index](inflect: true)")
        case .notes: AttributedString(localized: "^[\(count) note](inflect: true)")
        case .bibliography: AttributedString(localized: "^[\(count) bibliography](inflect: true)")
        case .colophon: AttributedString(localized: "^[\(count) colophon](inflect: true)")
        case .boilerplate: AttributedString(localized: "^[\(count) passage of license text](inflect: true)")
        case .pageNumber: AttributedString(localized: "^[\(count) page number](inflect: true)")
        case .noteReference: AttributedString(localized: "^[\(count) note reference](inflect: true)")
        case .hidden: AttributedString(localized: "^[\(count) passage of hidden text](inflect: true)")
        case .navigation: AttributedString(localized: "^[\(count) navigation list](inflect: true)")
        case .pullQuote: AttributedString(localized: "^[\(count) pull quote](inflect: true)")
        case .runningHead: AttributedString(localized: "^[\(count) running head](inflect: true)")
        case .annotation: AttributedString(localized: "^[\(count) pronunciation guide](inflect: true)")
        case .illustration: AttributedString(localized: "^[\(count) illustration caption](inflect: true)")
        case .code: AttributedString(localized: "^[\(count) code listing](inflect: true)")
        case .empty: AttributedString(localized: "^[\(count) empty passage](inflect: true)")
        }
        return String(phrase.characters)
    }
}
