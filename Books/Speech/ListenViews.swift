import AVFoundation
import SwiftUI

/// Playback controls shown in the reader while listening.
struct ListenBar: View {
    let session: ListeningSession
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if !session.isFollowing {
                Button {
                    session.returnToNarration()
                } label: {
                    Label("Return to Narration", systemImage: "arrow.uturn.backward")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("listen.return")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            HStack(spacing: 4) {
                control("gobackward", label: "Previous Sentence", id: "listen.back") { session.skip(by: -1) }
                Button {
                    session.togglePlayback()
                } label: {
                    ZStack {
                        if session.state == .loading || session.isWaiting {
                            ProgressView()
                        } else {
                            Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .frame(width: 52, height: 48)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(session.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("listen.playPause")
                control("goforward", label: "Next Sentence", id: "listen.forward") { session.skip(by: 1) }
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
                        .frame(width: 48, height: 44)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Speed")
                .accessibilityIdentifier("listen.speed")
                control("ellipsis", label: "Listening Options", id: "listen.options", action: openSettings)
                control("xmark", label: "Stop Listening", id: "listen.stop") { session.stop() }
            }
            .padding(.horizontal, 8)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .animation(.smooth(duration: 0.25), value: session.isFollowing)
    }

    private func control(_ systemImage: String, label: LocalizedStringKey, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    static func speedLabel(_ speed: Double) -> String {
        speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}

/// A play/pause button that stays on the page while listening and the chrome is hidden.
struct ListenPill: View {
    let session: ListeningSession

    var body: some View {
        Button {
            session.togglePlayback()
        } label: {
            ZStack {
                if session.state == .loading || session.isWaiting {
                    ProgressView()
                } else {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(session.isPlaying ? "Pause" : "Play")
        .accessibilityIdentifier("listen.pill")
    }
}

/// Listening options: the voice, speed, following along, and what gets read.
struct ListenSettingsView: View {
    @Bindable var session: ListeningSession

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if session.supportsNaturalVoices {
                    NaturalVoicesSection(session: session)
                }
                SystemVoicesSection(session: session)

                Section("Playback") {
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
            .navigationTitle("Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", systemImage: "xmark") { dismiss() }
                        .accessibilityIdentifier("listen.done")
                }
            }
        }
        .presentationDetents([.large])
        .onAppear { session.prewarm() }
        .onDisappear { VoicePreview.shared.stop() }
    }
}

/// A row in the voice list: a preview button, the name, and a checkmark when chosen.
private struct VoiceRow: View {
    let name: String
    let detail: String
    let isSelected: Bool
    let isPreviewing: Bool
    let id: String
    let preview: () -> Void
    let select: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: preview) {
                Image(systemName: isPreviewing ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isPreviewing ? "Stop Sample" : "Play Sample of \(name)")
            .accessibilityIdentifier("voice.preview.\(id)")
            Button(action: select) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).foregroundStyle(.primary)
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("voice.select.\(id)")
        }
    }
}

private struct NaturalVoicesSection: View {
    @Bindable var session: ListeningSession
    private var store: NeuralVoiceStore { .shared }
    private var preview: VoicePreview { .shared }

    var body: some View {
        Section {
            if !store.isReady { VoiceModelRow() }
            ForEach(NeuralVoiceCatalog.voices) { voice in
                VoiceRow(
                    name: voice.name, detail: voice.description,
                    isSelected: session.resolvedVoice == .natural(voice),
                    isPreviewing: preview.isPlaying(voice.id), id: voice.id,
                    preview: {
                        session.pause()
                        preview.toggle(voice)
                    },
                    select: {
                        session.preferences.voice = .natural(voice.id)
                        if !store.isReady { store.download() }
                    })
            }
        } header: {
            Text("Natural Voices")
        } footer: {
            Text("Natural voices run entirely on this device, so nothing you read is sent anywhere. They read English books.")
        }
        .onChange(of: store.state) { _, state in
            if state == .ready { session.voiceDidChange() }
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
                    Text(ByteCountFormatStyle().format(NeuralVoiceCatalog.downloadSize)).foregroundStyle(.secondary)
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

    /// "Leaves out 12 page number, 3 note reference": the most common omissions.
    static func omissionSummary(_ omissions: [SpeechOmission]) -> String? {
        var counts: [SpeechSkipReason: Int] = [:]
        for omission in omissions { counts[omission.reason, default: 0] += 1 }
        let top: [(SpeechSkipReason, Int)] = counts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key.rawValue < rhs.key.rawValue : lhs.value > rhs.value
        }.map { ($0.key, $0.value) }
        guard !top.isEmpty else { return nil }
        let items: [String] = top.prefix(3).map { reason, count in "\(count) \(reason.title.lowercased())" }
        return String(localized: "Leaves out ") + items.joined(separator: ", ")
    }
}
