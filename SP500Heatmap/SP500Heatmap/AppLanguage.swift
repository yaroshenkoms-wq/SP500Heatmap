import SwiftUI

/// Язык интерфейса, выбранный внутри приложения ("" = как в системе).
/// Text("ключ") берёт язык из окружения (\.locale); строки из кода и форматирование чисел —
/// через `AppLanguage.bundle` и `AppLanguage.locale`.
enum AppLanguage {
    static let storageKey = "appLanguage"

    /// Порядок по правилу владельца: английский и испанский первые, русский не выше 6–7 места.
    static let codes = ["en", "es", "zh-Hans", "ar", "fr", "bn", "hi", "ru", "uk"]

    /// Название языка на нём самом.
    static func nativeName(_ code: String) -> String {
        let name = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    static var selected: String { UserDefaults.standard.string(forKey: storageKey) ?? "" }

    /// Код языка, на котором реально показывается интерфейс.
    static var effectiveCode: String {
        if codes.contains(selected) { return selected }
        return Bundle.main.preferredLocalizations.first ?? "en"
    }

    static var locale: Locale {
        if codes.contains(selected) {
            // Язык выбран в приложении, регион (формат дат, валюта) оставляем системный.
            var comps = Locale.Components(locale: .current)
            comps.languageComponents = Locale.Language.Components(identifier: selected)
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

/// Кнопка выбора языка (глобус) для главного экрана.
struct LanguageMenu: View {
    @AppStorage(AppLanguage.storageKey) private var selected = ""

    var body: some View {
        Menu {
            Picker(selection: $selected) {
                Text("System language").tag("")
                ForEach(AppLanguage.codes, id: \.self) { code in
                    Text(verbatim: AppLanguage.nativeName(code)).tag(code)
                }
            } label: {
                Text("Language")
            }
        } label: {
            Image(systemName: "globe")
                .font(.body)
                .foregroundColor(.blue)
                .frame(width: 34, height: 34)
                .background(Color.blue.opacity(0.12), in: Circle())
        }
        .accessibilityLabel(Text("Language"))
    }
}
