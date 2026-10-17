import AVFoundation
import Observation

/// Plays a short sample of a voice from the voice list.
@Observable
final class VoicePreview: NSObject {
    static let shared = VoicePreview()
    static let sampleText = String(localized: "The quick brown fox jumps over the lazy dog. Shall we begin the next chapter?")

    /// The voice being previewed: a natural voice ID or a system voice identifier.
    private(set) var playingID: String?

    private var player: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func isPlaying(_ id: String) -> Bool { playingID == id }

    /// Plays the bundled sample of a natural voice, or stops it if it's the one playing.
    func toggle(_ voice: NeuralVoiceCatalog.Voice) {
        if playingID == voice.id { stop(); return }
        stop()
        guard let url = voice.previewURL, let player = try? AVAudioPlayer(contentsOf: url) else { return }
        activateSession()
        player.delegate = self
        self.player = player
        playingID = voice.id
        player.play()
    }

    /// Speaks a sample with a system voice, or stops it if it's the one playing.
    func toggle(_ voice: AVSpeechSynthesisVoice) {
        if playingID == voice.identifier { stop(); return }
        stop()
        activateSession()
        let utterance = AVSpeechUtterance(string: Self.sampleText)
        utterance.voice = voice
        playingID = voice.identifier
        synthesizer.speak(utterance)
    }

    func stop() {
        player?.stop()
        player = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        playingID = nil
    }

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}

extension VoicePreview: AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let current = self.player, ObjectIdentifier(current) == finished else { return }
                self.player = nil
                self.playingID = nil
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if self.player == nil { self.playingID = nil }
            }
        }
    }
}
