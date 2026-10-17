import CryptoKit
import Foundation
import Observation
import OSLog

/// Downloads, verifies, and removes the natural voice model. Text never leaves the device; only these model
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
    nonisolated static let modelsRoot = URL.applicationSupportDirectory.appending(path: "VoiceModels", directoryHint: .isDirectory)

    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case ready
        case failed(String)
    }

    private(set) var state: State = .notDownloaded
    private var downloadTask: Task<Void, Never>?
    let directory: URL

    init(directory: URL = NeuralVoiceStore.modelsRoot.appending(path: NeuralVoiceCatalog.modelID, directoryHint: .isDirectory)) {
        self.directory = directory
        state = isInstalled ? .ready : .notDownloaded
    }

    var modelURL: URL { directory.appending(path: NeuralVoiceCatalog.model.name) }
    var isReady: Bool { state == .ready }
    var isDownloading: Bool { if case .downloading = state { true } else { false } }

    private var isInstalled: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
            && NeuralVoiceCatalog.voices.allSatisfy { FileManager.default.fileExists(atPath: voiceURL($0).path) }
    }

    func voiceURL(_ voice: NeuralVoiceCatalog.Voice) -> URL {
        directory.appending(path: "voices/\(voice.file.name)")
    }

    /// Downloads the model and every voice, so switching voices later works offline.
    func download() {
        guard downloadTask == nil, state != .ready else { return }
        state = .downloading(0)
        downloadTask = Task {
            do {
                let total = Double(NeuralVoiceCatalog.downloadSize)
                let modelShare = Double(NeuralVoiceCatalog.model.size) / total
                if !FileManager.default.fileExists(atPath: modelURL.path) {
                    try await Self.fetch(NeuralVoiceCatalog.model, to: modelURL) { [weak self] fraction in
                        Task { @MainActor in self?.state = .downloading(fraction * modelShare) }
                    }
                }
                for (index, voice) in NeuralVoiceCatalog.voices.enumerated() where !FileManager.default.fileExists(atPath: voiceURL(voice).path) {
                    try await Self.fetch(voice.file, to: voiceURL(voice), progress: { _ in })
                    state = .downloading(modelShare + (1 - modelShare) * Double(index + 1) / Double(NeuralVoiceCatalog.voices.count))
                }
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

    /// Removes files from earlier versions: the larger full-precision model and prepared audiobooks.
    @concurrent
    nonisolated static func removeRetiredFiles(bookFolders: [URL]) async {
        for id in NeuralVoiceCatalog.retiredModelIDs {
            try? FileManager.default.removeItem(at: modelsRoot.appending(path: id, directoryHint: .isDirectory))
        }
        for folder in bookFolders {
            try? FileManager.default.removeItem(at: folder.appending(path: "audiobook", directoryHint: .isDirectory))
        }
    }

    // MARK: - Transfers

    /// Runs off the main actor: hashing a large file takes a moment.
    @concurrent
    private nonisolated static func fetch(_ file: NeuralVoiceCatalog.File, to destination: URL,
                                          progress: @escaping @Sendable (Double) -> Void) async throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var root = modelsRoot
        try? root.setResourceValues(excluded)

        let delegate = DownloadProgress(handler: progress)
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
    let handler: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(handler: @escaping @Sendable (Double) -> Void) {
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
        case .unavailable: String(localized: "Download the natural voices first.")
        }
    }
}

/// The one Kokoro instance. Renders a sentence at a time, at full priority, on the performance cores.
nonisolated final class NeuralSpeechService: @unchecked Sendable {
    static let shared = NeuralSpeechService()

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        // Utility or background work lands on efficiency cores, several times slower; listening can't wait.
        queue.qualityOfService = .userInitiated
        queue.name = "com.mbbooks.kokoro"
        return queue
    }()
    private let lock = NSLock()
    private var synthesizer: KokoroSynthesizer?
    private var g2p: EnglishG2P?
    /// Bumped to drop queued requests nobody wants anymore, such as after skipping ahead.
    private var generation = 0

    var currentGeneration: Int {
        lock.withLock { generation }
    }

    /// Abandons queued requests: they finish immediately with `CancellationError`.
    func cancelQueued() {
        lock.withLock { generation += 1 }
    }

    /// Loads the dictionaries and model ahead of the first sentence.
    func prewarm(modelURL: URL) {
        queue.addOperation { [self] in _ = try? loadedSynthesizer(modelURL: modelURL) }
    }

    /// Synthesizes `text` as 24 kHz mono samples.
    func synthesize(_ text: String, voice: NeuralVoiceCatalog.Voice, modelURL: URL, voiceURL: URL) async throws -> [Float] {
        let requested = currentGeneration
        return try await withCheckedThrowingContinuation { continuation in
            queue.addOperation { [self] in
                guard requested == currentGeneration else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    let synthesizer = try loadedSynthesizer(modelURL: modelURL)
                    if !synthesizer.hasVoice(voice.id) { try synthesizer.loadVoice(id: voice.id, from: voiceURL) }
                    continuation.resume(returning: try synthesizer.synthesize(text, voice: voice.id))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
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
        cancelQueued()
        queue.addOperation { [self] in
            lock.withLock { synthesizer = nil }
        }
    }
}
