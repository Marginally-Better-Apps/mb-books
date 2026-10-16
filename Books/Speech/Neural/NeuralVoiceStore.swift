import CryptoKit
import Foundation
import Observation
import OSLog

/// Downloads, verifies, and removes the neural voice model. Text never leaves the device; only these model
/// files come from the network, once, from pinned URLs with SHA-256 checks.
@Observable
final class NeuralVoiceStore {
    static let shared: NeuralVoiceStore = {
        #if DEBUG
        // Development aid: use an already-downloaded model (`MB_VOICE_MODEL_DIR`), e.g. in screenshot tours.
        if let path = ProcessInfo.processInfo.environment["MB_VOICE_MODEL_DIR"] {
            return NeuralVoiceStore(directory: URL(filePath: path, directoryHint: .isDirectory))
        }
        #endif
        return NeuralVoiceStore()
    }()
    private static let logger = Logger(subsystem: "com.mbbooks.MBBooks", category: "VoiceModel")

    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case ready
        case failed(String)
    }

    private(set) var state: State = .notDownloaded
    private var downloadTask: Task<Void, Never>?
    let directory: URL

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "VoiceModels/\(NeuralVoiceCatalog.modelID)", directoryHint: .isDirectory)) {
        self.directory = directory
        state = FileManager.default.fileExists(atPath: modelURL.path) ? .ready : .notDownloaded
    }

    var modelURL: URL { directory.appending(path: NeuralVoiceCatalog.model.name) }
    var isReady: Bool { state == .ready }

    func voiceURL(_ voice: NeuralVoiceCatalog.Voice) -> URL {
        directory.appending(path: "voices/\(voice.file.name)")
    }

    var downloadedSize: Int64 {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let url = enumerator?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Downloads the model and the default voice.
    func download() {
        guard downloadTask == nil, state != .ready else { return }
        state = .downloading(0)
        downloadTask = Task {
            do {
                try await Self.fetch(NeuralVoiceCatalog.model, to: modelURL) { [weak self] fraction in
                    Task { @MainActor in self?.state = .downloading(fraction * 0.99) }
                }
                _ = try await ensureVoice(NeuralVoiceCatalog.defaultVoice)
                state = .ready
            } catch is CancellationError {
                state = .notDownloaded
            } catch {
                Self.logger.error("Model download failed: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription)
            }
            downloadTask = nil
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    func delete() {
        downloadTask?.cancel()
        try? FileManager.default.removeItem(at: directory)
        state = .notDownloaded
        NeuralSpeechService.shared.unload()
    }

    /// The voice file, downloading it first if needed (each is half a megabyte).
    func ensureVoice(_ voice: NeuralVoiceCatalog.Voice) async throws -> URL {
        let url = voiceURL(voice)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try await Self.fetch(voice.file, to: url, progress: { _ in })
        return url
    }

    // MARK: - Transfers

    /// Runs off the main actor: hashing a 300 MB file takes a few seconds.
    @concurrent
    private nonisolated static func fetch(_ file: NeuralVoiceCatalog.File, to destination: URL,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var root = directory
        try? root.setResourceValues(excluded)

        let delegate = DownloadProgress(expected: file.size, handler: progress)
        let (temporary, response) = try await URLSession.shared.download(from: file.url, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NeuralVoiceError.download(file.name)
        }
        try Task.checkCancellation()
        guard try sha256(of: temporary) == file.sha256 else { throw NeuralVoiceError.checksum(file.name) }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private nonisolated final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let expected: Int64
    let handler: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(expected: Int64, handler: @escaping @Sendable (Double) -> Void) {
        self.expected = expected
        self.handler = handler
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [handler] progress, _ in
            handler(progress.fractionCompleted)
        }
    }
}

nonisolated enum NeuralVoiceError: LocalizedError {
    case download(String)
    case checksum(String)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .download(let name): String(localized: "Couldn't download \(name). Check your connection and try again.")
        case .checksum(let name): String(localized: "\(name) didn't match its expected checksum, so it wasn't installed.")
        case .unavailable: String(localized: "Download the Studio voice model first.")
        }
    }
}

/// The one Kokoro instance, shared by listening and preparing, with listening always first in line.
nonisolated final class NeuralSpeechService: @unchecked Sendable {
    static let shared = NeuralSpeechService()

    enum Priority { case listening, preparing }

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        queue.name = "com.mbbooks.kokoro"
        return queue
    }()
    private let lock = NSLock()
    private var synthesizer: KokoroSynthesizer?
    private var g2p: EnglishG2P?

    /// Synthesizes `text` as 24 kHz mono samples.
    func synthesize(_ text: String, voice: NeuralVoiceCatalog.Voice, modelURL: URL, voiceURL: URL,
                    priority: Priority) async throws -> [Float] {
        try await withCheckedThrowingContinuation { continuation in
            let operation = BlockOperation { [self] in
                do {
                    let synthesizer = try loadedSynthesizer(modelURL: modelURL)
                    if !synthesizer.hasVoice(voice.id) { try synthesizer.loadVoice(id: voice.id, from: voiceURL) }
                    continuation.resume(returning: try synthesizer.synthesize(text, voice: voice.id))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            operation.queuePriority = priority == .listening ? .veryHigh : .low
            operation.qualityOfService = priority == .listening ? .userInitiated : .utility
            queue.addOperation(operation)
        }
    }

    /// The English G2P, loaded once (its dictionaries take a moment).
    func englishG2P() throws -> EnglishG2P {
        lock.lock()
        defer { lock.unlock() }
        if let g2p { return g2p }
        let loaded = try EnglishG2P.bundled()
        g2p = loaded
        return loaded
    }

    private func loadedSynthesizer(modelURL: URL) throws -> KokoroSynthesizer {
        let g2p = try englishG2P()
        lock.lock()
        defer { lock.unlock() }
        if let synthesizer { return synthesizer }
        let loaded = try KokoroSynthesizer(modelURL: modelURL, g2p: g2p)
        synthesizer = loaded
        return loaded
    }

    /// Frees the model's memory, for example after deleting it or on a memory warning.
    func unload() {
        queue.addOperation { [self] in
            lock.lock()
            synthesizer = nil
            lock.unlock()
        }
    }
}
