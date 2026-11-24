import Foundation
import SwiftUI

// Код, общий для приложения и виджетов: App Group, снимок данных для виджетов, палитра.

enum AppGroup {
    static let id = "group.com.maximyaroshenko.SP500Heatmap2"

    /// Общие настройки (палитра, избранное, язык) — читают и приложение, и виджеты.
    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }
}

// MARK: Снимок данных для виджетов (widget_snapshot.json в контейнере App Group)

struct WidgetSnapshot: Codable {
    struct Idx: Codable, Identifiable {
        let id: String
        let name: String
        let country: String?
        let capUSD: Double?
        let changes: [String: Double]
    }
    struct Region: Codable, Identifiable {
        let id: String
        let indices: [Idx]
        var drawable: [Idx] {
            indices.filter { ($0.capUSD ?? 0) > 0 }.sorted { ($0.capUSD ?? 0) > ($1.capUSD ?? 0) }
        }
        var totalCap: Double { drawable.reduce(0) { $0 + ($1.capUSD ?? 0) } }
    }
    struct Fav: Codable, Identifiable {
        var id: String { ticker }
        let ticker: String
        let name: String
        let indexId: String
        let price: Double?
        let currency: String?
        let changes: [String: Double]
    }

    var updated: Date = Date()
    var asOf: String?
    var regions: [Region] = []
    var favorites: [Fav] = []

    var allIndices: [Idx] { regions.flatMap { $0.indices } }
    var drawableRegions: [Region] {
        regions.filter { !$0.drawable.isEmpty }.sorted { $0.totalCap > $1.totalCap }
    }
}

enum SnapshotIO {
    private static var url: URL? { AppGroup.containerURL?.appendingPathComponent("widget_snapshot.json") }

    static func read() -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    static func write(_ snapshot: WidgetSnapshot) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: Палитра

enum ColorPalette: String, CaseIterable {
    case redGreen
    case blueOrange   // для дальтоников: синий — рост, оранжевый — падение

    static let storageKey = "colorPalette"

    static var current: ColorPalette {
        ColorPalette(rawValue: AppGroup.defaults.string(forKey: storageKey) ?? "") ?? .redGreen
    }
}

enum SharedHeat {
    // % изменения, при котором цвет достигает полной насыщенности.
    static let cap = 3.0

    private typealias RGB = (r: Double, g: Double, b: Double)
    private static let neutral: RGB = (0x2A / 255.0, 0x27 / 255.0, 0x30 / 255.0)

    static func up(_ palette: ColorPalette) -> (r: Double, g: Double, b: Double) {
        switch palette {
        case .redGreen: return (0x36 / 255.0, 0x8C / 255.0, 0x56 / 255.0)
        case .blueOrange: return (0x2F / 255.0, 0x7F / 255.0, 0xC8 / 255.0)
        }
    }

    static func down(_ palette: ColorPalette) -> (r: Double, g: Double, b: Double) {
        switch palette {
        case .redGreen: return (0xB4 / 255.0, 0x4A / 255.0, 0x40 / 255.0)
        case .blueOrange: return (0xD9 / 255.0, 0x82 / 255.0, 0x26 / 255.0)
        }
    }

    /// % изменения, при котором цвет достигает полной насыщенности, для периода (SC = 1d).
    static func cap(forPeriod period: String?) -> Double {
        switch period {
        case "3d": return 5
        case "7d": return 7
        case "30d": return 12
        case "180d": return 25
        case "1y": return 35
        case "3y": return 60
        case "5y": return 80
        case "10y": return 150
        default: return cap
        }
    }

    static func color(for change: Double?, period: String?, palette: ColorPalette = .current) -> Color {
        color(for: change, palette: palette, cap: cap(forPeriod: period))
    }

    static func color(for change: Double?, palette: ColorPalette = .current, cap: Double = SharedHeat.cap) -> Color {
        guard let change else { return Color(red: neutral.r, green: neutral.g, blue: neutral.b) }
        let t = max(-1.0, min(1.0, change / cap))
        let target = t >= 0 ? up(palette) : down(palette)
        let f = abs(t)
        return Color(red: neutral.r + (target.r - neutral.r) * f,
                     green: neutral.g + (target.g - neutral.g) * f,
                     blue: neutral.b + (target.b - neutral.b) * f)
    }

    /// Цвет цифры «+1,2%» на тёмном фоне (списки, строки).
    static func textColor(for change: Double, palette: ColorPalette = .current) -> Color {
        switch palette {
        case .redGreen: return change >= 0 ? Color(red: 0x8F / 255.0, green: 0xBF / 255.0, blue: 0x9A / 255.0)
                                           : Color(red: 0xE0 / 255.0, green: 0x8E / 255.0, blue: 0x7F / 255.0)
        case .blueOrange: return change >= 0 ? Color(red: 0x7F / 255.0, green: 0xB8 / 255.0, blue: 0xEE / 255.0)
                                             : Color(red: 0xF0 / 255.0, green: 0xA8 / 255.0, blue: 0x5C / 255.0)
        }
    }
}

// MARK: Мелочи

func countryFlag(_ country: String?) -> String {
    var code = (country ?? "").uppercased()
    if code == "UK" { code = "GB" }
    guard code.count == 2 else { return "🌐" }
    let base: UInt32 = 0x1F1E6 - 65
    var result = ""
    for scalar in code.unicodeScalars {
        guard let flagScalar = UnicodeScalar(base + scalar.value) else { return "🌐" }
        result.unicodeScalars.append(flagScalar)
    }
    return result
}

/// Процент в единицах процента (1.23 = 1.23%) с двумя знаками и знаком «+».
func sharedPercent(_ value: Double, locale: Locale = .current) -> String {
    (value / 100).formatted(.percent.precision(.fractionLength(2)).sign(strategy: .always(includingZero: false)).locale(locale))
}
