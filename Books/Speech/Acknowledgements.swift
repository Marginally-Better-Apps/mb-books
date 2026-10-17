import SwiftUI

/// Open-source components used for listening, with their licenses.
struct AcknowledgementsView: View {
    struct Component: Identifiable {
        let name: String
        let author: String
        let license: String
        let url: URL
        var id: String { name }
    }

    static let components: [Component] = [
        Component(name: "Pocket TTS", author: "Kyutai", license: "CC BY 4.0",
                  url: URL(string: "https://huggingface.co/kyutai/pocket-tts")!),
        Component(name: "Pocket TTS voices", author: "Kyutai", license: "CC0 and CC BY 4.0",
                  url: URL(string: "https://huggingface.co/kyutai/tts-voices")!),
        Component(name: "CSTR VCTK Corpus", author: "University of Edinburgh", license: "CC BY 4.0",
                  url: URL(string: "https://datashare.ed.ac.uk/handle/10283/3443")!),
        Component(name: "Alba MacKenna voice recordings", author: "Alba MacKenna", license: "CC BY 4.0",
                  url: URL(string: "https://huggingface.co/kyutai/tts-voices/tree/main/alba-mackenna")!),
        Component(name: "Voice-Zero (LibriVox narrators)", author: "Owen Tyme", license: "CC0",
                  url: URL(string: "https://github.com/OwenTyme/voice-zero")!),
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.components) { component in
                    Link(destination: component.url) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(component.name).foregroundStyle(.primary)
                            Text("\(component.author) · \(component.license)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Natural voices run on this device. The full license texts are in THIRD_PARTY_NOTICES.md in the MB Books repository.")
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}
