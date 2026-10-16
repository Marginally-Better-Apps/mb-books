import SwiftUI

/// "Themes & Settings": font size, page turn, appearance, theme presets, and per-theme customization.
struct ThemesView: View {
    @Bindable var model: ReaderModel

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system

    /// Whether the reader is full width on iPad, where sheets are smaller cards and half height
    /// would cut off Customize. Read from the reader, since a sheet can report a compact width.
    var isRegularWidth = false

    private var compactHeight: PresentationDetent { isRegularWidth ? .height(480) : .medium }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    controls
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(ReaderThemeID.allCases) { theme in
                            ThemeTile(
                                theme: theme,
                                style: model.preferences.style(for: theme),
                                palette: theme.palette(dark: model.isDarkAppearance),
                                isSelected: model.preferences.theme == theme
                            ) {
                                model.preferences.theme = theme
                            }
                        }
                    }
                    NavigationLink {
                        CustomizeThemeView(model: model)
                    } label: {
                        Label("Customize", systemImage: "gearshape")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("themes.customize")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .navigationTitle("Themes & Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .presentationDetents([compactHeight, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: compactHeight))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                Button { model.decreaseFontSize() } label: {
                    Text("A").font(.system(size: 15, weight: .medium)).frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(model.preferences.fontScaleIndex == 0)
                .accessibilityLabel("Decrease Font Size")
                Divider().frame(height: 24)
                Button { model.increaseFontSize() } label: {
                    Text("A").font(.system(size: 22, weight: .medium)).frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(model.preferences.fontScaleIndex == ReaderPreferences.fontScales.count - 1)
                .accessibilityLabel("Increase Font Size")
                .accessibilityIdentifier("themes.increaseFont")
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)

            Menu {
                Picker("Page Turn", selection: $model.preferences.pageTurn) {
                    // Fixed layouts always turn pages; rolls always scroll.
                    ForEach(PageTurnStyle.allCases.filter { !model.isFixedLayout || $0 != .scroll }) { style in
                        Label(style.name, systemImage: style.systemImage).tag(style)
                    }
                }
            } label: {
                Image(systemName: model.effectivePageTurn.systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 52, height: 44)
            }
            .glassEffect(.regular.interactive(), in: .capsule)
            .disabled(model.publication.layout == .roll)
            .accessibilityLabel("Page Turn")
            .accessibilityIdentifier("themes.pageTurn")

            Menu {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Label(option.title, systemImage: option.systemImage).tag(option)
                    }
                }
            } label: {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 52, height: 44)
            }
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityLabel("Appearance")
        }
        .foregroundStyle(.primary)
    }
}

private struct ThemeTile: View {
    let theme: ReaderThemeID
    let style: ThemeStyle
    let palette: ThemePalette
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 4) {
                Text("Aa")
                    .font(style.font.previewFont(size: 30))
                    .fontWeight(style.boldText ? .bold : .regular)
                Text(theme.name)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(palette.textColor)
            .frame(maxWidth: .infinity, minHeight: 88)
            .background(palette.backgroundColor, in: .rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 3 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("theme.\(theme.rawValue)")
    }
}

struct CustomizeThemeView: View {
    @Bindable var model: ReaderModel

    var body: some View {
        Form {
            Section("Text") {
                Picker("Font", selection: $model.preferences.style.font) {
                    ForEach(ReaderFont.allCases) { font in
                        Text(font.displayName).font(font.previewFont(size: 17)).tag(font)
                    }
                }
                .pickerStyle(.navigationLink)
                Toggle("Bold Text", isOn: $model.preferences.style.boldText)
            }

            Section("Accessibility & Layout Options") {
                SpacingSlider(
                    title: "Line Spacing",
                    value: Binding(
                        get: { model.preferences.style.lineSpacing ?? 1.4 },
                        set: { model.preferences.style.lineSpacing = $0 }),
                    range: ThemeStyle.lineSpacingRange, isDefault: model.preferences.style.lineSpacing == nil)
                SpacingSlider(
                    title: "Character Spacing", value: $model.preferences.style.characterSpacing,
                    range: ThemeStyle.characterSpacingRange, isDefault: model.preferences.style.characterSpacing == 0)
                SpacingSlider(
                    title: "Word Spacing", value: $model.preferences.style.wordSpacing,
                    range: ThemeStyle.wordSpacingRange, isDefault: model.preferences.style.wordSpacing == 0)
                SpacingSlider(
                    title: "Margins", value: $model.preferences.style.margins,
                    range: ThemeStyle.marginsRange, isDefault: model.preferences.style.margins == 1)
                Toggle("Justify Text", isOn: $model.preferences.style.justify)
                Toggle("Allow Multiple Columns", isOn: $model.preferences.style.allowMultipleColumns)
            }

            Section {
                Button("Reset Theme", role: .destructive) { model.preferences.resetTheme() }
                    .disabled(!model.preferences.isStyleCustomized)
            }
        }
        .navigationTitle(Text("Customize \(Text(model.preferences.theme.name))"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SpacingSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let isDefault: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                if isDefault {
                    Text("Default").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Slider(value: $value, in: range)
                .accessibilityLabel(Text(title))
        }
    }
}
