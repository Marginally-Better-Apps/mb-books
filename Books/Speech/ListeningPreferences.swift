import Foundation

/// The voice a reader picked.
enum VoiceChoice: Codable, Hashable {
    /// A Kokoro voice, by ID. English books only, once the model is downloaded.
    case natural(String)
    /// The voices built into iOS, chosen per language.
    case system
}

/// Listening settings shared by every book.
struct ListeningPreferences: Equatable {
    static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    var voice: VoiceChoice = .natural(NeuralVoiceCatalog.defaultVoice.id)
    /// System voice identifiers chosen per language ("en", "fr").
    var systemVoices: [String: String] = [:]
    var speed: Double = 1
    /// Turn pages and highlight sentences to follow the voice.
    var followsAlong = true

    private static let key = "listening.preferences.v2"

    static func load(from defaults: UserDefaults = .standard) -> ListeningPreferences {
        guard let data = defaults.data(forKey: key), let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return ListeningPreferences()
        }
        return ListeningPreferences(
            voice: stored.voice, systemVoices: stored.systemVoices, speed: stored.speed, followsAlong: stored.followsAlong)
    }

    func save(to defaults: UserDefaults = .standard) {
        let stored = Stored(voice: voice, systemVoices: systemVoices, speed: speed, followsAlong: followsAlong)
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.key) }
    }

    var naturalVoice: NeuralVoiceCatalog.Voice? {
        if case .natural(let id) = voice { NeuralVoiceCatalog.voice(id: id) } else { nil }
    }

    func systemVoice(for language: String?) -> String? {
        systemVoices[Self.languageKey(language)]
    }

    mutating func setSystemVoice(_ identifier: String?, for language: String?) {
        systemVoices[Self.languageKey(language)] = identifier
    }

    static func languageKey(_ language: String?) -> String {
        String((language ?? "en").lowercased().split(separator: "-").first ?? "en")
    }

    private struct Stored: Codable {
        var voice: VoiceChoice
        var systemVoices: [String: String]
        var speed: Double
        var followsAlong: Bool
    }
}
