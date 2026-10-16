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

/// Listening options: voice mode, voices, speed, Studio preparation, and what gets read.
struct ListenSettingsView: View {
    @Bindable var session: ListeningSession

    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryStore.self) private var library

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Voice", selection: $session.preferences.mode) {
                        ForEach(ListeningMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .accessibilityIdentifier("listen.mode")
                } footer: {
                    Text(session.preferences.mode == .instant
                         ? "Instant uses the voices on your device and starts right away."
                         : "Studio uses a natural neural voice that runs on your device. Prepare a book ahead of time for the best experience.")
                }

                if session.preferences.mode == .instant {
                    SystemVoiceSection(session: session)
                } else {
                    StudioSection(session: session)
                }

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
                    Text("Page numbers, note markers, running heads, and front and back matter like the copyright page and index are left out.")
                }
            }
            .navigationTitle("Listen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", systemImage: "xmark") { dismiss() }
                        .accessibilityIdentifier("listen.done")
                }
            }
        }
        .presentationDetents([.large])
    }
}

private struct SystemVoiceSection: View {
    @Bindable var session: ListeningSession

    private var voices: [AVSpeechSynthesisVoice] { SystemVoices.voices(for: session.language) }

    var body: some View {
        Section {
            Picker("Voice", selection: Binding(
                get: { SystemVoices.voice(for: session.language, preferred: session.preferences.systemVoice(for: session.language))?.identifier ?? "" },
                set: { session.preferences.setSystemVoice($0, for: session.language) })) {
                ForEach(voices, id: \.identifier) { voice in
                    Text("\(voice.name) · \(Self.qualityName(voice.quality))").tag(voice.identifier)
                }
            }
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier("listen.systemVoice")
        } footer: {
            if SystemVoices.hasOnlyCompactVoices(for: session.language) {
                Text("For a more natural voice, download an Enhanced or Premium voice in Settings › Accessibility › Spoken Content › Voices.")
            }
        }
    }

    static func qualityName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: String(localized: "Premium")
        case .enhanced: String(localized: "Enhanced")
        default: String(localized: "Basic")
        }
    }
}

private struct StudioSection: View {
    @Bindable var session: ListeningSession

    @Environment(LibraryStore.self) private var library
    private var store: NeuralVoiceStore { .shared }

