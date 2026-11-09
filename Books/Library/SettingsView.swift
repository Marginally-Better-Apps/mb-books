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
    @State private var isConfirmingVoiceDeletion = false
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
                        Button("Delete Natural Voices", role: .destructive) { isConfirmingVoiceDeletion = true }
                            .accessibilityIdentifier("settings.deleteVoices")
                    }
                } header: {
                    Text("Listening")
                } footer: {
                    Text("Apple voices work right away and read every language. Natural voices read English books and need a one-time \(Self.voiceDownloadSize) download, then work offline.")
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
                    NavigationLink("Acknowledgements") { AcknowledgementsView() }
                } header: {
                    Text("About")
                } footer: {
                    Text("A personal library and reader for EPUB books, including fixed-layout, roll, audio, and video content.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Settings apply as they change, so the sheet only closes.
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier("settings.done")
                }
            }
            .confirmationDialog("Delete Natural Voices?", isPresented: $isConfirmingVoiceDeletion, titleVisibility: .visible) {
                Button("Delete Natural Voices", role: .destructive) { voiceStore.delete() }
            } message: {
                Text("This frees \(Self.voiceDownloadSize). You can download them again later.")
            }
        }
    }

    /// The natural voices' download size, which is also the space they take up once installed.
    static var voiceDownloadSize: String { ByteCountFormatStyle().format(NeuralVoiceCatalog.downloadSize) }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "\(version) (\(build))"
    }
}
