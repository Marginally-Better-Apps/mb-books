import AVFoundation
import Foundation
import OSLog

/// Events from a voice as it reads a chapter's utterances.
@MainActor
protocol SpeechBackendDelegate: AnyObject {
    /// Utterance `index` began. `duration` is known for rendered audio.
    func backend(didStart index: Int, duration: TimeInterval?)
    /// The voice reached a word, as a UTF-16 range in the utterance's text (system voices only).
    func backend(willSpeakWord range: NSRange, in index: Int)
    func backendDidFinish()
    func backend(isWaiting: Bool)
    func backend(didFail error: Error)
}

/// A voice that reads a list of utterances.
@MainActor
protocol SpeechBackend: AnyObject {
    var delegate: SpeechBackendDelegate? { get set }
    /// Reads `utterances` from `index`; replaces anything already playing.
    func play(_ utterances: [SpeechUtterance], from index: Int)
    func pause()
    func resume()
    func stop()
    /// Playback speed, where 1 is normal.
    var rate: Double { get set }
}

// MARK: - System voices

/// Instant listening with the voices built into iOS (`AVSpeechSynthesizer`): no download, works on every device,
/// and reports each word as it's spoken.
@MainActor
final class SystemSpeechBackend: NSObject, SpeechBackend {
    weak var delegate: SpeechBackendDelegate?
    var voiceIdentifier: String?
    var bookLanguage: String?
    var rate: Double = 1 {
        didSet {
            guard rate != oldValue, let current = currentIndex, isPlaying else { return }
            // AVSpeechSynthesizer can't change speed mid-utterance; restart the sentence.
            play(utterances, from: current)
        }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var utterances: [SpeechUtterance] = []
    private var queued: [ObjectIdentifier: Int] = [:]
    private var nextToQueue = 0
    private var currentIndex: Int?
    private var isPlaying = false
    /// How many utterances to hand the synthesizer ahead of the one speaking.
    private let lookahead = 2

    override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
    }

    func play(_ utterances: [SpeechUtterance], from index: Int) {
        stopSynthesizer()
        self.utterances = utterances
        nextToQueue = index
        currentIndex = nil
        isPlaying = true
        enqueue()
        if queued.isEmpty { delegate?.backendDidFinish() }
    }

    func pause() {
        isPlaying = false
        synthesizer.pauseSpeaking(at: .word)
    }

    func resume() {
        isPlaying = true
        if synthesizer.isPaused { synthesizer.continueSpeaking() } else if let current = currentIndex { play(utterances, from: current) }
    }

    func stop() {
        isPlaying = false
        stopSynthesizer()
        utterances = []
    }

    private func stopSynthesizer() {
        queued = [:]
        if synthesizer.isSpeaking || synthesizer.isPaused { synthesizer.stopSpeaking(at: .immediate) }
    }

    private func enqueue() {
        let limit = (currentIndex ?? nextToQueue) + lookahead
        while nextToQueue < utterances.count, nextToQueue <= limit {
            let source = utterances[nextToQueue]
            let utterance = AVSpeechUtterance(string: source.text)
            utterance.voice = SystemVoices.voice(for: source.language ?? bookLanguage, preferred: voiceIdentifier)
            utterance.rate = SystemVoices.rate(for: rate)
            utterance.postUtteranceDelay = source.pauseAfter / max(rate, 0.5)
            utterance.prefersAssistiveTechnologySettings = false
            queued[ObjectIdentifier(utterance)] = nextToQueue
            synthesizer.speak(utterance)
            nextToQueue += 1
        }
    }
}

extension SystemSpeechBackend: AVSpeechSynthesizerDelegate {
    // AVSpeechSynthesizer doesn't promise which thread it calls back on; hop to the main queue in order.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        onMain {
            guard let index = self.queued[id] else { return }
            self.currentIndex = index
            self.delegate?.backend(didStart: index, duration: nil)
            self.enqueue()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        onMain {
            guard let index = self.queued[id] else { return }
            self.delegate?.backend(willSpeakWord: characterRange, in: index)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        onMain {
            guard let index = self.queued.removeValue(forKey: id) else { return }
            if index == self.utterances.count - 1, self.nextToQueue >= self.utterances.count {
                self.isPlaying = false
                self.delegate?.backendDidFinish()
            }
        }
    }
}

private nonisolated func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(work)
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }
}

