import SwiftUI

/// Язык интерфейса, выбранный внутри приложения ("" = как в системе).
/// Text("ключ") берёт язык из окружения (\.locale); строки из кода и форматирование чисел —
/// через `AppLanguage.bundle` и `AppLanguage.locale`.
enum AppLanguage {
    static let storageKey = "appLanguage"

    /// Порядок по правилу владельца: английский и испанский первые, русский не выше 6–7 места.
    // 41 язык (как в PlanEditor + бенгальский). Порядок: английский и испанский первыми, русский — 7-й (правило владельца).
    static let codes = ["en", "es", "fr", "de", "pt-BR", "it", "ru", "uk", "pl", "nl", "ca", "pt-PT", "zh-Hans", "zh-Hant", "ja", "ko", "ar", "he", "hi", "bn", "tr", "sv", "da", "nb", "fi", "cs", "sk", "ro", "hu", "el", "bg", "hr", "sr-Latn", "sl", "lt", "lv", "et", "id", "ms", "vi", "th"]

    /// Название языка на нём самом.
    static func nativeName(_ code: String) -> String {
        let name = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Выбранный пользователем язык; "" — не выбирал (ничего не хранится до первого выбора).
    static var selected: String { UserDefaults.standard.string(forKey: storageKey) ?? "" }

    /// Язык системы, если он есть в приложении, иначе английский.
    static var systemDefault: String {
        let sys = Bundle.main.preferredLocalizations.first ?? "en"
        return codes.contains(sys) ? sys : "en"
    }

    /// Код языка, на котором реально показывается интерфейс.
    static var effectiveCode: String {
        codes.contains(selected) ? selected : systemDefault
    }

    /// Короткий код для кнопки: EN, ES, ZH, AR, FR, BN, HI, RU, UK.
    static func shortCode(_ code: String) -> String {
        switch code {
        case "zh-Hans": return "ZH"
        case "zh-Hant": return "TW"
        case "pt-BR": return "BR"
        case "pt-PT": return "PT"
        case "sr-Latn": return "SR"
        case "nb": return "NO"
        default: return code.uppercased()
        }
    }

    static var locale: Locale {
        // Язык выбран в приложении (или системный не из девяти — тогда английский);
        // регион (формат дат, валюта) оставляем системный.
        let sys = Bundle.main.preferredLocalizations.first ?? "en"
        if codes.contains(selected) || !codes.contains(sys) {
            var comps = Locale.Components(locale: .current)
            comps.languageComponents = Locale.Language.Components(identifier: effectiveCode)
            return Locale(components: comps)
        }
        return .current
    }

    static var bundle: Bundle {
        guard codes.contains(selected),
              let path = Bundle.main.path(forResource: selected, ofType: "lproj"),
              let b = Bundle(path: path) else { return .main }
        return b
    }

    static var isRightToLeft: Bool {
        Locale.Language(identifier: effectiveCode).characterDirection == .rightToLeft
    }

    static func string(_ key: String, table: String? = nil) -> String {
        bundle.localizedString(forKey: key, value: key, table: table)
    }
}

/// Кнопка выбора языка для главного экрана: контурная плашка с кодом текущего языка.
struct LanguageMenu: View {
    @AppStorage(AppLanguage.storageKey) private var selected = ""

    // Пока пользователь не выбирал, показываем язык системы (или английский) и ничего не пишем.
    private var current: Binding<String> {
        Binding(get: { AppLanguage.codes.contains(selected) ? selected : AppLanguage.systemDefault },
                set: { selected = $0 })
    }

    var body: some View {
        Menu {
            Picker(selection: current) {
                ForEach(AppLanguage.codes, id: \.self) { code in
                    Text(verbatim: "\(AppLanguage.shortCode(code))  \(AppLanguage.nativeName(code))").tag(code)
                }
            } label: {
                Text("Language")
            }
        } label: {
            Text(verbatim: AppLanguage.shortCode(current.wrappedValue))
                .font(Theme.ui(.footnote, weight: .semibold))
                .tracking(0.8)
                .padding(.horizontal, 10)
                .frame(minWidth: 40, minHeight: 34)
                .outlinedControl()
        }
        .accessibilityLabel(Text("Language"))
    }
}
