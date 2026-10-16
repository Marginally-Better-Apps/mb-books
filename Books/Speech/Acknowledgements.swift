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
        Component(name: "Kokoro-82M", author: "hexgrad", license: "Apache License 2.0",
                  url: URL(string: "https://huggingface.co/hexgrad/Kokoro-82M")!),
        Component(name: "Kokoro-82M ONNX", author: "onnx-community", license: "Apache License 2.0",
                  url: URL(string: "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX")!),
        Component(name: "misaki pronunciation dictionaries", author: "hexgrad", license: "Apache License 2.0",
                  url: URL(string: "https://github.com/hexgrad/misaki")!),
        Component(name: "graphemes_to_phonemes_en_us", author: "Peter Reid", license: "Apache License 2.0",
                  url: URL(string: "https://huggingface.co/PeterReid/graphemes_to_phonemes_en_us")!),
        Component(name: "ONNX Runtime", author: "Microsoft", license: "MIT License",
                  url: URL(string: "https://github.com/microsoft/onnxruntime")!),
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
                Text("Studio voices and pronunciation run on this device. The full license texts are in THIRD_PARTY_NOTICES.md in the MB Books repository.")
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}
