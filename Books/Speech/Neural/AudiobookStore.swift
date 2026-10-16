import AVFoundation
import CryptoKit
import Foundation

/// Rendered Studio audio for one book and voice: an AAC file per utterance, named by a hash of what's said,
/// so a better extractor later reuses everything that didn't change.
nonisolated struct AudiobookStore: Sendable {
    /// Bump when the model, pronunciation, or encoding changes, so old audio isn't mixed with new.
    static let renderVersion = "kokoro-1.0.g2p-1"
    static let directoryName = "audiobook"

    let directory: URL

    init(bookFolder: URL, voice: NeuralVoiceCatalog.Voice) {
        directory = bookFolder.appending(path: "\(Self.directoryName)/\(voice.id)", directoryHint: .isDirectory)
    }

    func url(for utterance: SpeechUtterance) -> URL {
        let digest = SHA256.hash(data: Data("\(Self.renderVersion)|\(utterance.cacheKey)".utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(name).m4a")
    }

    func contains(_ utterance: SpeechUtterance) -> Bool {
        FileManager.default.fileExists(atPath: url(for: utterance).path)
    }

    /// Encodes samples as AAC. The file appears only once it's complete, so a crash never leaves half a sentence.
    func write(_ samples: [Float], for utterance: SpeechUtterance) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = url(for: utterance)
        let temporary = directory.appending(path: ".\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let format = Self.format, let buffer = Self.buffer(samples, format: format) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let file = try AVAudioFile(forWriting: temporary, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: NeuralVoiceCatalog.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 40_000,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    func read(_ utterance: SpeechUtterance) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url(for: utterance), commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: buffer)
        return buffer
    }

    func readSamples(_ utterance: SpeechUtterance) throws -> [Float] {
        let buffer = try read(utterance)
        guard let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: NeuralVoiceCatalog.sampleRate, channels: 1, interleaved: false)

    static func buffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count))) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        }
        return buffer
    }

    // MARK: - Whole books

    static func size(bookFolder: URL) -> Int64 {
        let root = bookFolder.appending(path: directoryName, directoryHint: .isDirectory)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let url = enumerator?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func remove(bookFolder: URL) {
        try? FileManager.default.removeItem(at: bookFolder.appending(path: directoryName, directoryHint: .isDirectory))
    }

    /// The share of a script's text already rendered.
    func progress(of script: SpeechScript) -> Double {
        let total = script.characterCount
        guard total > 0 else { return 0 }
        var done = 0
        for chapter in script.readableChapters {
            for utterance in chapter.utterances where contains(utterance) { done += utterance.text.count }
        }
        return Double(done) / Double(total)
    }
}
