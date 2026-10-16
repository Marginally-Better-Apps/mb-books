import SwiftData
import SwiftUI

struct SettingsView: View {
    static let repositoryURL = URL(string: "https://github.com/Marginally-Better-Apps/mb-books")!

    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryStore.self) private var library
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system
    @AppStorage(GoalDefaults.dailyMinutesKey) private var dailyGoal = GoalDefaults.dailyMinutes
    @AppStorage(GoalDefaults.yearlyBooksKey) private var yearlyGoal = GoalDefaults.yearlyBooks
    @Query private var books: [Book]
    @State private var audiobookSize: Int64 = 0
    private var voiceStore: NeuralVoiceStore { .shared }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .accessibilityIdentifier("settings.appearance")
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Reading themes adapt to light and dark appearance. Choose themes and fonts from the reading menu.")
                }

                Section("Reading Goals") {
                    Stepper(value: $dailyGoal, in: 1...240) {
                        LabeledContent("Daily Goal", value: String(localized: "\(dailyGoal) min"))
                    }
                    Stepper(value: $yearlyGoal, in: 1...365) {
                        LabeledContent("Books Per Year", value: "\(yearlyGoal)")
                    }
                }

                Section {
                    VoiceModelRow()
                    if voiceStore.isReady {
                        Button("Delete Studio Voice", role: .destructive) { voiceStore.delete() }
                    }
                    LabeledContent("Prepared Audiobooks", value: ByteCountFormatStyle().format(audiobookSize))
                    if audiobookSize > 0 {
                        Button("Delete Prepared Audiobooks", role: .destructive) {
                            for book in books { AudiobookStore.remove(bookFolder: library.storage.folder(for: book.id)) }
                            audiobookSize = 0
                        }
                    }
                    NavigationLink("Acknowledgements") { AcknowledgementsView() }
                } header: {
                    Text("Listening")
                } footer: {
                    Text("Listening works offline. Studio voices need a one-time download and read English books.")
                }

                Section("Library") {
                    LabeledContent("Books", value: "\(books.count)")
                    LabeledContent("Storage", value: ByteCountFormatStyle().format(books.reduce(0) { $0 + $1.fileSize }))
                }

                Section {
                    Link(destination: Self.repositoryURL) {
                        HStack {
                            Label("MB Books on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.footnote).foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityIdentifier("settings.github")
                    LabeledContent("Version", value: Self.version)
                    LabeledContent("Format", value: "EPUB 3.4")
                } header: {
                    Text("About")
                } footer: {
                    Text("A personal library and reader for EPUB books, including fixed-layout, roll, audio, and video content.")
                }
            }
            .task {
                let folders = books.map { library.storage.folder(for: $0.id) }
                audiobookSize = await Task.detached { folders.reduce(0) { $0 + AudiobookStore.size(bookFolder: $1) } }.value
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                        .accessibilityIdentifier("settings.done")
                }
            }
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "\(version) (\(build))"
    }
}
