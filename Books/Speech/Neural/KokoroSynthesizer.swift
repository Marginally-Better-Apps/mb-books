import Foundation
import OnnxRuntimeBindings
import OSLog

/// Runs Kokoro-82M on the CPU with ONNX Runtime.
///
/// Core ML would be faster on the Neural Engine, but Core ML builds of Kokoro have known crashes in long
/// sessions on current iOS releases (FluidAudio #844, #889). A book is hours of audio, so this uses the CPU,
/// which every supported iPhone and iPad can run and which ONNX Runtime keeps stable.
nonisolated final class KokoroSynthesizer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.mbbooks.MBBooks", category: "Kokoro")
    /// Kokoro's context: 512 tokens including the two padding tokens.
    static let maximumPhonemes = 510
    private static let styleWidth = 256

    private let session: ORTSession
    private let env: ORTEnv
    private let g2p: EnglishG2P
    private let lock = NSLock()
    private var voices: [String: [Float]] = [:]

    init(modelURL: URL, g2p: EnglishG2P, threads: Int = KokoroSynthesizer.recommendedThreads) throws {
        env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        try options.setIntraOpNumThreads(Int32(threads))
        session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
        self.g2p = g2p
    }

    /// Performance cores only: efficiency cores slow a synchronous graph down rather than speeding it up.
    static var recommendedThreads: Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 { return Int(count) }
        return max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    func loadVoice(id: String, from url: URL) throws {
        let data = try Data(contentsOf: url)
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard values.count % Self.styleWidth == 0, values.count >= Self.styleWidth else { throw CocoaError(.fileReadCorruptFile) }
        lock.lock()
        voices[id] = values
        lock.unlock()
    }

    func hasVoice(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return voices[id] != nil
    }

    /// Phonemes for text, split into chunks Kokoro can take at once.
    func phonemeChunks(for text: String) -> [String] {
        let phonemes = g2p.phonemize(text)
        guard phonemes.unicodeScalars.count > Self.maximumPhonemes else { return phonemes.isEmpty ? [] : [phonemes] }
        var chunks: [String] = []
        var current = ""
        // Split after punctuation where possible, else at a word boundary.
        for word in phonemes.split(separator: " ", omittingEmptySubsequences: true) {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if candidate.unicodeScalars.count > Self.maximumPhonemes - 10, !current.isEmpty {
                chunks.append(current)
                current = String(word)
            } else {
                current = candidate
            }
            if let last = current.last, ".!?;:".contains(last), current.unicodeScalars.count > 300 {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Synthesizes text as 24 kHz mono samples.
    func synthesize(_ text: String, voice: String, speed: Float = 1) throws -> [Float] {
        var samples: [Float] = []
        for chunk in phonemeChunks(for: text) {
            samples += try synthesize(phonemes: chunk, voice: voice, speed: speed)
        }
        return samples
    }

    func synthesize(phonemes: String, voice: String, speed: Float = 1) throws -> [Float] {
        let ids = phonemes.unicodeScalars.compactMap { NeuralVoiceCatalog.vocabulary[Character($0)] }
        guard !ids.isEmpty else { return [] }
        let tokens = Array(ids.prefix(Self.maximumPhonemes))
        lock.lock()
        let pack = voices[voice]
        lock.unlock()
        guard let pack else { throw KokoroError.voiceNotLoaded(voice) }
        // Each voice holds a style vector per input length.
        let rows = pack.count / Self.styleWidth
        let row = min(max(tokens.count - 1, 0), rows - 1)
        let style = Array(pack[(row * Self.styleWidth)..<((row + 1) * Self.styleWidth)])

        let input = [Int64(0)] + tokens + [Int64(0)]
        let inputIDs = try ORTValue(
            tensorData: NSMutableData(data: input.withUnsafeBufferPointer { Data(buffer: $0) }),
            elementType: .int64, shape: [1, NSNumber(value: input.count)])
        let styleValue = try ORTValue(
            tensorData: NSMutableData(data: style.withUnsafeBufferPointer { Data(buffer: $0) }),
            elementType: .float, shape: [1, NSNumber(value: Self.styleWidth)])
        var speedValue = speed
        let speedTensor = try ORTValue(
            tensorData: NSMutableData(bytes: &speedValue, length: MemoryLayout<Float>.size), elementType: .float, shape: [1])
        let outputs = try session.run(
            withInputs: ["input_ids": inputIDs, "style": styleValue, "speed": speedTensor],
            outputNames: ["waveform"], runOptions: nil)
        guard let waveform = outputs["waveform"] else { throw KokoroError.noOutput }
        let data = try waveform.tensorData() as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

nonisolated enum KokoroError: LocalizedError {
    case voiceNotLoaded(String)
    case noOutput

    var errorDescription: String? {
        switch self {
        case .voiceNotLoaded(let voice): "The voice \(voice) isn't loaded."
        case .noOutput: "The voice model produced no audio."
        }
    }
}
