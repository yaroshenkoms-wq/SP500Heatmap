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
/// Открывает отдельный экран со списком (41 язык): в выпадающем меню такой длины на iPhone
/// прокрутка выбирала строку под пальцем (жалоба владельца 24.11.2026).
struct LanguageMenu: View {
    @AppStorage(AppLanguage.storageKey) private var selected = ""
    @State private var showPicker = false

    private var currentCode: String { AppLanguage.codes.contains(selected) ? selected : AppLanguage.systemDefault }

    var body: some View {
        Button { showPicker = true } label: {
            Text(verbatim: AppLanguage.shortCode(currentCode))
                .font(Theme.ui(.footnote, weight: .semibold))
                .tracking(0.8)
                .padding(.horizontal, 10)
                .frame(minWidth: 40, minHeight: 34)
                .outlinedControl()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Language"))
        .sheet(isPresented: $showPicker) { LanguagePickerView() }
    }
}

/// Строка «Язык» для настроек: показывает текущий язык и открывает тот же экран выбора.
struct LanguageSettingsRow: View {
    @AppStorage(AppLanguage.storageKey) private var selected = ""
    @State private var showPicker = false

    private var currentCode: String { AppLanguage.codes.contains(selected) ? selected : AppLanguage.systemDefault }

    var body: some View {
        Button { showPicker = true } label: {
            HStack {
                Text("Language").font(Theme.ui(.subheadline)).foregroundColor(Theme.text)
                Spacer()
                Text(verbatim: "\(AppLanguage.shortCode(currentCode))  \(AppLanguage.nativeName(currentCode))")
                    .font(Theme.ui(.subheadline)).foregroundColor(Theme.gold)
                Image(systemName: "chevron.forward").font(.caption).foregroundColor(Theme.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPicker) { LanguagePickerView() }
    }
}

/// Экран выбора языка: прокручиваемый список с поиском; сверху текущий язык и язык телефона.
struct LanguagePickerView: View {
    @AppStorage(AppLanguage.storageKey) private var selected = ""
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var currentCode: String { AppLanguage.codes.contains(selected) ? selected : AppLanguage.systemDefault }

    private var suggested: [String] {
        var out = [currentCode]
        let sys = AppLanguage.systemDefault
        if sys != currentCode { out.append(sys) }
        if !out.contains("en") { out.append("en") }
        return out
    }

    private var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return AppLanguage.codes }
        return AppLanguage.codes.filter { code in
            AppLanguage.nativeName(code).lowercased().contains(q)
                || AppLanguage.shortCode(code).lowercased().contains(q)
                || (Locale(identifier: "en").localizedString(forIdentifier: code) ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section { ForEach(suggested, id: \.self) { row($0) } }
                }
                Section { ForEach(filtered, id: \.self) { row($0) } }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .searchable(text: $query, prompt: Text("Search"))
            .navigationTitle(Text("Language"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text("Done") }.tint(Theme.gold)
                }
            }
        }
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
    }

    private func row(_ code: String) -> some View {
        Button {
            selected = code
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(verbatim: AppLanguage.shortCode(code))
                    .font(Theme.ui(.footnote, weight: .semibold))
                    .foregroundColor(Theme.gold)
                    .frame(width: 34, alignment: .leading)
                Text(verbatim: AppLanguage.nativeName(code))
                    .font(.body)
                    .foregroundColor(Theme.text)
                Spacer()
                if code == currentCode {
                    Image(systemName: "checkmark").foregroundColor(Theme.gold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.panel)
    }
}
