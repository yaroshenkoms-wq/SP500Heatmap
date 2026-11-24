import Foundation

// Locale-aware number formatting for user-visible values.

/// Percent value given in percent units (1.23 = 1.23%), always 2 decimals.
func formatPercent(_ value: Double) -> String {
    (value / 100).formatted(.percent.precision(.fractionLength(2)).locale(AppLanguage.locale))
}

/// Plain decimal with fixed fraction digits in the current locale.
func formatDecimal(_ value: Double, fractionDigits: Int = 2) -> String {
    value.formatted(.number.precision(.fractionLength(fractionDigits)).grouping(.never).locale(AppLanguage.locale))
}

/// Compact amount with international T / B / M suffixes (digits localized).
func formatCompact(_ value: Double) -> String {
    if value >= 1_000_000_000_000 { return formatDecimal(value / 1_000_000_000_000) + "T" }
    if value >= 1_000_000_000 { return formatDecimal(value / 1_000_000_000) + "B" }
    if value >= 1_000_000 { return formatDecimal(value / 1_000_000) + "M" }
    return formatDecimal(value, fractionDigits: 0)
}

/// Sector / industry names arrive from the server in English; show them
/// localized (table "Sectors"). Unknown names fall back to the English text.
func localizedSectorName(_ name: String) -> String {
    AppLanguage.string(name, table: "Sectors")
}

/// Вес компании в изменении сектора или индекса: капитализация на НАЧАЛО периода (сегодняшняя / (1 + рост)).
/// С весом по сегодняшней капитализации победители раздували итог, особенно на 3–10 годах.
func startWeight(_ cap: Double, _ changePercent: Double) -> Double {
    let growth = 1 + changePercent / 100
    return cap / max(growth, 0.01)
}