/// Choosing among the voices installed on the device.
enum SystemVoices {
    /// Voices for a language, best quality first, without novelty voices.
    static func voices(for language: String?) -> [AVSpeechSynthesisVoice] {
        let wanted = (language ?? Locale.current.language.languageCode?.identifier ?? "en").lowercased()
        let primary = String(wanted.split(separator: "-").first ?? "en")
        let region = wanted.split(separator: "-").dropFirst().first.map(String.init)
            ?? Locale.current.region?.identifier.lowercased()
        // The voice iOS uses for the language by default, which is better than older voices like Fred.
        let systemDefault = AVSpeechSynthesisVoice(language: language ?? AVSpeechSynthesisVoice.currentLanguageCode())?.identifier
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(primary) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { lhs, rhs in
                if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
                if (lhs.identifier == systemDefault) != (rhs.identifier == systemDefault) { return lhs.identifier == systemDefault }
                let lhsRegion = region.map { lhs.language.lowercased().hasSuffix($0) } ?? false
                let rhsRegion = region.map { rhs.language.lowercased().hasSuffix($0) } ?? false
                if lhsRegion != rhsRegion { return lhsRegion }
                return lhs.name < rhs.name
            }
    }

    /// The reader's chosen voice if it speaks the language, else the best one installed.
    static func voice(for language: String?, preferred identifier: String?) -> AVSpeechSynthesisVoice? {
        let candidates = voices(for: language)
        if let identifier, let chosen = candidates.first(where: { $0.identifier == identifier }) { return chosen }
        return candidates.first ?? AVSpeechSynthesisVoice(language: language)
    }

    /// Whether only basic voices are installed, so the reader should be pointed to the better downloads.
    static func hasOnlyCompactVoices(for language: String?) -> Bool {
        !voices(for: language).contains { $0.quality != .default }
    }

    /// Maps a playback speed (1 = normal) onto `AVSpeechUtterance` rates, which aren't linear.
    static func rate(for speed: Double) -> Float {
        let base = Double(AVSpeechUtteranceDefaultSpeechRate)
        let rate = speed <= 1 ? base * speed : base + (Double(AVSpeechUtteranceMaximumSpeechRate) - base) * min(1, (speed - 1) / 2.5)
        return Float(min(max(rate, Double(AVSpeechUtteranceMinimumSpeechRate)), Double(AVSpeechUtteranceMaximumSpeechRate)))
    }
}

// MARK: - Natural voices

