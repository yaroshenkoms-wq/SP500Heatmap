import SwiftUI

func pfMoney(_ value: Double, _ code: String, signed: Bool = false) -> String {
    let style = FloatingPointFormatStyle<Double>.Currency(code: code, locale: AppLanguage.locale)
    return signed ? value.formatted(style.sign(strategy: .always())) : value.formatted(style)
}

func pfSignedPercent(_ value: Double) -> String {
    (value / 100).formatted(.percent.precision(.fractionLength(2)).sign(strategy: .always()).locale(AppLanguage.locale))
}

func pfQuantity(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...4)).locale(AppLanguage.locale))
}

func pfCountryName(_ code: String) -> String {
    AppLanguage.locale.localizedString(forRegionCode: code) ?? code
}

/// Подпись из таблицы Localizable с подстановкой значений: pfText("Sold %@ of %@", a, b).
func pfText(_ key: String, _ args: CVarArg...) -> String {
    String(format: AppLanguage.string(key), locale: AppLanguage.locale, arguments: args)
}

/// Число из поля ввода: принимает и точку, и запятую.
func pfParse(_ text: String) -> Double? {
    let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
    return t.isEmpty ? nil : Double(t)
}
