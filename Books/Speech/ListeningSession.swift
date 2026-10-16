import AVFoundation
import MediaPlayer
import Observation
import OSLog
import UIKit

/// Where the reader shows the sentence being read, reported by `reader.js`.
struct SpeechMark: Decodable, Equatable {
    var startPage: Int?
    var endPage: Int?
    /// Where a sentence running onto the next page crosses over, as a text offset.
    var breakOffset: Int?
    var currentPage: Int?
    /// Scroll mode: whether the sentence is on screen, and where to scroll to show it.
    var visible: Bool?
    var y: Double?
}

/// What the reader's rendering layer does for listening. Implemented by `ReaderViewController`.
@MainActor
protocol SpeechFollowing: AnyObject {
    /// The text offset of the first character on screen, in the current chapter.
    func visibleTextOffset() async -> (spineIndex: Int, offset: Int?)?
    /// The text offset where the selection starts.
    func selectionTextOffset() async -> (spineIndex: Int, offset: Int)?
    /// Highlights a sentence (and word) if its chapter is showing. With `reveal`, opens the chapter at it first.
    func markSpeech(spineIndex: Int, start: Int, end: Int, word: Range<Int>?, reveal: Bool) async -> SpeechMark?
    /// Shows a page of the current chapter, turning to it if it's the next one.
    func showSpeechPage(_ page: Int)
    /// Scrolls the current chapter so a sentence is in view.
    func scrollSpeech(to y: Double)
    /// Shows a spine item without a text position, for pages read with OCR.
    func showSpineItem(_ spineIndex: Int)
    func clearSpeech()
}

/// Reads a book aloud: picks up from the page on screen, reads chapter after chapter, and keeps the page,
/// the highlight, the Lock Screen, and headphone controls in step with the voice.
@Observable
final class ListeningSession {
    private static let logger = Logger(subsystem: "com.mbbooks.MBBooks", category: "Listening")

    enum State: Equatable {
        case idle, loading, playing, paused, finished
        case failed(String)
    }

    let book: Book
    let provider: SpeechScriptProvider
    let bookFolder: URL
    let language: String?

    private(set) var state: State = .idle
    private(set) var mode: ListeningMode = .instant
    /// Waiting for Studio audio to be rendered.
    private(set) var isWaiting = false
    /// Whether the page follows the voice. Turning pages by hand stops following until asked to return.
    private(set) var isFollowing = true
    private(set) var chapter: SpeechChapter?
    private(set) var index = 0
    /// Explains why Studio wasn't used, when it was asked for.
    private(set) var notice: String?

    var preferences: ListeningPreferences {
        didSet {
            guard preferences != oldValue else { return }
            preferences.save()
            applyPreferenceChange(from: oldValue)
        }
    }

    weak var reader: SpeechFollowing?
    var coverImage: UIImage?

    private var backend: SpeechBackend?
    private var pageTurnTask: Task<Void, Never>?
    private var pendingBreak: (offset: Int, page: Int)?
    /// Relocations before this time were caused by following, not by the reader.
    private var navigationGrace = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var startedAt = Date()

    init(book: Book, publication: Publication, container: DirectoryContainer) {
        self.book = book
        bookFolder = container.root.deletingLastPathComponent()
        provider = SpeechScriptProvider(
            publication: publication, container: container, folder: bookFolder.appending(path: "speech", directoryHint: .isDirectory))
        language = publication.metadata.language
        preferences = ListeningPreferences.load()
    }

    var isActive: Bool { state != .idle }
    var isPlaying: Bool { state == .playing }
    var currentUtterance: SpeechUtterance? {
        guard let chapter, chapter.utterances.indices.contains(index) else { return nil }
        return chapter.utterances[index]
    }

    var supportsStudio: Bool { NeuralVoiceCatalog.supports(language: language) }

