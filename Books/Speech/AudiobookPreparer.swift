import BackgroundTasks
import Foundation
import Observation
import OSLog

/// Prepares Studio audiobooks ahead of time: renders every sentence of a book with the neural voice and saves it,
/// so listening later is instant and costs no battery. One book at a time, resumable, and it keeps going in the
/// background (iOS shows its progress) after the reader starts it.
@Observable
final class AudiobookPreparer {
    static let shared = AudiobookPreparer()
    private static let logger = Logger(subsystem: "com.mbbooks.MBBooks", category: "Prepare")
    private static let taskPrefix = "com.mbbooks.MBBooks.prepare."

    struct Job: Identifiable, Equatable {
        enum Phase: Equatable {
            case queued
            case reading
            case rendering
            case finished
            case paused
            case failed(String)
        }

        let id: UUID
        let title: String
        let voice: NeuralVoiceCatalog.Voice
        var phase: Phase = .queued
        var fraction: Double = 0
        /// Estimated seconds left, once there's a rate to go by.
        var remaining: TimeInterval?
        var renderedSeconds: Double = 0
    }

    private(set) var jobs: [Job] = []
    private var worker: Task<Void, Never>?
    private var requests: [UUID: Request] = [:]
    private var backgroundTask: BGContinuedProcessingTask?
    /// Whether a background task was requested and hasn't finished.
    private var hasRequestedTask = false

    private struct Request {
        let storage: BookStorage
        let author: String
    }

    func job(for bookID: UUID) -> Job? {
        jobs.first { $0.id == bookID }
    }

    var activeJob: Job? {
        jobs.first { $0.phase == .reading || $0.phase == .rendering }
    }

    /// Queues a book. Already-rendered sentences are kept, so this also resumes.
    func prepare(bookID: UUID, title: String, author: String, voice: NeuralVoiceCatalog.Voice, storage: BookStorage) {
        requests[bookID] = Request(storage: storage, author: author)
        if let index = jobs.firstIndex(where: { $0.id == bookID }) {
            jobs[index].phase = .queued
        } else {
            jobs.append(Job(id: bookID, title: title, voice: voice))
        }
        submitBackgroundTask(title: title)
        runNext()
    }

