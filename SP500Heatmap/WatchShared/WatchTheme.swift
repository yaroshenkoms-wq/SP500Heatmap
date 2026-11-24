import SwiftUI

/// Чёрно-золотая тема часов (те же цвета, что Theme.swift в iPhone-приложении).
enum WTheme {
    static let bg = Color(red: 0x0B / 255.0, green: 0x0A / 255.0, blue: 0x0D / 255.0)
    static let panel = Color(red: 0x17 / 255.0, green: 0x15 / 255.0, blue: 0x1A / 255.0)
    static let gold = Color(red: 0xC9 / 255.0, green: 0xA9 / 255.0, blue: 0x6E / 255.0)
    static let gold2 = Color(red: 0xE9 / 255.0, green: 0xD3 / 255.0, blue: 0xA4 / 255.0)
    static let text = Color(red: 0xED / 255.0, green: 0xE8 / 255.0, blue: 0xDF / 255.0)
    static let muted = Color(red: 0x9C / 255.0, green: 0x96 / 255.0, blue: 0x8A / 255.0)

    /// Цвет плитки/полоски: та же шкала, что на карте в приложении (зависит от периода).
    static func fill(_ change: Double?, period: String) -> Color {
        SharedHeat.color(for: change, period: period == "1d" ? nil : period)
    }

    static func textColor(_ change: Double?) -> Color {
        guard let change else { return muted }
        return SharedHeat.textColor(for: change)
    }

    /// «+1,2%» — один знак после запятой, в языке системы.
    static func pct(_ value: Double?) -> String {
        guard let value else { return "–" }
        return (value / 100).formatted(.percent.precision(.fractionLength(1))
            .sign(strategy: .always(includingZero: false)))
    }
}