/// Natural voices: Pocket TTS renders a few sentences ahead of the listener while they play through
/// `AVAudioEngine`, so speed changes keep the voice's pitch.
@MainActor
final class NeuralSpeechBackend: SpeechBackend {
    nonisolated private static let logger = Logger(subsystem: "com.mbbooks.MBBooks", category: "NaturalVoice")
    nonisolated static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: NeuralVoiceCatalog.sampleRate, channels: 1, interleaved: false)

    weak var delegate: SpeechBackendDelegate?
    var rate: Double = 1 {
        didSet { timePitch.rate = Float(rate) }
    }

    let voice: NeuralVoiceCatalog.Voice
    private let directory: URL
    private let voiceURL: URL
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var utterances: [SpeechUtterance] = []
    private var generation = 0
    private var nextToSchedule = 0
    private var scheduledAhead = 0
    /// Rendered samples (nil for a sentence that's skipped), or a failure that stops listening.
    private var rendering: [Int: Task<Result<[Float]?, NeuralVoiceError>, Never>] = [:]
    private var isPaused = false
    private var isWaiting = false
    private var durations: [Int: TimeInterval] = [:]
    /// Sentences rendered ahead of the one playing.
    private let lookahead = 3

    init(voice: NeuralVoiceCatalog.Voice, directory: URL, voiceURL: URL) {
        self.voice = voice
        self.directory = directory
        self.voiceURL = voiceURL
        engine.attach(player)
        engine.attach(timePitch)
        if let format = Self.format {
            engine.connect(player, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        }
        NeuralSpeechService.shared.prewarm(directory: directory)
    }

    func play(_ utterances: [SpeechUtterance], from index: Int) {
        stopPlayback()
        self.utterances = utterances
        nextToSchedule = index
        isPaused = false
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            delegate?.backend(didFail: error)
            return
        }
        player.play()
        fill()
    }

    func pause() {
        isPaused = true
        player.pause()
    }

    func resume() {
        isPaused = false
        if !engine.isRunning { try? engine.start() }
        player.play()
    }

    func stop() {
        stopPlayback()
        engine.stop()
        utterances = []
    }

    private func stopPlayback() {
        generation += 1
        rendering.values.forEach { $0.cancel() }
        rendering = [:]
        // Sentences queued for the sentence that was playing are no longer needed.
        NeuralSpeechService.shared.cancelQueued()
        player.stop()
        scheduledAhead = 0
        durations = [:]
        setWaiting(false)
    }

    /// Keeps a few sentences rendered and scheduled ahead of the one playing.
    private func fill() {
        let generation = generation
        for index in nextToSchedule..<min(utterances.count, nextToSchedule + lookahead) where rendering[index] == nil {
            let text = utterances[index].text
            let voice = voice
            let directory = directory
            let voiceURL = voiceURL
            rendering[index] = Task.detached(priority: .userInitiated) {
                await Self.samples(for: text, voice: voice, directory: directory, voiceURL: voiceURL)
            }
        }
        guard scheduledAhead < 2, nextToSchedule < utterances.count, let task = rendering[nextToSchedule] else {
            if nextToSchedule >= utterances.count, scheduledAhead == 0 { delegate?.backendDidFinish() }
            return
        }
        let index = nextToSchedule
        if scheduledAhead == 0 { setWaiting(true) }
        Task {
            let result = await task.value
            guard generation == self.generation, index == nextToSchedule else { return }
            rendering[index] = nil
            if case .failure(let error) = result {
                // Nothing can be read: stop rather than skip through the book.
                stopPlayback()
                delegate?.backend(didFail: error)
                return
            }
            nextToSchedule += 1
            guard case .success(let samples) = result, let samples, !samples.isEmpty, let format = Self.format, let buffer = Self.buffer(samples, format: format) else {
                // A sentence that can't be rendered is skipped rather than stopping the book.
                fill()
                return
            }
            schedule(buffer, index: index, generation: generation)
            fill()
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, index: Int, generation: Int) {
        let padded = Self.appendingSilence(buffer, seconds: utterances[index].pauseAfter)
        durations[index] = Double(buffer.frameLength) / NeuralVoiceCatalog.sampleRate
        let startsNow = scheduledAhead == 0
        scheduledAhead += 1
        if startsNow {
            setWaiting(false)
            delegate?.backend(didStart: index, duration: durations[index].map { $0 / rate })
        }
        // Called on an audio thread.
        let completion: @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self, generation == self.generation else { return }
                self.scheduledAhead -= 1
                // The next scheduled sentence starts as this one ends.
                if self.scheduledAhead > 0, index + 1 < self.utterances.count {
                    self.delegate?.backend(didStart: index + 1, duration: self.durations[index + 1].map { $0 / self.rate })
                }
                self.fill()
            }
        }
        player.scheduleBuffer(padded, completionCallbackType: .dataPlayedBack, completionHandler: completion)
        if !isPaused, !player.isPlaying { player.play() }
    }

    private func setWaiting(_ waiting: Bool) {
        guard waiting != isWaiting else { return }
        isWaiting = waiting
        delegate?.backend(isWaiting: waiting)
    }

    @concurrent
    nonisolated private static func samples(for text: String, voice: NeuralVoiceCatalog.Voice, directory: URL,
                                            voiceURL: URL) async -> Result<[Float]?, NeuralVoiceError> {
        guard !Task.isCancelled else { return .success(nil) }
        do {
            return .success(try await NeuralSpeechService.shared.synthesize(text, voice: voice, directory: directory, voiceURL: voiceURL))
        } catch is CancellationError {
            return .success(nil)
        } catch let error as NeuralVoiceError {
            logger.error("Natural voices are unusable: \(error.localizedDescription, privacy: .public)")
            return .failure(error)
        } catch {
            logger.error("Couldn't render a sentence: \(error.localizedDescription, privacy: .public)")
            return .success(nil)
        }
    }

    nonisolated static func buffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count))) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        }
        return buffer
    }

    private static func appendingSilence(_ buffer: AVAudioPCMBuffer, seconds: Double) -> AVAudioPCMBuffer {
        let extra = AVAudioFrameCount(max(0, seconds) * buffer.format.sampleRate)
        guard extra > 0, let padded = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength + extra),
              let source = buffer.floatChannelData?[0], let destination = padded.floatChannelData?[0]
        else { return buffer }
        destination.update(from: source, count: Int(buffer.frameLength))
        destination.advanced(by: Int(buffer.frameLength)).initialize(repeating: 0, count: Int(extra))
        padded.frameLength = buffer.frameLength + extra
        return padded
    }
}
