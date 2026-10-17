import Foundation

/// The natural voice model and its voices, pinned to exact files so every download can be verified.
///
/// Kyutai's Pocket TTS (english_2026-09, CC BY 4.0), converted to Core ML by `scripts/pocket-tts/convert.py`.
/// Pocket reads plain text, with no pronunciation dictionary, and sounds far more natural than Kokoro, which
/// it replaced. Only voices licensed for commercial use are offered.
nonisolated enum NeuralVoiceCatalog {
    struct File: Sendable, Hashable {
        let name: String
        let url: URL
        let size: Int64
        let sha256: String
    }

    struct Voice: Identifiable, Sendable, Hashable {
        enum Source: Sendable {
            case audiobookNarrator, voiceActor, studioRecording
        }

        let id: String
        let name: String
        let source: Source
        let size: Int64
        let sha256: String

        var file: File {
            File(name: "\(id).bin", url: NeuralVoiceCatalog.repository.appending(path: "voices/\(id).bin"), size: size, sha256: sha256)
        }

        var description: String {
            switch source {
            case .audiobookNarrator: String(localized: "Audiobook narrator")
            case .voiceActor: String(localized: "Voice actor")
            case .studioRecording: String(localized: "Studio recording")
            }
        }

        /// A short sample bundled with the app, so voices can be heard before the model is downloaded.
        var previewURL: URL? {
            Bundle.main.url(forResource: "preview-\(id)", withExtension: "m4a")
        }
    }

    static let modelID = "pocket-tts-2026-09-v1"
    /// Folders of earlier model downloads, removed to give the space back.
    static let retiredModelIDs = ["kokoro-82m-v1.0", "kokoro-82m-v1.0-q8"]
    // TODO: Move to a public host before release. The tailnet only reaches the developer's own devices.
    static let repository = URL(string: "https://shloks-macbook-air.taildb44.ts.net:8443/pocket-tts/v1")!

    /// Core ML models, archived with Apple Archive: the transformer (8-bit weights) and the audio decoder.
    static let models = [
        File(name: "FlowLM.mlmodelc.aar", url: repository.appending(path: "FlowLM.mlmodelc.aar"), size: 78_428_223,
             sha256: "ee9fd76490e9ae2b0c5c78f52b08e7c3cacc988e8edded8cd9722ea1c9141bcc"),
        File(name: "Mimi.mlmodelc.aar", url: repository.appending(path: "Mimi.mlmodelc.aar"), size: 19_087_174,
             sha256: "4a256260f1140501e6a37380e2f4f6c4a0f831cc906f331c5a21e56dc5180bda"),
    ]

    /// Voices, best first by automatic naturalness score.
    static let voices: [Voice] = [
        Voice(id: "george", name: "George", source: .studioRecording, size: 3_121_156,
              sha256: "9b06e8d3646331636a84c24845c1593d9eb246bd0da7840747d3b36031bc5151"),
        Voice(id: "mary", name: "Mary", source: .studioRecording, size: 3_096_580,
              sha256: "1740b9d73afa4a0529776497e46be8c7915663fabf5a18f3a7c526e6d9bef109"),
        Voice(id: "jane", name: "Jane", source: .studioRecording, size: 3_686_404,
              sha256: "e59573117c9691d678b8e33a06dc8b9aa0d144bbce053e484130318c44a12268"),
        Voice(id: "eve", name: "Eve", source: .studioRecording, size: 3_268_612,
              sha256: "365e49642468345193c24d1a2ab9983dc2aac753c758d1fb8cb681742906f93e"),
        Voice(id: "anna", name: "Anna", source: .studioRecording, size: 3_907_588,
              sha256: "f3ad084cdc6205763760c2dad0c0412a02cc6000ae3daee1786c7b86a79229cd"),
        Voice(id: "eponine", name: "Eponine", source: .studioRecording, size: 3_465_220,
              sha256: "f0e93f1f629a6bed3b69d589d209cf1d4d9a9458cc17838b293f38e52fdf675e"),
        Voice(id: "vera", name: "Vera", source: .studioRecording, size: 3_366_916,
              sha256: "7a3ebbf5dfd9e5460421d4b0f4e79c9a7e84d82bc2b7e8a90c8336fa3bd817b4"),
        Voice(id: "michael", name: "Michael", source: .studioRecording, size: 3_637_252,
              sha256: "abe2e708f6ce6c940e1a033e71337bf622a5619d8c749e79858fc9e8703f6731"),
        Voice(id: "fantine", name: "Fantine", source: .studioRecording, size: 3_268_612,
              sha256: "6a5dabb9ca3734942e996b28ec851bebfcaecfb53543331fc1204a7d5de8b002"),
        Voice(id: "azelma", name: "Azelma", source: .studioRecording, size: 3_981_316,
              sha256: "cef7ae49ac00f04bdfb087182092cd8364662c8df452cfad9c56496b37e24715"),
        Voice(id: "bill_boerst", name: "Bill", source: .audiobookNarrator, size: 3_366_916,
              sha256: "e8363bb705847a0749aad4a40eb612c4eea6b47fe26dafd6ea37815a0e470857"),
        Voice(id: "caro_davy", name: "Caro", source: .audiobookNarrator, size: 2_629_636,
              sha256: "ffcac16ad0324f1c7d1b3bd4453ee10023929841bf085e2813b9429d5c4b61be"),
        Voice(id: "peter_yearsley", name: "Peter", source: .audiobookNarrator, size: 1_867_780,
              sha256: "7f31598e4f199c4f9df2af532ac0ad29cdd2d92c78f9bd6b32f46e1e388e8684"),
        Voice(id: "alba", name: "Alba", source: .voiceActor, size: 3_096_580,
              sha256: "1e42a1b340f766e3d60c9e9a8db255f98e8b2846bae4c508a4a67dbe111e5a00"),
        Voice(id: "charles", name: "Charles", source: .studioRecording, size: 3_096_580,
              sha256: "3200cd37013513b8c6ba1b722366429224a30dfaa5bd49036365a3e782297d34"),
        Voice(id: "paul", name: "Paul", source: .studioRecording, size: 3_489_796,
              sha256: "fa84e90f5ee9c83a44ee156f48a3187f544be45aae97b3a1dc5df2232509e183"),
        Voice(id: "stuart_bell", name: "Stuart", source: .audiobookNarrator, size: 2_629_636,
              sha256: "b270ede3ecc0003d3ccce67174a691e61ae520d539c4e7ad98001d46263b3665"),
    ]

    static let defaultVoice = voices[0]

    static func voice(id: String) -> Voice? {
        voices.first { $0.id == id }
    }

    /// Models and voices together, for the download size.
    static var downloadSize: Int64 { models.reduce(0) { $0 + $1.size } + voices.reduce(0) { $0 + $1.size } }

    /// Pocket TTS writes 24 kHz mono audio.
    static let sampleRate = PocketSynthesizer.sampleRate

    /// Whether the natural voices can read a book in `language`. They speak English only.
    static func supports(language: String?) -> Bool {
        guard let language, !language.isEmpty else { return true }
        return language.lowercased().hasPrefix("en")
    }
}
