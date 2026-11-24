import SwiftUI
import WidgetKit

/// Размер плиток: по капитализации или одинаковые.
enum SizeMode: String, CaseIterable {
    case marketCap, equal

    static let storageKey = "sizeMode"

    static var current: SizeMode {
        SizeMode(rawValue: AppGroup.defaults.string(forKey: storageKey) ?? "") ?? .marketCap
    }

    /// Вес плитки в карте: капитализация или 1 (внутри своего родителя).
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