    func pause(bookID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == bookID }) else { return }
        let wasActive = jobs[index].phase == .reading || jobs[index].phase == .rendering
        jobs[index].phase = .paused
        jobs[index].remaining = nil
        if wasActive {
            worker?.cancel()
            worker = nil
            runNext()
        }
    }

    func cancel(bookID: UUID) {
        pause(bookID: bookID)
        jobs.removeAll { $0.id == bookID }
    }

    private func runNext() {
        guard worker == nil else { return }
        guard let index = jobs.firstIndex(where: { $0.phase == .queued }) else {
            finishBackgroundTask(success: true)
            return
        }
        let job = jobs[index]
        guard let request = requests[job.id] else {
            jobs[index].phase = .failed(String(localized: "The book is no longer available."))
            runNext()
            return
        }
        worker = Task {
            await render(job, request: request)
            worker = nil
            runNext()
        }
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
        if let active = activeJob, active.id == id, let backgroundTask {
            backgroundTask.progress.totalUnitCount = 1000
            backgroundTask.progress.completedUnitCount = Int64(active.fraction * 1000)
        }
    }

    private func render(_ job: Job, request: Request) async {
        update(job.id) { $0.phase = .reading }
        let container = request.storage.container(for: job.id)
        let publication: Publication
        do {
            publication = try await Task.detached { try EPUBParser.parse(container) }.value
        } catch {
            update(job.id) { $0.phase = .failed(error.localizedDescription) }
            return
        }
        guard NeuralVoiceCatalog.supports(language: publication.metadata.language) else {
            update(job.id) { $0.phase = .failed(String(localized: "Studio voices read English only.")) }
            return
        }
        let store = NeuralVoiceStore.shared
        guard store.isReady else {
            update(job.id) { $0.phase = .failed(NeuralVoiceError.unavailable.localizedDescription) }
            return
        }
        let folder = request.storage.folder(for: job.id)
        let provider = SpeechScriptProvider(
            publication: publication, container: container, folder: folder.appending(path: "speech", directoryHint: .isDirectory))
        let script = await provider.script()
        guard !Task.isCancelled else { return }

        let audio = AudiobookStore(bookFolder: folder, voice: job.voice)
        let utterances = script.readableChapters.flatMap(\.utterances)
        let total = max(1, utterances.reduce(0) { $0 + $1.text.count })
        var done = utterances.filter { audio.contains($0) }.reduce(0) { $0 + $1.text.count }
        update(job.id) {
            $0.phase = .rendering
            $0.fraction = Double(done) / Double(total)
        }
        let voiceURL: URL
        do {
            voiceURL = try await store.ensureVoice(job.voice)
        } catch {
            update(job.id) { $0.phase = .failed(error.localizedDescription) }
            return
        }
        let started = Date.now
        var renderedCharacters = 0
        for utterance in utterances {
            guard !Task.isCancelled else { return }
            if audio.contains(utterance) { continue }
            do {
                let samples = try await NeuralSpeechService.shared.synthesize(
                    utterance.text, voice: job.voice, modelURL: store.modelURL, voiceURL: voiceURL, priority: .preparing)
                if !samples.isEmpty {
                    try await Task.detached(priority: .utility) { try audio.write(samples, for: utterance) }.value
                }
                let seconds = Double(samples.count) / NeuralVoiceCatalog.sampleRate
                done += utterance.text.count
                renderedCharacters += utterance.text.count
                let elapsed = Date.now.timeIntervalSince(started)
                let rate = Double(renderedCharacters) / max(elapsed, 0.001)
                update(job.id) {
                    $0.fraction = Double(done) / Double(total)
                    $0.renderedSeconds += seconds
                    $0.remaining = elapsed > 20 ? Double(total - done) / rate : nil
                }
            } catch {
                Self.logger.error("Couldn't render a sentence: \(error.localizedDescription, privacy: .public)")
            }
        }
        update(job.id) {
            $0.phase = .finished
            $0.fraction = 1
            $0.remaining = nil
        }
    }

    // MARK: - Background

    /// Asks iOS to keep preparing after the app leaves the screen, with a progress indicator.
    private func submitBackgroundTask(title: String) {
        guard !hasRequestedTask else { return }
        hasRequestedTask = true
        let identifier = Self.taskPrefix + UUID().uuidString
        let scheduler = BGTaskScheduler.shared
        _ = scheduler.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            MainActor.assumeIsolated { self?.adopt(task) }
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: String(localized: "Preparing Audiobook"), subtitle: title)
        request.strategy = .queue
        do {
            try scheduler.submit(request)
        } catch {
            // Not available (for example in the simulator): preparing continues while the app is open.
            Self.logger.info("Continued processing unavailable: \(error.localizedDescription, privacy: .public)")
            hasRequestedTask = false
        }
    }

    private func adopt(_ task: BGContinuedProcessingTask) {
        backgroundTask = task
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = Int64((activeJob?.fraction ?? 0) * 1000)
        task.expirationHandler = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // iOS needs the time back; pause, keeping everything rendered so far.
                if let active = self.activeJob { self.pause(bookID: active.id) }
                self.backgroundTask = nil
                self.hasRequestedTask = false
            }
        }
        if worker == nil, !jobs.contains(where: { $0.phase == .queued }) { finishBackgroundTask(success: true) }
    }

    private func finishBackgroundTask(success: Bool) {
        guard let backgroundTask else { return }
        hasRequestedTask = false
        backgroundTask.progress.completedUnitCount = backgroundTask.progress.totalUnitCount
        backgroundTask.setTaskCompleted(success: success)
        self.backgroundTask = nil
    }
}
