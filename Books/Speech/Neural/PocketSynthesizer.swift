import CoreML
import Foundation
import OSLog

/// Runs Kyutai's Pocket TTS with Core ML.
///
/// Two models, converted by `scripts/pocket-tts/convert.py`:
/// - FlowLM, the transformer that writes 32-number audio latents, 12.5 per second. It keeps its attention cache in
///   a Core ML state and runs on the GPU. Its `prefill` function reads text; `generate` makes one latent.
/// - Mimi, the decoder that turns each latent into 80 ms of 24 kHz audio. It streams, carrying its state from
///   frame to frame, and runs on the CPU in full precision, where it's fastest and its feedback stays clean.
///
/// The two overlap: while the GPU makes the next latent, the CPU decodes the last one.
nonisolated final class PocketSynthesizer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.mbbooks.MBBooks", category: "PocketTTS")

    static let sampleRate = 24_000.0
    static let samplesPerFrame = 1920
    private static let framesPerSecond = 12.5
    private static let cacheLength = 512
    private static let prefillLength = 64
    private static let layers = 6
    private static let heads = 16
    private static let headDimension = 64
    private static let latentSize = 32
    /// Kyutai's sampling settings for this model.
    private static let temperature: Float = 0.3
    private static let endThreshold: Float = -4
    private static let minimumFramesBeforeEnd = 6

    private let prefill: MLModel
    private let generate: MLModel
    private let mimi: MLModel
    private let state: MLState
    private let tokenizer: PocketTokenizer
    private let mimiStateNames: [String]
    private let decoding = DispatchQueue(label: "com.mbbooks.pocket.mimi", qos: .userInitiated)
    private var random = SystemRandomNumberGenerator()

    private var voices: [String: Voice] = [:]
    private var loadedVoice: String?

    /// A voice: the FlowLM cache after its audio prompt, as fp16 keys and values per layer.
    struct Voice: Sendable {
        let length: Int
        let data: Data

        init(url: URL) throws {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count >= 4 else { throw CocoaError(.fileReadCorruptFile) }
            let length = Int(data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
            let expected = 4 + PocketSynthesizer.layers * 2 * PocketSynthesizer.heads * length * PocketSynthesizer.headDimension * 2
            guard length > 0, length < PocketSynthesizer.cacheLength / 2, data.count == expected else {
                throw CocoaError(.fileReadCorruptFile)
            }
            self.length = length
            self.data = data.dropFirst(4)
        }
    }

    /// - Parameters:
    ///   - directory: Holds `FlowLM.mlmodelc` and `Mimi.mlmodelc`.
    ///   - transformerUnits: Where FlowLM runs: the GPU unless testing.
    init(directory: URL, tokenizer: PocketTokenizer, transformerUnits: MLComputeUnits = .cpuAndGPU) throws {
        let gpu = MLModelConfiguration()
        gpu.computeUnits = transformerUnits
        gpu.functionName = "prefill"
        prefill = try MLModel(contentsOf: directory.appending(path: "FlowLM.mlmodelc"), configuration: gpu)
        gpu.functionName = "generate"
        generate = try MLModel(contentsOf: directory.appending(path: "FlowLM.mlmodelc"), configuration: gpu)
        let cpu = MLModelConfiguration()
        cpu.computeUnits = .cpuOnly
        mimi = try MLModel(contentsOf: directory.appending(path: "Mimi.mlmodelc"), configuration: cpu)
        // One state serves both functions of the model.
        state = generate.makeState()
        mimiStateNames = mimi.modelDescription.inputDescriptionsByName.keys.filter { $0 != "latent" && $0 != "frame" }.sorted()
        self.tokenizer = tokenizer
    }

    func loadVoice(id: String, from url: URL) throws {
        voices[id] = try Voice(url: url)
    }

    func hasVoice(_ id: String) -> Bool {
        voices[id] != nil
    }

    /// Synthesizes `text` as 24 kHz mono samples. `isCancelled` is checked between frames.
    func synthesize(_ text: String, voice id: String, isCancelled: () -> Bool = { false }) throws -> [Float] {
        guard let voice = voices[id] else { throw PocketError.voiceNotLoaded(id) }
        if loadedVoice != id {
            try write(voice)
            loadedVoice = id
        }
        let spoken = PocketText.clean(SpokenEnglish.normalize(text), tokenizer: tokenizer)
        var samples: [Float] = []
        for chunk in PocketText.chunks(spoken, tokenizer: tokenizer) {
            guard !isCancelled() else { throw CancellationError() }
            samples += try synthesizeChunk(chunk, voiceLength: voice.length, isCancelled: isCancelled)
        }
        return samples
    }

    // MARK: - FlowLM

    /// Copies a voice into the cache. Generation only writes past it, so it stays for every later chunk.
    private func write(_ voice: Voice) throws {
        for name in ["k_cache", "v_cache"] {
            try state.withMultiArray(for: name) { array in
                // [layer, 1, head, position, dimension]
                let strides = array.strides.map(\.intValue)
                guard array.dataType == .float16, strides.count == 5, strides[4] == 1 else { throw PocketError.unexpectedState }
                let isKeys = name == "k_cache"
                array.withUnsafeMutableBytes { pointer, _ in
                    let destination = pointer.bindMemory(to: UInt16.self)
                    voice.data.withUnsafeBytes { source in
                        let values = source.bindMemory(to: UInt16.self)
                        let block = Self.heads * voice.length * Self.headDimension
                        for layer in 0..<Self.layers {
                            let base = (layer * 2 + (isKeys ? 0 : 1)) * block
                            for head in 0..<Self.heads {
                                for position in 0..<voice.length {
                                    let from = base + (head * voice.length + position) * Self.headDimension
                                    let to = layer * strides[0] + head * strides[2] + position * strides[3]
                                    for dimension in 0..<Self.headDimension {
                                        destination[to + dimension] = values[from + dimension]
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func synthesizeChunk(_ chunk: String, voiceLength: Int, isCancelled: () -> Bool) throws -> [Float] {
        let (text, framesAfterEnd) = PocketText.prepare(chunk)
        let tokens = tokenizer.encode(text)
        guard !tokens.isEmpty else { return [] }
        var position = voiceLength

        // Text, a padded block at a time. Padding lands past the text and generation overwrites it.
        let tokenArray = try MLMultiArray(shape: [1, NSNumber(value: Self.prefillLength)], dataType: .int32)
        let positionArray = try MLMultiArray(shape: [1], dataType: .int32)
        var bos: MLMultiArray?
        for start in stride(from: 0, to: tokens.count, by: Self.prefillLength) {
            let block = tokens[start..<min(tokens.count, start + Self.prefillLength)]
            guard position + Self.prefillLength <= Self.cacheLength else { throw PocketError.textTooLong }
            for index in 0..<Self.prefillLength {
                tokenArray[index] = NSNumber(value: index < block.count ? Int32(block[block.startIndex + index]) : 0)
            }
            positionArray[0] = NSNumber(value: Int32(position))
            let output = try prefill.prediction(
                from: MLDictionaryFeatureProvider(dictionary: ["token_ids": tokenArray, "position": positionArray]),
                using: state)
            bos = output.featureValue(for: "bos_latent")?.multiArrayValue
            position += block.count
        }
        guard var latent = bos else { throw PocketError.noOutput }

        // Latents, decoded on the CPU as they come.
        let maximumFrames = Int(((Double(tokens.count) / 3 + 2) * Self.framesPerSecond).rounded(.up))
        let noise = try MLMultiArray(shape: [1, NSNumber(value: Self.latentSize)], dataType: .float32)
        let decoder = try MimiStream(model: mimi, stateNames: mimiStateNames)
        var endFrame: Int?
        var failure: Error?
        for frame in 0..<maximumFrames where position < Self.cacheLength {
            if isCancelled() {
                failure = CancellationError()
                break
            }
            fillNoise(noise)
            positionArray[0] = NSNumber(value: Int32(position))
            let output = try generate.prediction(
                from: MLDictionaryFeatureProvider(dictionary: ["latent": latent, "noise": noise, "position": positionArray]),
                using: state)
            position += 1
            guard let next = output.featureValue(for: "next_latent")?.multiArrayValue,
                  let end = output.featureValue(for: "eos_logit")?.multiArrayValue else { throw PocketError.noOutput }
            if endFrame == nil, frame >= Self.minimumFramesBeforeEnd, end[0].floatValue > Self.endThreshold { endFrame = frame }
            if let endFrame, frame >= endFrame + framesAfterEnd { break }
            // The next frame's input, and Mimi's: [1, 1, 32], where the output is [1, 32].
            latent = try MLMultiArray(shape: [1, 1, NSNumber(value: Self.latentSize)], dataType: .float32)
            latent.withUnsafeMutableBufferPointer(ofType: Float.self) { destination, _ in
                next.withUnsafeBufferPointer(ofType: Float.self) { source in _ = destination.update(fromContentsOf: source) }
            }
            let decoded = latent
            decoding.async { decoder.decode(decoded, frame: frame) }
        }
        decoding.sync {}
        if let failure { throw failure }
        return try decoder.result()
    }

    /// Gaussian noise with variance `temperature`, the flow's starting point.
    private func fillNoise(_ array: MLMultiArray) {
        let deviation = Self.temperature.squareRoot()
        array.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            var index = 0
            while index < buffer.count {
                // Box–Muller: two uniform numbers make two normal ones.
                let u1 = Float.random(in: Float.ulpOfOne...1, using: &random)
                let u2 = Float.random(in: 0..<1, using: &random)
                let radius = (-2 * log(u1)).squareRoot() * deviation
                buffer[index] = radius * cos(2 * .pi * u2)
                if index + 1 < buffer.count { buffer[index + 1] = radius * sin(2 * .pi * u2) }
                index += 2
            }
        }
    }
}

/// Mimi decoding one utterance, frame by frame, on its own queue.
private nonisolated final class MimiStream: @unchecked Sendable {
    private let model: MLModel
    private var inputs: [String: MLFeatureValue]
    private let stateNames: [String]
    private let frameArray: MLMultiArray
    private var samples: [Float] = []
    private var error: Error?

    init(model: MLModel, stateNames: [String]) throws {
        self.model = model
        self.stateNames = stateNames
        frameArray = try MLMultiArray(shape: [1], dataType: .int32)
        inputs = [:]
        // Every utterance starts from silence: zeroed state.
        for name in stateNames {
            guard let shape = model.modelDescription.inputDescriptionsByName[name]?.multiArrayConstraint?.shape else {
                throw PocketError.unexpectedState
            }
            let array = try MLMultiArray(shape: shape, dataType: .float32)
            array.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in buffer.initialize(repeating: 0) }
            inputs[name] = MLFeatureValue(multiArray: array)
        }
        samples.reserveCapacity(PocketSynthesizer.samplesPerFrame * 200)
    }

    func decode(_ latent: MLMultiArray, frame: Int) {
        guard error == nil else { return }
        do {
            frameArray[0] = NSNumber(value: Int32(frame))
            inputs["latent"] = MLFeatureValue(multiArray: latent)
            inputs["frame"] = MLFeatureValue(multiArray: frameArray)
            let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
            guard let audio = output.featureValue(for: "audio")?.multiArrayValue else { throw PocketError.noOutput }
            audio.withUnsafeBufferPointer(ofType: Float.self) { samples += $0 }
            // The state comes back as outputs and goes in again with the next frame.
            for name in stateNames {
                guard let value = output.featureValue(for: "new_" + name) else { throw PocketError.noOutput }
                inputs[name] = value
            }
        } catch {
            self.error = error
        }
    }

    func result() throws -> [Float] {
        if let error { throw error }
        return samples
    }
}

nonisolated enum PocketError: LocalizedError {
    case voiceNotLoaded(String)
    case noOutput
    case unexpectedState
    case textTooLong

    var errorDescription: String? {
        switch self {
        case .voiceNotLoaded(let voice): "The voice \(voice) isn't loaded."
        case .noOutput: "The voice model produced no audio."
        case .unexpectedState: "The voice model's files don't match this version of the app."
        case .textTooLong: "A sentence was too long for the voice to read."
        }
    }
}
