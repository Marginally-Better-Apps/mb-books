import Accelerate
import Foundation

/// Spells out words the pronunciation dictionary doesn't know (names, coinages) with a tiny
/// grapheme-to-phoneme transformer: `PeterReid/graphemes_to_phonemes_en_us`, the model misaki uses for the
/// same job (Apache 2.0, 751k parameters). It runs here in plain Swift with Accelerate, so there's no
/// espeak-ng, which is GPL-licensed.
nonisolated final class G2PFallback: @unchecked Sendable {
    private static let graphemes = Array("____AIOWYbdfhijklmnpstuvwz'-.BCDEFGHJKLMNPQRSTUVXZacegoqrxy")
    private static let phonemes = Array("____AIOWYbdfhijklmnpstuvwzæðŋɑɔəɛɜɡɪɹɾʃʊʌʒʔʤʧˈˌθᵊᵻ")
    private static let model = 128
    private static let feedForward = 1024
    private static let maxPositions = 64
    private static let bos = 1, eos = 2, unknown = 3

    private let weights: SafeTensors
    /// Linear layer weights transposed to `[input, output]` for `vDSP_mmul`.
    private let transposed: [String: [Float]]
    private let tokenIndex: [Character: Int]
    private let lock = NSLock()
    private var cache: [String: String] = [:]

    init(url: URL) throws {
        weights = try SafeTensors(url: url)
        var transposed: [String: [Float]] = [:]
        for name in weights.names where name.hasSuffix("proj.weight") || name.hasSuffix("fc1.weight") || name.hasSuffix("fc2.weight") {
            let shape = weights.shape(name)
            guard shape.count == 2 else { continue }
            transposed[name] = Self.transpose(weights[name], rows: shape[0], columns: shape[1])
        }
        self.transposed = transposed
        var index: [Character: Int] = [:]
        for (position, character) in Self.graphemes.enumerated() { index[character] = position }
        tokenIndex = index
    }

    static func bundled() throws -> G2PFallback {
        guard let url = Bundle.main.url(forResource: "g2p-en-us", withExtension: "safetensors")
            ?? Bundle(for: G2PFallback.self).url(forResource: "g2p-en-us", withExtension: "safetensors")
        else { throw CocoaError(.fileNoSuchFile) }
        return try G2PFallback(url: url)
    }

    /// Phonemes in misaki's notation, such as "hɝmˈIəni" for "Hermione".
    func phonemes(for word: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[word] { return cached }
        let input = [Self.bos] + word.prefix(Self.maxPositions - 2).map { tokenIndex[$0] ?? Self.unknown } + [Self.eos]
        let encoded = encode(input)
        var output = [Self.bos]
        while output.count < Self.maxPositions {
            let next = decodeNext(output, encoded: encoded, sourceLength: input.count)
            if next == Self.eos { break }
            output.append(next)
        }
        let result = String(output.dropFirst().compactMap { $0 > 3 && $0 < Self.phonemes.count ? Self.phonemes[$0] : nil })
        cache[word] = result
        return result
    }

    // MARK: - Transformer

    private func embed(_ tokens: [Int], prefix: String) -> [Float] {
        let d = Self.model
        let table = weights["model.shared.weight"]
        let positions = weights["\(prefix).embed_positions.weight"]
        var x = [Float](repeating: 0, count: tokens.count * d)
        for (row, token) in tokens.enumerated() {
            for column in 0..<d {
                // BART's learned positions start at offset 2.
                x[row * d + column] = table[token * d + column] + positions[(row + 2) * d + column]
            }
        }
        layerNorm(&x, rows: tokens.count, name: "\(prefix).layernorm_embedding")
        return x
    }

    private func encode(_ tokens: [Int]) -> [Float] {
        var x = embed(tokens, prefix: "model.encoder")
        let layer = "model.encoder.layers.0"
        let attended = attention(query: x, keyValue: x, rows: tokens.count, keyRows: tokens.count, causal: false,
                                 name: "\(layer).self_attn")
        add(&x, attended)
        layerNorm(&x, rows: tokens.count, name: "\(layer).self_attn_layer_norm")
        let ff = feedForwardBlock(x, rows: tokens.count, layer: layer)
        add(&x, ff)
        layerNorm(&x, rows: tokens.count, name: "\(layer).final_layer_norm")
        return x
    }

    private func decodeNext(_ tokens: [Int], encoded: [Float], sourceLength: Int) -> Int {
        let rows = tokens.count
        var y = embed(tokens, prefix: "model.decoder")
        let layer = "model.decoder.layers.0"
        let selfAttended = attention(query: y, keyValue: y, rows: rows, keyRows: rows, causal: true, name: "\(layer).self_attn")
        add(&y, selfAttended)
        layerNorm(&y, rows: rows, name: "\(layer).self_attn_layer_norm")
        let crossAttended = attention(query: y, keyValue: encoded, rows: rows, keyRows: sourceLength, causal: false,
                                      name: "\(layer).encoder_attn")
        add(&y, crossAttended)
        layerNorm(&y, rows: rows, name: "\(layer).encoder_attn_layer_norm")
        let ff = feedForwardBlock(y, rows: rows, layer: layer)
        add(&y, ff)
        layerNorm(&y, rows: rows, name: "\(layer).final_layer_norm")
        // Logits for the last position only, against the tied embedding matrix.
        let d = Self.model
        let last = Array(y[(rows - 1) * d..<rows * d])
        let table = weights["model.shared.weight"]
        let bias = weights["final_logits_bias"]
        var best = Self.eos
        var bestScore = -Float.infinity
        for token in 0..<Self.phonemes.count {
            var score = bias[token]
            for column in 0..<d { score += last[column] * table[token * d + column] }
            if token != 0, score > bestScore {
                bestScore = score
                best = token
            }
        }
        return best
    }

    /// Single-head attention, as configured in this model.
    private func attention(query: [Float], keyValue: [Float], rows: Int, keyRows: Int, causal: Bool, name: String) -> [Float] {
        let d = Self.model
        var q = linear(query, rows: rows, input: d, output: d, name: "\(name).q_proj")
        let k = linear(keyValue, rows: keyRows, input: d, output: d, name: "\(name).k_proj")
        let v = linear(keyValue, rows: keyRows, input: d, output: d, name: "\(name).v_proj")
        var scale = 1 / Float(d).squareRoot()
        vDSP_vsmul(q, 1, &scale, &q, 1, vDSP_Length(q.count))
        var scores = [Float](repeating: 0, count: rows * keyRows)
        vDSP_mmul(q, 1, Self.transpose(k, rows: keyRows, columns: d), 1, &scores, 1,
                  vDSP_Length(rows), vDSP_Length(keyRows), vDSP_Length(d))
        for row in 0..<rows {
            let base = row * keyRows
            var maximum = -Float.infinity
            for column in 0..<keyRows {
                if causal, column > row { scores[base + column] = -Float.infinity }
                maximum = max(maximum, scores[base + column])
            }
            var sum: Float = 0
            for column in 0..<keyRows {
                let value = scores[base + column] == -Float.infinity ? 0 : exp(scores[base + column] - maximum)
                scores[base + column] = value
                sum += value
            }
            for column in 0..<keyRows { scores[base + column] /= sum }
        }
        var context = [Float](repeating: 0, count: rows * d)
        vDSP_mmul(scores, 1, v, 1, &context, 1, vDSP_Length(rows), vDSP_Length(d), vDSP_Length(keyRows))
        return linear(context, rows: rows, input: d, output: d, name: "\(name).out_proj")
    }

    private func feedForwardBlock(_ x: [Float], rows: Int, layer: String) -> [Float] {
        var hidden = linear(x, rows: rows, input: Self.model, output: Self.feedForward, name: "\(layer).fc1")
        for index in hidden.indices {
            // Exact GELU, as in the original model.
            let value = hidden[index]
            hidden[index] = 0.5 * value * (1 + erf(value / Float(2).squareRoot()))
        }
        return linear(hidden, rows: rows, input: Self.feedForward, output: Self.model, name: "\(layer).fc2")
    }

    /// `x · Wᵀ + b`, with PyTorch's `[output, input]` weight layout.
    private func linear(_ x: [Float], rows: Int, input: Int, output: Int, name: String) -> [Float] {
        guard let weight = transposed["\(name).weight"] else { preconditionFailure("Missing tensor \(name)") }
        let bias = weights["\(name).bias"]
        var result = [Float](repeating: 0, count: rows * output)
        vDSP_mmul(x, 1, weight, 1, &result, 1, vDSP_Length(rows), vDSP_Length(output), vDSP_Length(input))
        for row in 0..<rows {
            for column in 0..<output { result[row * output + column] += bias[column] }
        }
        return result
    }

    private static func transpose(_ matrix: [Float], rows: Int, columns: Int) -> [Float] {
        var result = [Float](repeating: 0, count: matrix.count)
        vDSP_mtrans(matrix, 1, &result, 1, vDSP_Length(columns), vDSP_Length(rows))
        return result
    }

    private func layerNorm(_ x: inout [Float], rows: Int, name: String) {
        let d = Self.model
        let gamma = weights["\(name).weight"]
        let beta = weights["\(name).bias"]
        for row in 0..<rows {
            let base = row * d
            var mean: Float = 0
            for column in 0..<d { mean += x[base + column] }
            mean /= Float(d)
            var variance: Float = 0
            for column in 0..<d {
                let delta = x[base + column] - mean
                variance += delta * delta
            }
            variance /= Float(d)
            let inverse = 1 / (variance + 1e-5).squareRoot()
            for column in 0..<d {
                x[base + column] = (x[base + column] - mean) * inverse * gamma[column] + beta[column]
            }
        }
    }

    private func add(_ x: inout [Float], _ y: [Float]) {
        vDSP_vadd(x, 1, y, 1, &x, 1, vDSP_Length(x.count))
    }
}

