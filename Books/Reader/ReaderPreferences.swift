import SwiftUI
import UIKit

/// The six Apple Books themes. Each has light and dark palettes and its own customizable typography.
enum ReaderThemeID: String, Codable, CaseIterable, Identifiable {
    case original, quiet, paper, bold, calm, focus

    var id: String { rawValue }

    var name: LocalizedStringKey {
        switch self {
        case .original: "Original"
        case .quiet: "Quiet"
        case .paper: "Paper"
        case .bold: "Bold"
        case .calm: "Calm"
        case .focus: "Focus"
        }
    }

    /// The typography a theme starts with, and returns to on "Reset Theme".
    var defaultStyle: ThemeStyle {
        switch self {
        case .original: ThemeStyle()
        case .quiet: ThemeStyle(font: .original)
        case .paper: ThemeStyle(font: .charter, lineSpacing: 1.5)
        case .bold: ThemeStyle(font: .sanFrancisco, boldText: true)
        case .calm: ThemeStyle(font: .athelas, lineSpacing: 1.6)
        case .focus: ThemeStyle(font: .newYork, lineSpacing: 1.55)
        }
    }

    func palette(dark: Bool) -> ThemePalette {
        switch (self, dark) {
        case (.original, false): ThemePalette(background: 0xFFFFFF, text: 0x111111, secondary: 0x8A8A8E, link: 0x0A60D9)
        case (.original, true): ThemePalette(background: 0x121212, text: 0xEDEDED, secondary: 0x8E8E93, link: 0x4C9DFF)
        case (.quiet, false): ThemePalette(background: 0x4A4A4D, text: 0xD6D6D6, secondary: 0xA0A0A5, link: 0x9CC3FF)
        case (.quiet, true): ThemePalette(background: 0x2B2B2D, text: 0xA8A8AC, secondary: 0x75757A, link: 0x7FAEEA)
        case (.paper, false): ThemePalette(background: 0xF2EFE8, text: 0x1E1D1B, secondary: 0x8B877F, link: 0x2F5FAE)
        case (.paper, true): ThemePalette(background: 0x232220, text: 0xDEDBD3, secondary: 0x8D8A83, link: 0x89AEE8)
        case (.bold, false): ThemePalette(background: 0xFFFFFF, text: 0x000000, secondary: 0x6E6E73, link: 0x0040DD)
        case (.bold, true): ThemePalette(background: 0x000000, text: 0xFFFFFF, secondary: 0x98989D, link: 0x5EA1FF)
        case (.calm, false): ThemePalette(background: 0xF4E8CE, text: 0x3D2E1F, secondary: 0x9A8466, link: 0x8A4B12)
        case (.calm, true): ThemePalette(background: 0x332A21, text: 0xE5D6BB, secondary: 0x9D8B70, link: 0xE0A867)
        case (.focus, false): ThemePalette(background: 0xFFFBEF, text: 0x262420, secondary: 0x9C968A, link: 0x7A5200)
        case (.focus, true): ThemePalette(background: 0x1B1A17, text: 0xE9E3D2, secondary: 0x8F897C, link: 0xE4BE6A)
        }
    }

    /// Whether publisher colors are respected. Only Original in light appearance leaves them alone.
    func overridesPublisherColors(dark: Bool) -> Bool { self != .original || dark }
}

struct ThemePalette: Equatable {
    let background: UInt32
    let text: UInt32
    let secondary: UInt32
    let link: UInt32

    var backgroundColor: Color { Color(hex: background) }
    var textColor: Color { Color(hex: text) }
    var secondaryColor: Color { Color(hex: secondary) }

    /// Whether this palette reads as dark, for status bar and system chrome.
    var isDark: Bool {
        let r = Double((background >> 16) & 0xFF), g = Double((background >> 8) & 0xFF), b = Double(background & 0xFF)
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255 < 0.5
    }
}

