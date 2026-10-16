import AVFoundation
import SwiftData
import SwiftUI

@main
struct MBBooksApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system
    @State private var library: LibraryStore
    private let container: ModelContainer

    init() {
        let launch = LaunchConfiguration.current
        if launch.isUITesting {
            UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        }
        // Core Data doesn't create Application Support on a fresh install.
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        do {
            container = try ModelContainer(
                for: Book.self, BookCollection.self, Annotation.self, ReadingDay.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: launch.isUITesting))
        } catch {
            fatalError("Couldn't open the library database: \(error)")
        }
        _library = State(initialValue: LibraryStore(storage: launch.makeStorage()))
        // Books with audio or video should play even when the ring/silent switch is on.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(OrientationLock.shared)
                .preferredColorScheme(appearance.colorScheme)
                .task { await LaunchConfiguration.current.seedIfNeeded(library: library, context: container.mainContext) }
        }
        .modelContainer(container)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.shared.mask
    }
}

/// Launch arguments used by UI tests: an isolated in-memory library, optionally seeded with a sample book.
struct LaunchConfiguration {
    let isUITesting: Bool
    let seedsSampleBook: Bool
    /// Development aid: imports every EPUB in a directory at launch (`-import-directory <path>`).
    let importDirectory: URL?

    static let current: LaunchConfiguration = {
        let arguments = ProcessInfo.processInfo.arguments
        #if DEBUG
        let directory = arguments.firstIndex(of: "-import-directory")
            .flatMap { arguments.indices.contains($0 + 1) ? URL(filePath: arguments[$0 + 1]) : nil }
        #else
        let directory: URL? = nil
        #endif
        return LaunchConfiguration(
            isUITesting: arguments.contains("-ui-testing"),
            seedsSampleBook: arguments.contains("-seed-sample-book"),
            importDirectory: directory)
    }()

    /// UI tests get a fresh, empty library folder on every launch.
    func makeStorage() -> BookStorage {
        guard isUITesting else { return .shared }
        let root = FileManager.default.temporaryDirectory.appending(path: "UITestLibrary", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: root)
        return BookStorage(root: root)
    }

    func seedIfNeeded(library: LibraryStore, context: ModelContext) async {
        if let importDirectory, (try? context.fetchCount(FetchDescriptor<Book>())) == 0 {
            let files = (try? FileManager.default.contentsOfDirectory(at: importDirectory, includingPropertiesForKeys: nil)) ?? []
            await library.importBooks(from: files.filter { $0.pathExtension == "epub" }.sorted { $0.path < $1.path }, into: context)
        }
        guard seedsSampleBook, (try? context.fetchCount(FetchDescriptor<Book>())) == 0 else { return }
        let url = FileManager.default.temporaryDirectory.appending(path: "Sample Book.epub")
        do {
            try SampleBook.make().write(to: url)
            await library.importBooks(from: [url], into: context)
        } catch {
            library.importError = .init(fileName: url.lastPathComponent, message: error.localizedDescription)
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearance"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}

/// Locks the interface to its current orientation while reading.
@Observable
final class OrientationLock {
    static let shared = OrientationLock()

    private(set) var isLocked = false
    private(set) var mask: UIInterfaceOrientationMask = .all

    func toggle() {
        isLocked ? unlock() : lock()
    }

    func lock() {
        guard let scene = activeScene else { return }
        mask = switch scene.effectiveGeometry.interfaceOrientation {
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        case .portraitUpsideDown: .portraitUpsideDown
        default: .portrait
        }
        isLocked = true
        update(scene)
    }

    func unlock() {
        guard isLocked else { return }
        mask = .all
        isLocked = false
        if let scene = activeScene { update(scene) }
    }

    private var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
    }

    private func update(_ scene: UIWindowScene) {
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }
}