/// Reads float32 tensors from a `.safetensors` file.
nonisolated struct SafeTensors: Sendable {
    private let tensors: [String: [Float]]
    private let shapes: [String: [Int]]

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count > 8 else { throw CocoaError(.fileReadCorruptFile) }
        let headerLength = data.prefix(8).enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
        guard headerLength > 0, 8 + headerLength <= data.count,
              let header = try JSONSerialization.jsonObject(with: data.subdata(in: 8..<(8 + headerLength))) as? [String: Any]
        else { throw CocoaError(.fileReadCorruptFile) }
        let base = 8 + headerLength
        var tensors: [String: [Float]] = [:]
        var shapes: [String: [Int]] = [:]
        for (name, value) in header where name != "__metadata__" {
            guard let info = value as? [String: Any], info["dtype"] as? String == "F32",
                  let offsets = info["data_offsets"] as? [Int], offsets.count == 2,
                  base + offsets[1] <= data.count
            else { continue }
            let slice = data.subdata(in: (base + offsets[0])..<(base + offsets[1]))
            tensors[name] = slice.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            shapes[name] = info["shape"] as? [Int] ?? []
        }
        self.tensors = tensors
        self.shapes = shapes
    }

    var names: [String] { Array(tensors.keys) }

    func shape(_ name: String) -> [Int] { shapes[name] ?? [] }

    subscript(name: String) -> [Float] {
        guard let tensor = tensors[name] else { preconditionFailure("Missing tensor \(name)") }
        return tensor
    }
}
