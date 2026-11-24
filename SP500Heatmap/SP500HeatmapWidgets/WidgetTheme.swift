import SwiftUI

// Чёрно-золотая тема для виджетов (те же цвета, что в Theme.swift приложения).
enum WTheme {
    static let bg = Color(red: 0x0B / 255.0, green: 0x0A / 255.0, blue: 0x0D / 255.0)
    static let panel = Color(red: 0x17 / 255.0, green: 0x15 / 255.0, blue: 0x1A / 255.0)
    static let gold = Color(red: 0xC9 / 255.0, green: 0xA9 / 255.0, blue: 0x6E / 255.0)
    static let text = Color(red: 0xED / 255.0, green: 0xE8 / 255.0, blue: 0xDF / 255.0)
    static let muted = Color(red: 0x9C / 255.0, green: 0x96 / 255.0, blue: 0x8A / 255.0)

    /// Виджеты показывают язык, выбранный в приложении (иначе — язык системы).
    static var locale: Locale {
        let code = AppGroup.defaults.string(forKey: "appLanguage") ?? ""
        return code.isEmpty ? .current : Locale(identifier: code)
    }

    static func percent(_ value: Double) -> String { sharedPercent(value, locale: locale) }
}
