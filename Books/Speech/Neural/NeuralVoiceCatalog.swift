import Foundation

/// The neural voice model and its voices, pinned to exact files so every download can be verified.
///
/// Kokoro-82M (hexgrad, Apache 2.0) as exported to ONNX by onnx-community (Apache 2.0). Only English
/// voices are offered: Kokoro's other languages depend on espeak-ng for pronunciation, which is GPL-licensed.
nonisolated enum NeuralVoiceCatalog {
    struct File: Sendable, Hashable {
        let name: String
        let url: URL
        let size: Int64
        let sha256: String
    }

    struct Voice: Identifiable, Sendable, Hashable {
        let id: String
        let name: String
        let isFemale: Bool
        let sha256: String

        var file: File {
            File(name: "\(id).bin", url: NeuralVoiceCatalog.repository.appending(path: "voices/\(id).bin"),
                 size: 522_240, sha256: sha256)
        }
    }

    static let modelID = "kokoro-82m-v1.0"
    private static let revision = "1939ad2a8e416c0acfeecc08a694d14ef25f2231"
    static let repository = URL(string: "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/\(revision)")!

    /// The full-precision model: the slow, high-quality path is the reason this exists.
    static let model = File(
        name: "model.onnx", url: repository.appending(path: "onnx/model.onnx"), size: 325_532_232,
        sha256: "8fbea51ea711f2af382e88c833d9e288c6dc82ce5e98421ea61c058ce21a34cb")

    /// American English voices, best first (grades from the Kokoro model card).
    static let voices: [Voice] = [
        Voice(id: "af_heart", name: "Heart", isFemale: true, sha256: "d583ccff3cdca2f7fae535cb998ac07e9fcb90f09737b9a41fa2734ec44a8f0b"),
        Voice(id: "af_bella", name: "Bella", isFemale: true, sha256: "f69d836209b78eb8c66e75e3cda491e26ea838a3674257e9d4e5703cbaf55c8b"),
        Voice(id: "af_nicole", name: "Nicole", isFemale: true, sha256: "cd2191ab31b914ed7b318416b0e4440fdf392ddad9106a060819aa600a64f59a"),
        Voice(id: "am_michael", name: "Michael", isFemale: false, sha256: "1d1f21dd8da39c30705cd4c75d039d265e9bc4a2a93ed09bc9e1b1225eb95ba1"),
        Voice(id: "am_fenrir", name: "Fenrir", isFemale: false, sha256: "c27989f741f7ee34d273a39d8a595cc0837d35f5ced9a29b7cc162614616df43"),
        Voice(id: "am_puck", name: "Puck", isFemale: false, sha256: "fcf73c989033e9233e0b98713eca600c8c74dcc1614b37009d5450ff4a2274a0"),
        Voice(id: "af_aoede", name: "Aoede", isFemale: true, sha256: "4a004c33430762e2461eedb2013fad808ef4ab3121f5300f554476caf58d8361"),
        Voice(id: "af_kore", name: "Kore", isFemale: true, sha256: "9be5221b6a941c04b561959b8ff0b06e809444dcc4ab7e75a7b23606f691819e"),
        Voice(id: "af_sarah", name: "Sarah", isFemale: true, sha256: "4409fbc125afabacc615d94db5398d847006a737b0247d6892b7a9a0007a2f0a"),
    ]

    static let defaultVoice = voices[0]

    static func voice(id: String) -> Voice {
        voices.first { $0.id == id } ?? defaultVoice
    }

    /// Kokoro writes 24 kHz mono audio.
    static let sampleRate = 24_000.0

    /// Whether the neural voices can read a book in `language`. They speak English only.
    static func supports(language: String?) -> Bool {
        guard let language, !language.isEmpty else { return true }
        return language.lowercased().hasPrefix("en")
    }

    /// Phoneme symbols to Kokoro's token IDs (from the model's `tokenizer.json`).
    static let vocabulary: [Character: Int64] = [
        "$": 0, ";": 1, ":": 2, ",": 3, ".": 4, "!": 5, "?": 6, "—": 9, "…": 10, "\"": 11, "(": 12, ")": 13, "“": 14,
        "”": 15, " ": 16, "\u{0303}": 17, "ʣ": 18, "ʥ": 19, "ʦ": 20, "ʨ": 21, "ᵝ": 22, "ꭧ": 23, "A": 24, "I": 25, "O": 31,
        "Q": 33, "S": 35, "T": 36, "W": 39, "Y": 41, "ᵊ": 42, "a": 43, "b": 44, "c": 45, "d": 46, "e": 47, "f": 48, "h": 50,
        "i": 51, "j": 52, "k": 53, "l": 54, "m": 55, "n": 56, "o": 57, "p": 58, "q": 59, "r": 60, "s": 61, "t": 62, "u": 63,
        "v": 64, "w": 65, "x": 66, "y": 67, "z": 68, "ɑ": 69, "ɐ": 70, "ɒ": 71, "æ": 72, "β": 75, "ɔ": 76, "ɕ": 77, "ç": 78,
        "ɖ": 80, "ð": 81, "ʤ": 82, "ə": 83, "ɚ": 85, "ɛ": 86, "ɜ": 87, "ɟ": 90, "ɡ": 92, "ɥ": 99, "ɨ": 101, "ɪ": 102,
        "ʝ": 103, "ɯ": 110, "ɰ": 111, "ŋ": 112, "ɳ": 113, "ɲ": 114, "ɴ": 115, "ø": 116, "ɸ": 118, "θ": 119, "œ": 120,
        "ɹ": 123, "ɾ": 125, "ɻ": 126, "ʁ": 128, "ɽ": 129, "ʂ": 130, "ʃ": 131, "ʈ": 132, "ʧ": 133, "ʊ": 135, "ʋ": 136,
        "ʌ": 138, "ɣ": 139, "ɤ": 140, "χ": 142, "ʎ": 143, "ʒ": 147, "ʔ": 148, "ˈ": 156, "ˌ": 157, "ː": 158, "ʰ": 162,
        "ʲ": 164, "↓": 169, "→": 171, "↗": 172, "↘": 173, "ᵻ": 177,
    ]
}
