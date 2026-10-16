import Foundation

/// How a book is read aloud.
enum ListeningMode: String, CaseIterable, Identifiable, Codable {
    /// The voices built into iOS: starts immediately on any device.
    case instant
    /// Kokoro neural voices: best prepared ahead, rendered on the spot otherwise.
    case studio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .instant: String(localized: "Instant")
        case .studio: String(localized: "Studio")
        }
    }
}

/// Listening settings shared by every book.
struct ListeningPreferences: Equatable {
    static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    var mode: ListeningMode = .instant
    /// System voice identifiers chosen per language ("en", "fr").
    var systemVoices: [String: String] = [:]
    var neuralVoiceID: String = NeuralVoiceCatalog.defaultVoice.id
    var speed: Double = 1
    /// Turn pages and highlight sentences to follow the voice.
    var followsAlong = true

    private static let key = "listening.preferences"

    static func load(from defaults: UserDefaults = .standard) -> ListeningPreferences {
        guard let data = defaults.data(forKey: key), let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return ListeningPreferences()
        }
        return ListeningPreferences(
            mode: stored.mode, systemVoices: stored.systemVoices, neuralVoiceID: stored.neuralVoiceID,
            speed: stored.speed, followsAlong: stored.followsAlong)
    }

    func save(to defaults: UserDefaults = .standard) {
        let stored = Stored(mode: mode, systemVoices: systemVoices, neuralVoiceID: neuralVoiceID, speed: speed, followsAlong: followsAlong)
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.key) }
    }

    var neuralVoice: NeuralVoiceCatalog.Voice { NeuralVoiceCatalog.voice(id: neuralVoiceID) }

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
        var mode: ListeningMode
        var systemVoices: [String: String]
        var neuralVoiceID: String
        var speed: Double
        var followsAlong: Bool
    }
}