enum ReaderFont: String, Codable, CaseIterable, Identifiable {
    case original, athelas, charter, georgia, iowan, newYork, palatino, sanFrancisco, seravek, timesNewRoman

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original: String(localized: "Original")
        case .athelas: "Athelas"
        case .charter: "Charter"
        case .georgia: "Georgia"
        case .iowan: "Iowan"
        case .newYork: "New York"
        case .palatino: "Palatino"
        case .sanFrancisco: "San Francisco"
        case .seravek: "Seravek"
        case .timesNewRoman: "Times New Roman"
        }
    }

    /// The CSS `font-family` value, or `nil` to keep the publisher's fonts.
    var cssFamily: String? {
        switch self {
        case .original: nil
        case .athelas: "Athelas, Georgia, serif"
        case .charter: "Charter, 'Charter BT', Georgia, serif"
        case .georgia: "Georgia, serif"
        case .iowan: "'Iowan Old Style', Georgia, serif"
        case .newYork: "ui-serif, 'New York', Georgia, serif"
        case .palatino: "Palatino, 'Palatino Linotype', serif"
        case .sanFrancisco: "-apple-system, system-ui, sans-serif"
        case .seravek: "Seravek, -apple-system, sans-serif"
        case .timesNewRoman: "'Times New Roman', Times, serif"
        }
    }

    /// A SwiftUI font for rendering the font's own name in pickers.
    func previewFont(size: CGFloat) -> Font {
        switch self {
        case .original: .system(size: size)
        case .newYork: .system(size: size, design: .serif)
        case .sanFrancisco: .system(size: size)
        case .athelas: .custom("Athelas-Regular", size: size)
        case .charter: .custom("Charter-Roman", size: size)
        case .georgia: .custom("Georgia", size: size)
        case .iowan: .custom("IowanOldStyle-Roman", size: size)
        case .palatino: .custom("Palatino-Roman", size: size)
        case .seravek: .custom("Seravek", size: size)
        case .timesNewRoman: .custom("TimesNewRomanPSMT", size: size)
        }
    }
}

/// Typography for a theme. `nil` spacing values keep the publisher's styles.
struct ThemeStyle: Codable, Equatable {
    var font: ReaderFont = .original
    var boldText = false
    var lineSpacing: Double?
    var characterSpacing: Double = 0
    var wordSpacing: Double = 0
    /// Horizontal page margins as a multiple of the default.
    var margins: Double = 1
    var justify = false
    var allowMultipleColumns = true

    static let lineSpacingRange = 1.0...2.4
    static let characterSpacingRange = 0.0...0.2
    static let wordSpacingRange = 0.0...0.5
    static let marginsRange = 0.25...2.5
}

/// Apple Books' page turn options, in its menu order.
enum PageTurnStyle: String, Codable, CaseIterable, Identifiable {
    case slide, curl, fade, scroll

    var id: String { rawValue }

    var name: LocalizedStringKey {
        switch self {
        case .curl: "Curl"
        case .slide: "Slide"
        case .fade: "Fast Fade"
        case .scroll: "Scroll"
        }
    }

    var systemImage: String {
        switch self {
        case .curl: "book.pages"
        case .slide: "rectangle.portrait.on.rectangle.portrait.angled"
        case .fade: "circle.dashed"
        case .scroll: "arrow.up.and.down.text.horizontal"
        }
    }
}

/// Global reader settings, shared by every book like in Apple Books.
struct ReaderPreferences: Codable, Equatable {
    static let fontScales: [Double] = [0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.35, 1.5, 1.7, 1.9, 2.2, 2.5, 3.0]

    var theme: ReaderThemeID = .original
    var fontScaleIndex = 3
    var pageTurn: PageTurnStyle = .slide
    var styles: [ReaderThemeID: ThemeStyle] = [:]

    var fontScale: Double { Self.fontScales[min(max(fontScaleIndex, 0), Self.fontScales.count - 1)] }

    var style: ThemeStyle {
        get { styles[theme] ?? theme.defaultStyle }
        set { styles[theme] = newValue }
    }

    func style(for theme: ReaderThemeID) -> ThemeStyle { styles[theme] ?? theme.defaultStyle }

    var isStyleCustomized: Bool { style != theme.defaultStyle }

    mutating func resetTheme() { styles[theme] = nil }

    // MARK: Persistence

    private static let key = "readerPreferences"

    static func load(from defaults: UserDefaults = .standard) -> ReaderPreferences {
        guard let data = defaults.data(forKey: key),
              let preferences = try? JSONDecoder().decode(ReaderPreferences.self, from: data)
        else { return ReaderPreferences() }
        return preferences
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

extension UInt32 {
    var cssHex: String { String(format: "#%06X", self) }
}
