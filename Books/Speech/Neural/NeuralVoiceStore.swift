import AppleArchive
import CryptoKit
import Foundation
import Observation
import OSLog
import System

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

    var isReady: Bool { state == .ready }
    var isDownloading: Bool { if case .downloading = state { true } else { false } }

    /// An archived model, unpacked: "FlowLM.mlmodelc.aar" becomes "FlowLM.mlmodelc".
    private func modelURL(_ file: NeuralVoiceCatalog.File) -> URL {
        directory.appending(path: String(file.name.dropLast(".aar".count)), directoryHint: .isDirectory)
    }

    private var isInstalled: Bool {
        NeuralVoiceCatalog.models.allSatisfy { FileManager.default.fileExists(atPath: modelURL($0).path) }
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
                var done: Int64 = 0
                for model in NeuralVoiceCatalog.models {
                    if !FileManager.default.fileExists(atPath: modelURL(model).path) {
                        let start = Double(done) / total
                        let share = Double(model.size) / total
                        let archive = directory.appending(path: model.name)
                        try await Self.fetch(model, to: archive) { [weak self] fraction in
                            Task { @MainActor in self?.state = .downloading(start + fraction * share) }
                        }
                        try await Self.install(archive, at: modelURL(model))
                    }
                    done += model.size
                    state = .downloading(Double(done) / total)
                }
                for voice in NeuralVoiceCatalog.voices {
                    if !FileManager.default.fileExists(atPath: voiceURL(voice).path) {
                        try await Self.fetch(voice.file, to: voiceURL(voice), progress: { _ in })
                    }
                    done += voice.size
                    state = .downloading(Double(done) / total)
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

    /// Removes files from earlier versions: the Kokoro models and prepared audiobooks.
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

    /// Unpacks a model archive beside `destination`, then moves it into place. An unpack cut short (say, by the app
    /// being closed) leaves only the staging folder, so the model never looks installed when it's incomplete.
    @concurrent
    private nonisolated static func install(_ archive: URL, at destination: URL) async throws {
        let fileManager = FileManager.default
        let staging = destination.deletingLastPathComponent().appending(path: ".staging", directoryHint: .isDirectory)
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        try await extract(archive, into: staging)
        let unpacked = staging.appending(path: destination.lastPathComponent, directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: unpacked.path) else { throw NeuralVoiceError.download(archive.lastPathComponent) }
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: unpacked, to: destination)
    }

    /// Unpacks an Apple Archive into `directory`, then deletes it.
    @concurrent
    private nonisolated static func extract(_ archive: URL, into directory: URL) async throws {
        defer { try? FileManager.default.removeItem(at: archive) }
        guard let file = ArchiveByteStream.fileStream(path: FilePath(archive.path), mode: .readOnly, options: [],
                                                      permissions: FilePermissions(rawValue: 0o644)) else {
            throw NeuralVoiceError.download(archive.lastPathComponent)
        }
        defer { try? file.close() }
        guard let decompressed = ArchiveByteStream.decompressionStream(readingFrom: file) else {
            throw NeuralVoiceError.download(archive.lastPathComponent)
        }
        defer { try? decompressed.close() }
        guard let decoder = ArchiveStream.decodeStream(readingFrom: decompressed) else {
            throw NeuralVoiceError.download(archive.lastPathComponent)
        }
        defer { try? decoder.close() }
        guard let extractor = ArchiveStream.extractStream(extractingTo: FilePath(directory.path),
                                                          flags: [.ignoreOperationNotPermitted]) else {
            throw NeuralVoiceError.download(archive.lastPathComponent)
        }
        defer { try? extractor.close() }
        _ = try ArchiveStream.process(readingFrom: decoder, writingTo: extractor)
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
    /// The models or a voice can't be loaded, so no sentence can be read.
    case unusable(String)

    var errorDescription: String? {
        switch self {
        case .download(let name): String(localized: "Couldn't download \(name). Check your connection and try again.")
        case .checksum(let name): String(localized: "\(name) didn't match its expected checksum, so it wasn't installed.")
        case .unavailable: String(localized: "Download the natural voices first.")
        case .unusable(let reason): String(localized: "The natural voices couldn't start: \(reason) Try an Apple voice, or delete and download the natural voices again in Settings.")
        }
    }
}

/// The one Pocket TTS instance. Renders a sentence at a time, at full priority.
nonisolated final class NeuralSpeechService: @unchecked Sendable {
    static let shared = NeuralSpeechService()

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        // Utility or background work lands on efficiency cores, several times slower; listening can't wait.
        queue.qualityOfService = .userInitiated
        queue.name = "com.mbbooks.pocket"
        return queue
    }()
    private let lock = NSLock()
    private var synthesizer: PocketSynthesizer?
    /// Bumped to drop queued requests nobody wants anymore, such as after skipping ahead.
    private var generation = 0

    var currentGeneration: Int {
        lock.withLock { generation }
    }

    /// Abandons queued requests: they finish immediately with `CancellationError`, and the one rendering stops.
    func cancelQueued() {
        lock.withLock { generation += 1 }
    }

    /// Loads the models ahead of the first sentence.
    func prewarm(directory: URL) {
        queue.addOperation { [self] in _ = try? loadedSynthesizer(directory: directory) }
    }

    /// Synthesizes `text` as 24 kHz mono samples, with when each word starts.
    func synthesize(_ text: String, voice: NeuralVoiceCatalog.Voice, directory: URL, voiceURL: URL) async throws -> PocketSynthesizer.Speech {
        let requested = currentGeneration
        return try await withCheckedThrowingContinuation { continuation in
            queue.addOperation { [self] in
                guard requested == currentGeneration else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    let synthesizer: PocketSynthesizer
                    do {
                        synthesizer = try loadedSynthesizer(directory: directory)
                        if !synthesizer.hasVoice(voice.id) { try synthesizer.loadVoice(id: voice.id, from: voiceURL) }
                    } catch {
                        throw NeuralVoiceError.unusable(error.localizedDescription)
                    }
                    let speech = try synthesizer.synthesize(text, voice: voice.id) { requested != self.currentGeneration }
                    continuation.resume(returning: speech)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func loadedSynthesizer(directory: URL) throws -> PocketSynthesizer {
        lock.lock()
        defer { lock.unlock() }
        if let synthesizer { return synthesizer }
        let loaded = try PocketSynthesizer(directory: directory, tokenizer: PocketTokenizer.bundled())
        synthesizer = loaded
        return loaded
    }

    /// Frees the models' memory, for example after deleting them or on a memory warning.
    func unload() {
        cancelQueued()
        queue.addOperation { [self] in
            lock.withLock { synthesizer = nil }
        }
    }
}