    /// The mode that will actually be used: Studio needs the model and an English book.
    var effectiveMode: ListeningMode {
        guard preferences.mode == .studio else { return .instant }
        return supportsStudio && NeuralVoiceStore.shared.isReady ? .studio : .instant
    }

    var chapterTitle: String? {
        guard let chapter else { return nil }
        return chapter.title ?? book.title
    }

    // MARK: - Starting and stopping

    /// Starts reading from the top of the page on screen, or from the selection.
    func start(fromSelection: Bool = false) async {
        state = .loading
        isFollowing = true
        var spineIndex = 0
        var offset: Int?
        if fromSelection, let selection = await reader?.selectionTextOffset() {
            spineIndex = selection.spineIndex
            offset = selection.offset
        } else if let visible = await reader?.visibleTextOffset() {
            spineIndex = visible.spineIndex
            offset = visible.offset
        } else if let location = book.location {
            spineIndex = location.spineIndex
        }
        guard let chapter = await provider.readableChapter(from: spineIndex) else {
            state = .failed(String(localized: "There's nothing to read from here."))
            return
        }
        var startIndex = 0
        if chapter.spineIndex == spineIndex, let offset {
            // The sentence on screen, even if it started on the previous page.
            startIndex = chapter.utterances.firstIndex { ($0.end ?? .max) > offset } ?? 0
        }
        activateAudioSession()
        installRemoteCommands()
        play(chapter, from: startIndex)
    }

