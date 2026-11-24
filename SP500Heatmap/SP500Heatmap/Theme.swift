import SwiftUI

/// Тёмная «чёрно-золотая» тема, как в PlanEditor: цвета, шрифты, стили чипов и кнопок.
enum Theme {
    static let bg = Color(hex: 0x0B0A0D)
    static let bg2 = Color(hex: 0x141215)
    static let panel = Color(hex: 0x17151A)
    static let bg3 = Color(hex: 0x1B181D)
    static let chip = Color(hex: 0x25222B)
    static let line = Color(hex: 0xEDE8DF, opacity: 0.13)
    static let goldLine = Color(hex: 0xC9A96E, opacity: 0.55)
    static let gold = Color(hex: 0xC9A96E)
    static let gold2 = Color(hex: 0xE9D3A4)
    static let text = Color(hex: 0xEDE8DF)
    static let muted = Color(hex: 0x9C968A)
    static let ok = Color(hex: 0x8FBF9A)
    static let danger = Color(hex: 0xE08E7F)

    static let radius: CGFloat = 8

    static func changeColor(_ value: Double) -> Color { SharedHeat.textColor(for: value) }

    // MARK: Шрифты

    // Geist (латиница + кириллица) и Instrument Serif (только латиница) лежат в бандле.
    // Для остальных языков (zh-Hans, ar, bn, hi) и для кириллических заголовков
    // берётся системный шрифт, чтобы не было квадратиков-«тофу».
    // Языки, все буквы которых есть в Geist / Instrument Serif (проверено fontTools 24.11.2026); остальные — системный шрифт.
    private static let geistLanguages: Set<String> = ["en", "es", "fr", "ru", "uk", "de", "nl", "sv", "da", "nb", "fi", "pt-BR", "pt-PT", "it", "ca", "id", "ms", "bg"]
    private static let serifLanguages: Set<String> = ["en", "es", "fr", "de", "nl", "sv", "da", "nb", "fi", "pt-BR", "pt-PT", "it", "ca", "id", "ms"]

    private static var code: String { AppLanguage.effectiveCode }
    static var usesGeist: Bool { geistLanguages.contains(code) }
    static var usesInstrumentSerif: Bool { serifLanguages.contains(code) }

    private static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline, .body: return 17
        case .callout: return 16
        case .subheadline: return 15
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        default: return 17
        }
    }

    /// Основной шрифт интерфейса (Geist 400–600).
    static func ui(_ style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
        guard usesGeist else { return .system(style).weight(weight) }
        let name: String
        switch weight {
        case .semibold, .bold, .heavy, .black: name = "Geist-SemiBold"
        case .medium: name = "Geist-Medium"
        default: name = "Geist-Regular"
        }
        return .custom(name, size: baseSize(style), relativeTo: style)
    }

    /// Шрифт заголовков (Instrument Serif, только regular).
    static func serif(_ style: Font.TextStyle = .largeTitle, scale: CGFloat = 1) -> Font {
        guard usesInstrumentSerif else {
            return scale == 1 ? .system(style, design: .serif)
                              : .system(size: baseSize(style) * scale, weight: .regular, design: .serif)
        }
        // Instrument Serif узкий и визуально мельче, поэтому размер чуть крупнее.
        return .custom("InstrumentSerif-Regular", size: baseSize(style) * 1.12 * scale, relativeTo: style)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

extension View {
    /// Фон экрана.
    func themeScreen() -> some View {
        background(Theme.bg.ignoresSafeArea())
    }

    /// Карточка/панель: заливка panel и тонкая рамка.
    func panelCard() -> some View {
        self
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line, lineWidth: 1))
    }

    /// Контурная кнопка 8pt с золотым акцентом.
    func outlinedControl(gold: Bool = true) -> some View {
        self
            .foregroundColor(gold ? Theme.gold : Theme.text)
            .background(Theme.bg2, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(gold ? Theme.goldLine : Theme.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    /// Чип периода: выбранный — золотая рамка и золотой текст.
    func themeChip(selected: Bool) -> some View {
        self
            .font(Theme.ui(.caption, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundColor(selected ? Theme.gold : Theme.muted)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(selected ? Theme.goldLine : Theme.line, lineWidth: 1))
    }

    /// Тёмная панель навигации для экранов с системным заголовком.
    func themeNavBar() -> some View {
        self
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

/// Стиль кнопки: контур 8pt, золото.
struct OutlinedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(.subheadline, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .outlinedControl()
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
