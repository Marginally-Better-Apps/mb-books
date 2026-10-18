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
    /// The page the word being spoken is on, when a word was marked.
    var wordPage: Int?
    /// Scroll mode: whether the sentence (or the word, when one was marked) is on screen, and where to scroll to show it.
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
    /// The voice reading now (or next, when paused).
    private(set) var activeVoice: ResolvedVoice?
    /// Waiting for a natural voice to render the next sentence.
    private(set) var isWaiting = false
    /// Whether the page follows the voice. Turning pages by hand stops following until asked to return.
    private(set) var isFollowing = true
    private(set) var chapter: SpeechChapter?
    private(set) var index = 0

    /// A voice ready to read: a downloaded natural voice, or a system voice.
    enum ResolvedVoice: Equatable {
        case natural(NeuralVoiceCatalog.Voice)
        case system(identifier: String?)
    }

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
    /// Set when the voice or position changed while paused; the next resume starts from `index` afresh.
    private var needsRestart = false
    private var pageTurnTask: Task<Void, Never>?
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

    var supportsNaturalVoices: Bool { NeuralVoiceCatalog.supports(language: language) }

    /// The voice that will read: the chosen natural voice if it can, otherwise the system voice for the language.
    var resolvedVoice: ResolvedVoice {
        if let natural = preferences.naturalVoice, supportsNaturalVoices, NeuralVoiceStore.shared.isReady {
            return .natural(natural)
        }
        return .system(identifier: preferences.systemVoice(for: language))
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

    /// Reads `chapter` from `index`, or, with `startPlaying` false, just moves there for the next resume.
    private func play(_ chapter: SpeechChapter, from index: Int, startPlaying: Bool = true) {
        self.chapter = chapter
        self.index = max(0, min(index, chapter.utterances.count - 1))
        guard startPlaying else {
            backend?.stop()
            needsRestart = true
            state = .paused
            if let utterance = currentUtterance { follow(utterance, duration: nil) }
            updateNowPlaying()
            return
        }
        needsRestart = false
        let backend = makeBackendIfNeeded()
        state = .playing
        startedAt = .now
        backend.play(chapter.utterances, from: self.index)
        updateNowPlaying()
    }

    private func makeBackendIfNeeded() -> SpeechBackend {
        let voice = resolvedVoice
        if let backend, voice == activeVoice { return backend }
        if backend != nil { reader?.clearSpeech() }
        backend?.stop()
        let backend: SpeechBackend
        switch voice {
        case .system(let identifier):
            let system = SystemSpeechBackend()
            system.bookLanguage = language
            system.voiceIdentifier = identifier
            backend = system
        case .natural(let natural):
            let store = NeuralVoiceStore.shared
            backend = NeuralSpeechBackend(voice: natural, directory: store.directory, voiceURL: store.voiceURL(natural))
        }
        backend.rate = preferences.speed
        backend.delegate = self
        self.backend = backend
        activeVoice = voice
        isWaiting = false
        return backend
    }

    private func applyPreferenceChange(from old: ListeningPreferences) {
        backend?.rate = preferences.speed
        if old.voice != preferences.voice || old.systemVoices != preferences.systemVoices { voiceDidChange() }
        guard isActive else { return }
        if !old.followsAlong, preferences.followsAlong { returnToNarration() }
        if old.followsAlong, !preferences.followsAlong { reader?.clearSpeech() }
        updateNowPlaying()
    }

    /// Switches to the chosen voice at the current sentence. Never starts playback: a paused book stays paused
    /// and picks up with the new voice when resumed.
    func voiceDidChange() {
        guard isActive, let chapter, resolvedVoice != activeVoice else { return }
        if state == .playing {
            play(chapter, from: index)
        } else {
            backend?.stop()
            needsRestart = true
        }
    }

    /// Prepares the model before the first sentence is needed, if a natural voice will read.
    func prewarm() {
        if case .natural = resolvedVoice { NeuralSpeechService.shared.prewarm(directory: NeuralVoiceStore.shared.directory) }
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
        if needsRestart || backend == nil || resolvedVoice != activeVoice, let chapter {
            play(chapter, from: index)
            return
        }
        backend?.resume()
        state = .playing
        updateNowPlaying()
    }

    /// Moves by whole sentences, crossing into neighboring chapters.
    /// Moves by whole sentences, crossing into neighboring chapters. Keeps playing or stays paused.
    func skip(by count: Int) {
        guard let chapter else { return }
        let playing = state == .playing
        let target = index + count
        if chapter.utterances.indices.contains(target) {
            play(chapter, from: target, startPlaying: playing)
            return
        }
        Task {
            if target < 0, let previous = await provider.readableChapter(from: chapter.spineIndex - 1, forward: false) {
                play(previous, from: previous.utterances.count - 1, startPlaying: playing)
            } else if target >= chapter.utterances.count,
                      let next = await provider.readableChapter(from: chapter.spineIndex + 1) {
                play(next, from: 0, startPlaying: playing)
            } else {
                play(chapter, from: max(0, min(target, chapter.utterances.count - 1)), startPlaying: playing)
            }
        }
    }

    func skipChapter(forward: Bool) {
        guard let chapter else { return }
        let playing = state == .playing
        Task {
            if !forward, index > 2 {
                play(chapter, from: 0, startPlaying: playing)
                return
            }
            let from = chapter.spineIndex + (forward ? 1 : -1)
            if let target = await provider.readableChapter(from: from, forward: forward) {
                play(target, from: 0, startPlaying: playing)
            }
        }
    }

    /// Follows the voice again after the reader paged away.
    func returnToNarration() {
        isFollowing = true
        if let utterance = currentUtterance { follow(utterance, duration: nil) }
    }

    /// The reader turned or jumped to another page themselves: they're browsing, so stop following until asked.
    func readerWasNavigated() {
        guard isActive, state != .loading else { return }
        isFollowing = false
        pageTurnTask?.cancel()
    }

    // MARK: - Following along


    private func follow(_ utterance: SpeechUtterance, duration: TimeInterval?) {
        pageTurnTask?.cancel()
        guard preferences.followsAlong, let reader else { return }
        guard let start = utterance.start, let end = utterance.end else {
            if isFollowing {
                reader.showSpineItem(utterance.spineIndex)
            }
            return
        }
        let following = isFollowing
        pageTurnTask = Task {
            guard let mark = await reader.markSpeech(
                spineIndex: utterance.spineIndex, start: start, end: end, word: nil, reveal: following),
                !Task.isCancelled, isFollowing
            else { return }
            if let visible = mark.visible {
                if !visible, let y = mark.y {
                    reader.scrollSpeech(to: y)
                }
                return
            }
            guard let startPage = mark.startPage, let current = mark.currentPage else { return }
            if startPage != current {
                reader.showSpeechPage(startPage)
            }
            guard let breakOffset = mark.breakOffset, let endPage = mark.endPage, endPage != startPage else { return }
            if let duration, duration > 0 {
                // Rendered audio has no word timings; turn when the voice is about as far in as the page break.
                let fraction = Double(breakOffset - start) / Double(max(1, end - start))
                try? await Task.sleep(for: .seconds(duration * fraction))
                guard !Task.isCancelled, isFollowing, state == .playing else { return }
                reader.showSpeechPage(endPage)
            }
            // Otherwise the words turn the page as they reach it.
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
            info[MPMediaItemPropertyArtwork] = Self.artwork(coverImage)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = state == .playing ? .playing : .paused
    }

    /// MediaPlayer asks for artwork on its own queue, so the handler must not be tied to the main actor.
    nonisolated private static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        let handler: @Sendable (CGSize) -> UIImage = { _ in image }
        return MPMediaItemArtwork(boundsSize: image.size, requestHandler: handler)
    }

    private func installRemoteCommands() {
        guard commandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (ListeningSession) -> Void) {
            command.isEnabled = true
            let handler: @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    action(self)
                }
                return .success
            }
            let target = command.addTarget(handler: handler)
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
        Task {
            guard let reader,
                  let mark = await reader.markSpeech(spineIndex: utterance.spineIndex, start: start, end: end,
                                                     word: wordStart..<max(wordStart, wordEnd), reveal: false),
                  isFollowing, state == .playing
            else { return }
            // Keep the word being spoken on screen.
            if mark.visible == false, let y = mark.y {
                reader.scrollSpeech(to: y)
            } else if let page = mark.wordPage, page != mark.currentPage {
                reader.showSpeechPage(page)
            }
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
