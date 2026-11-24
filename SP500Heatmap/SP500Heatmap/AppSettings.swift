import SwiftUI
import WidgetKit

/// Размер плиток: по капитализации, одинаковые, по объёму торгов или по обороту (деньги, прошедшие через бумагу).
enum SizeMode: String, CaseIterable, Identifiable {
    case marketCap, equal, volume, turnover

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .marketCap: return "Market cap"
        case .equal: return "Equal"
        case .volume: return "Volume"
        case .turnover: return "Turnover"
        }
    }

    static let storageKey = "sizeMode"

    static var current: SizeMode {
        SizeMode(rawValue: AppGroup.defaults.string(forKey: storageKey) ?? "") ?? .marketCap
    }

    /// Вес плитки там, где объёма нет (мировая карта индексов): капитализация или 1.
    static func weight(_ cap: Double) -> Double {
        current == .equal ? 1 : cap
    }
}

/// Настройки карты. Лежат в App Group, чтобы палитру видели и виджеты.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var palette: ColorPalette {
        didSet {
            AppGroup.defaults.set(palette.rawValue, forKey: ColorPalette.storageKey)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
    @Published var sizeMode: SizeMode {
        didSet { AppGroup.defaults.set(sizeMode.rawValue, forKey: SizeMode.storageKey) }
    }

    private init() {
        palette = ColorPalette.current
        sizeMode = SizeMode.current
    }

    /// Виджеты показывают текст на языке, выбранном в приложении.
    static func mirrorLanguage() {
        AppGroup.defaults.set(AppLanguage.selected, forKey: AppLanguage.storageKey)
    }
}