    func stop() {
        backend?.stop()
        backend = nil
        pageTurnTask?.cancel()
        reader?.clearSpeech()
        state = .idle
        chapter = nil
        isWaiting = false
        removeRemoteCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func play(_ chapter: SpeechChapter, from index: Int) {
        self.chapter = chapter
        self.index = max(0, min(index, chapter.utterances.count - 1))
        let backend = makeBackendIfNeeded()
        state = .playing
        startedAt = .now
        backend.play(chapter.utterances, from: self.index)
        updateNowPlaying()
    }

    private func makeBackendIfNeeded() -> SpeechBackend {
        let mode = effectiveMode
        notice = preferences.mode == .studio && mode == .instant
            ? (supportsStudio ? String(localized: "Download the Studio voice to use it.")
                : String(localized: "Studio voices read English only, so this book uses Instant."))
            : nil
        if let backend, mode == self.mode {
            if let system = backend as? SystemSpeechBackend {
                system.voiceIdentifier = preferences.systemVoice(for: language)
            }
            if let neural = backend as? NeuralSpeechBackend, neural.voice.id != preferences.neuralVoiceID {
                return replaceBackend(mode: mode)
            }
            return backend
        }
        return replaceBackend(mode: mode)
    }

    private func replaceBackend(mode: ListeningMode) -> SpeechBackend {
        if backend != nil { reader?.clearSpeech() }
        backend?.stop()
        let backend: SpeechBackend
        switch mode {
        case .instant:
            let system = SystemSpeechBackend()
            system.bookLanguage = language
            system.voiceIdentifier = preferences.systemVoice(for: language)
            backend = system
        case .studio:
            let voice = preferences.neuralVoice
            backend = NeuralSpeechBackend(voice: voice, store: AudiobookStore(bookFolder: bookFolder, voice: voice))
        }
        backend.rate = preferences.speed
        backend.delegate = self
        self.backend = backend
        self.mode = mode
        isWaiting = false
        return backend
    }

    private func applyPreferenceChange(from old: ListeningPreferences) {
        backend?.rate = preferences.speed
        guard isActive, let chapter else { return }
        let modeChanged = old.mode != preferences.mode
        let voiceChanged = old.neuralVoiceID != preferences.neuralVoiceID || old.systemVoices != preferences.systemVoices
        if modeChanged || voiceChanged {
            let wasPlaying = state == .playing
            play(chapter, from: index)
            if !wasPlaying { pause() }
        }
        if !old.followsAlong, preferences.followsAlong { returnToNarration() }
        if old.followsAlong, !preferences.followsAlong { reader?.clearSpeech() }
        updateNowPlaying()
    }

    /// Called when the reader turns on Studio after downloading it, to switch voices in place.
    func refreshMode() {
        guard isActive, let chapter, effectiveMode != mode else { return }
        play(chapter, from: index)
    }

    // MARK: - Controls

    func togglePlayback() {
        switch state {
        case .playing: pause()
        case .paused: resume()
        case .finished, .failed, .idle: Task { await start() }
        case .loading: break
        }
    }

    func pause() {
        guard state == .playing else { return }
        backend?.pause()
        pageTurnTask?.cancel()
        state = .paused
        updateNowPlaying()
    }

    func resume() {
        guard state == .paused else { return }
        activateAudioSession()
        backend?.resume()
        state = .playing
        updateNowPlaying()
    }

    /// Moves by whole sentences, crossing into neighboring chapters.
    func skip(by count: Int) {
        guard let chapter else { return }
        let target = index + count
        if chapter.utterances.indices.contains(target) {
            play(chapter, from: target)
            return
        }
        Task {
            if target < 0, let previous = await provider.readableChapter(from: chapter.spineIndex - 1, forward: false) {
                play(previous, from: previous.utterances.count - 1)
            } else if target >= chapter.utterances.count,
                      let next = await provider.readableChapter(from: chapter.spineIndex + 1) {
                play(next, from: 0)
            } else {
                play(chapter, from: max(0, min(target, chapter.utterances.count - 1)))
            }
        }
    }

    func skipChapter(forward: Bool) {
        guard let chapter else { return }
        Task {
            if !forward, index > 2 {
                play(chapter, from: 0)
                return
            }
            let from = chapter.spineIndex + (forward ? 1 : -1)
            if let target = await provider.readableChapter(from: from, forward: forward) {
                play(target, from: 0)
            }
        }
    }

    /// Follows the voice again after the reader paged away.
    func returnToNarration() {
        isFollowing = true
        if let utterance = currentUtterance { follow(utterance, duration: nil) }
    }

    /// The reader's page changed. If listening didn't cause it, the reader is browsing; stop following.
    func readerDidRelocate() {
        guard isActive, Date.now > navigationGrace, state != .loading else { return }
        isFollowing = false
        pageTurnTask?.cancel()
    }

    // MARK: - Following along

    private func expectNavigation() {
        navigationGrace = Date.now.addingTimeInterval(1.5)
    }

    private func follow(_ utterance: SpeechUtterance, duration: TimeInterval?) {
        pageTurnTask?.cancel()
        pendingBreak = nil
        guard preferences.followsAlong, let reader else { return }
        guard let start = utterance.start, let end = utterance.end else {
            if isFollowing {
                expectNavigation()
                reader.showSpineItem(utterance.spineIndex)
            }
            return
        }
        let following = isFollowing
        pageTurnTask = Task {
            if following { expectNavigation() }
            guard let mark = await reader.markSpeech(
                spineIndex: utterance.spineIndex, start: start, end: end, word: nil, reveal: following),
                !Task.isCancelled, isFollowing
            else { return }
            if let visible = mark.visible {
                if !visible, let y = mark.y {
                    expectNavigation()
                    reader.scrollSpeech(to: y)
                }
                return
            }
            guard let startPage = mark.startPage, let current = mark.currentPage else { return }
            if startPage != current {
                expectNavigation()
                reader.showSpeechPage(startPage)
            }
            guard let breakOffset = mark.breakOffset, let endPage = mark.endPage, endPage != startPage else { return }
            if let duration, duration > 0 {
                // Rendered audio has no word timings; turn when the voice is about as far in as the page break.
                let fraction = Double(breakOffset - start) / Double(max(1, end - start))
                try? await Task.sleep(for: .seconds(duration * fraction))
                guard !Task.isCancelled, isFollowing, state == .playing else { return }
                expectNavigation()
                reader.showSpeechPage(endPage)
            } else {
                pendingBreak = (breakOffset, endPage)
            }
        }
    }

    // MARK: - Now Playing

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: chapterTitle ?? book.title,
            MPMediaItemPropertyArtist: book.author,
            MPMediaItemPropertyAlbumTitle: book.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? preferences.speed : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1,
        ]
        if let chapter, !chapter.utterances.isEmpty {
            info[MPNowPlayingInfoPropertyPlaybackProgress] = Double(index) / Double(chapter.utterances.count)
        }
        if let coverImage {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: coverImage.size) { _ in coverImage }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = state == .playing ? .playing : .paused
    }

    private func installRemoteCommands() {
        guard commandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (ListeningSession) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { [weak self] _ in
                guard let self else { return .noActionableNowPlayingItem }
                MainActor.assumeIsolated { action(self) }
                return .success
            }
            commandTargets.append((command, target))
        }
        add(center.playCommand) { $0.resume() }
        add(center.pauseCommand) { $0.pause() }
        add(center.togglePlayPauseCommand) { $0.togglePlayback() }
        add(center.nextTrackCommand) { $0.skipChapter(forward: true) }
        add(center.previousTrackCommand) { $0.skipChapter(forward: false) }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        add(center.skipForwardCommand) { $0.skip(by: 2) }
        add(center.skipBackwardCommand) { $0.skip(by: -2) }
    }

    private func removeRemoteCommands() {
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets = []
    }

    // MARK: - Audio session

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
        } catch {
            Self.logger.error("Audio session: \(error.localizedDescription, privacy: .public)")
        }
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) {
            [weak self] notification in
            let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init) ?? []
            MainActor.assumeIsolated {
                guard let self else { return }
                if type == .began {
                    self.pause()
                } else if type == .ended, options.contains(.shouldResume) {
                    self.resume()
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) {
            [weak self] notification in
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init)
            // Unplugging headphones pauses, so the book doesn't start playing out loud.
            MainActor.assumeIsolated {
                if reason == .oldDeviceUnavailable { self?.pause() }
            }
        })
    }
}