    var body: some View {
        if !session.supportsStudio {
            Section {
                Label("Studio voices read English only, so this book uses Instant.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        } else {
            Section {
                VoiceModelRow()
                if store.isReady {
                    Picker("Voice", selection: $session.preferences.neuralVoiceID) {
                        ForEach(NeuralVoiceCatalog.voices) { voice in
                            Text(voice.name).tag(voice.id)
                        }
                    }
                    .accessibilityIdentifier("listen.studioVoice")
                }
            } footer: {
                Text("Studio voices are Kokoro, an open model that runs entirely on this device. Nothing you read is sent anywhere.")
            }
            .onChange(of: store.state) { _, state in
                if state == .ready { session.refreshMode() }
            }
            if store.isReady {
                Section {
                    PrepareAudiobookRow(
                        bookID: session.book.id, title: session.book.title, author: session.book.author,
                        voice: session.preferences.neuralVoice, storage: library.storage)
                } footer: {
                    Text("Preparing renders the whole book with this voice, so listening is instant and uses less battery. It continues in the background, and you can listen while it works.")
                }
            }
        }
    }
}

/// Downloads or shows the state of the Studio voice model.
struct VoiceModelRow: View {
    private var store: NeuralVoiceStore { .shared }

    var body: some View {
        switch store.state {
        case .notDownloaded:
            Button {
                store.download()
            } label: {
                HStack {
                    Label("Download Studio Voice", systemImage: "arrow.down.circle")
                    Spacer()
                    Text(ByteCountFormatStyle().format(NeuralVoiceCatalog.model.size)).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("listen.downloadModel")
        case .downloading(let fraction):
            HStack {
                ProgressView(value: fraction) {
                    Text("Downloading Studio Voice")
                } currentValueLabel: {
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                }
                Button("Cancel", systemImage: "xmark.circle.fill") { store.cancelDownload() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Label("Studio Voice Installed", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).font(.footnote).foregroundStyle(.red)
                Button("Try Again") { store.download() }
            }
        }
    }
}

/// Starts, shows, and pauses preparing a book's Studio audiobook.
struct PrepareAudiobookRow: View {
    let bookID: UUID
    let title: String
    let author: String
    let voice: NeuralVoiceCatalog.Voice
    let storage: BookStorage

    private var preparer: AudiobookPreparer { .shared }
    @State private var preparedSize: Int64 = 0

    var body: some View {
        let job = preparer.job(for: bookID)
        VStack(alignment: .leading, spacing: 8) {
            switch job?.phase {
            case .reading?, .rendering?, .queued?:
                ProgressView(value: job?.fraction ?? 0) {
                    Text(job?.phase == .queued ? "Waiting to Prepare" : job?.phase == .reading ? "Reading Book" : "Preparing Audiobook")
                } currentValueLabel: {
                    Text(Self.detail(job))
                }
                Button("Pause", systemImage: "pause.circle") { preparer.pause(bookID: bookID) }
                    .accessibilityIdentifier("prepare.pause")
            case .finished?:
                Label("Audiobook Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                storageLine
            case .failed(let message)?:
                Text(message).font(.footnote).foregroundStyle(.red)
                startButton(String(localized: "Try Again"))
            case .paused?:
                ProgressView(value: job?.fraction ?? 0) { Text("Paused") }
                startButton(String(localized: "Resume Preparing"))
            case nil:
                startButton(String(localized: "Prepare Audiobook"))
                if preparedSize > 0 { storageLine }
            }
        }
        .task(id: job?.phase) { preparedSize = AudiobookStore.size(bookFolder: storage.folder(for: bookID)) }
    }

    private var storageLine: some View {
        HStack {
            Text("Uses \(ByteCountFormatStyle().format(preparedSize))").font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button("Delete", role: .destructive) {
                preparer.cancel(bookID: bookID)
                AudiobookStore.remove(bookFolder: storage.folder(for: bookID))
                preparedSize = 0
            }
            .font(.footnote)
        }
    }

    private func startButton(_ title: String) -> some View {
        Button {
            preparer.prepare(bookID: bookID, title: self.title, author: author, voice: voice, storage: storage)
        } label: {
            Label(title, systemImage: "waveform")
        }
        .accessibilityIdentifier("prepare.start")
    }

    private static func detail(_ job: AudiobookPreparer.Job?) -> String {
        guard let job else { return "" }
        let percent = job.fraction.formatted(.percent.precision(.fractionLength(0)))
        guard let remaining = job.remaining else { return percent }
        let duration = Duration.seconds(remaining).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return String(localized: "\(percent) · about \(duration) left")
    }
}

/// Every document in the book, whether it's read, and what was left out, with switches to change it.
struct SpeechContentsView: View {
    let session: ListeningSession

    @State private var chapters: [SpeechChapter] = []
    @State private var overrides = SpeechOverrides()
    @State private var isLoading = true

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            ForEach(chapters, id: \.spineIndex) { chapter in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(
                        get: { isRead(chapter) },
                        set: { included in
                            Task {
                                await session.provider.setIncluded(chapter.spineIndex, included)
                                overrides = await session.provider.overrides
                            }
                        })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(for: chapter)).lineLimit(2)
                            Text(summary(for: chapter)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(chapter.utterances.isEmpty)
                }
            }
        }
        .navigationTitle("What's Read Aloud")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let script = await session.provider.script()
            overrides = await session.provider.overrides
            chapters = script.chapters
            isLoading = false
        }
    }

    private func isRead(_ chapter: SpeechChapter) -> Bool {
        if overrides.excluded.contains(chapter.spineIndex) { return false }
        if overrides.included.contains(chapter.spineIndex) { return true }
        return !chapter.isSkipped && !chapter.utterances.isEmpty
    }

    private func title(for chapter: SpeechChapter) -> String {
        chapter.title ?? chapter.utterances.first.map { String($0.text.prefix(60)) } ?? String(localized: "Section \(chapter.spineIndex + 1)")
    }

    private func summary(for chapter: SpeechChapter) -> String {
        var parts: [String] = []
        if let reason = chapter.skipReason, !overrides.included.contains(chapter.spineIndex) {
            parts.append(String(localized: "Skipped: \(reason.title)"))
        } else if !chapter.utterances.isEmpty {
            let minutes = max(1, Int((Double(chapter.characterCount) / 15 / 60).rounded()))
            parts.append(String(localized: "About \(minutes) min"))
        }
        let left = Dictionary(grouping: chapter.omissions, by: \.reason).map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
        if !left.isEmpty {
            parts.append(String(localized: "Leaves out ") + left.prefix(3).map { "\($0.1) × \($0.0.title.lowercased())" }.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}