extension ListeningSession: SpeechBackendDelegate {
    func backend(didStart index: Int, duration: TimeInterval?) {
        self.index = index
        if isWaiting { isWaiting = false }
        guard let utterance = currentUtterance else { return }
        follow(utterance, duration: duration)
        updateNowPlaying()
    }

    func backend(willSpeakWord range: NSRange, in index: Int) {
        guard preferences.followsAlong, let chapter, chapter.utterances.indices.contains(index) else { return }
        let utterance = chapter.utterances[index]
        guard let start = utterance.start, let end = utterance.end,
              let wordStart = utterance.sourceOffset(forSpoken: range.location),
              let wordEnd = utterance.sourceOffset(forSpoken: range.location + range.length)
        else { return }
        let reader = reader
        Task {
            _ = await reader?.markSpeech(spineIndex: utterance.spineIndex, start: start, end: end,
                                         word: wordStart..<max(wordStart, wordEnd), reveal: false)
        }
        if let pending = pendingBreak, wordStart >= pending.offset, isFollowing {
            pendingBreak = nil
            expectNavigation()
            reader?.showSpeechPage(pending.page)
        }
    }

    func backendDidFinish() {
        guard let chapter, state == .playing else { return }
        Task {
            if let next = await provider.readableChapter(from: chapter.spineIndex + 1) {
                play(next, from: 0)
            } else {
                state = .finished
                reader?.clearSpeech()
                updateNowPlaying()
            }
        }
    }

    func backend(isWaiting: Bool) {
        self.isWaiting = isWaiting
    }

    func backend(didFail error: Error) {
        Self.logger.error("Listening failed: \(error.localizedDescription, privacy: .public)")
        state = .failed(error.localizedDescription)
    }
}
