import Foundation
import SwiftUI

// Texts (portfolios_text.json) and data (portfolios_data.json) bundled with the app.
// Both are produced by tools/sync_udak_portfolios.py from the udak.eu data.

struct PortfolioModelText: Decodable {
    let risk: String
    let name: [String: String]
    let short: [String: String]
    let author: [String: String]
    let rationale: [String: String]
    let criticisms: [String: [String]]
    let machine: [String]
    let year: String
    let sources: [String]
}

struct PortfolioText: Decodable {
    let machine: [String]
    let classes: [String: [String: String]]
    let eras: [String: [String: String]]
    let models: [String: PortfolioModelText]
}

struct PortfolioInfo: Identifiable, Hashable {
    let key: String
    let weights: [String: Double]
    let risk: String
    var id: String { key }
}

enum PortfolioSort: String, CaseIterable, Identifiable {
    case cagr, drawdown, risk
    var id: String { rawValue }
}

struct PortfolioRow: Identifiable {
    let info: PortfolioInfo
    let run: PortfolioRun?
    var id: String { info.key }
}

private final class BundleToken {}

final class PortfolioStore: ObservableObject {
    static let shared = PortfolioStore()
    static let referenceKey = "spy"

    let dataset: PortfolioDataset?
    let text: PortfolioText?
    let models: [PortfolioInfo]
    let reference: PortfolioInfo?
    private var engines: [PortfolioCurrency: PortfolioEngine] = [:]
    private var cache: [String: PortfolioRun?] = [:]

    var isAvailable: Bool { dataset != nil && text != nil }

    init(bundle: Bundle = Bundle(for: BundleToken.self)) {
        func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
            guard let url = bundle.url(forResource: name, withExtension: "json") ?? Bundle.main.url(forResource: name, withExtension: "json"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
        let d = load("portfolios_data", as: PortfolioDataset.self)
        dataset = d
        text = load("portfolios_text", as: PortfolioText.self)
        let all = (d?.models ?? []).map { PortfolioInfo(key: $0.key, weights: $0.w, risk: $0.risk) }
        reference = all.first { $0.key == Self.referenceKey }
        models = all.filter { $0.key != Self.referenceKey }
    }

    func engine(_ currency: PortfolioCurrency) -> PortfolioEngine? {
        if let e = engines[currency] { return e }
        guard let dataset else { return nil }
        let e = PortfolioEngine(dataset: dataset, currency: currency)
        engines[currency] = e
        return e
    }

    func info(_ key: String) -> PortfolioInfo? {
        key == Self.referenceKey ? reference : models.first { $0.key == key }
    }

    /// Run over a standard period (cached).
    func run(_ info: PortfolioInfo, period: PortfolioPeriod, currency: PortfolioCurrency, real: Bool) -> PortfolioRun? {
        let k = "\(info.key)|\(period.rawValue)|\(currency.rawValue)|\(real)"
        if let hit = cache[k] { return hit }
        let r = engine(currency)?.run(weights: info.weights, period: period, real: real)
        cache[k] = r
        return r
    }

    /// Run over an arbitrary range (not cached).
    func run(_ info: PortfolioInfo, from: String?, to: String?, currency: PortfolioCurrency, real: Bool) -> PortfolioRun? {
        engine(currency)?.run(weights: info.weights, from: from, to: to, real: real)
    }

    func rows(period: PortfolioPeriod, currency: PortfolioCurrency, real: Bool, sort: PortfolioSort) -> [PortfolioRow] {
        let rows = models.map { PortfolioRow(info: $0, run: run($0, period: period, currency: currency, real: real)) }
        func key(_ r: PortfolioRow) -> Double {
            guard let m = r.run?.metrics else { return .infinity }
            switch sort {
            case .cagr: return -m.cagr
            case .drawdown: return -m.maxDrawdown      // shallowest first
            case .risk: return m.volatility
            }
        }
        return rows.sorted { key($0) < key($1) }
    }

    // MARK: Localized texts

    private func pick<T>(_ dict: [String: T]) -> T? {
        dict[AppLanguage.effectiveCode] ?? dict["en"]
    }

    func name(_ key: String) -> String { text?.models[key].flatMap { pick($0.name) } ?? key }
    func shortText(_ key: String) -> String { text?.models[key].flatMap { pick($0.short) } ?? "" }
    func author(_ key: String) -> String { text?.models[key].flatMap { pick($0.author) } ?? "" }
    func rationale(_ key: String) -> String { text?.models[key].flatMap { pick($0.rationale) } ?? "" }
    func criticisms(_ key: String) -> [String] { text?.models[key].flatMap { pick($0.criticisms) } ?? [] }
    func year(_ key: String) -> String { text?.models[key]?.year ?? "" }
    func sources(_ key: String) -> [String] { text?.models[key]?.sources ?? [] }
    func className(_ c: String) -> String { text?.classes[AppLanguage.effectiveCode]?[c] ?? text?.classes["en"]?[c] ?? c }
    func eraName(_ id: String) -> String { text?.eras[id].flatMap { pick($0) } ?? id }

    /// Descriptions exist only in en/es/fr/ru; other languages get the English text.
    var descriptionsAreEnglishFallback: Bool { !["en", "es", "fr", "ru"].contains(AppLanguage.effectiveCode) }
    /// Model names in this language were translated by machine.
    var namesAreMachineMade: Bool { text?.machine.contains(AppLanguage.effectiveCode) ?? false }
}

// MARK: Formatting helpers (portfolio screens)

enum PortfolioFormat {
    /// Fraction (0.0734) as a percent with one decimal, e.g. 7.3%.
    static func percent(_ v: Double, digits: Int = 1, signed: Bool = false) -> String {
        let f = FloatingPointFormatStyle<Double>.Percent.percent.precision(.fractionLength(digits)).locale(AppLanguage.locale)
        let s = v.formatted(signed ? f.sign(strategy: .always()) : f)
        return s
    }

    static func money(_ v: Double, currency: PortfolioCurrency) -> String {
        v.formatted(.currency(code: currency.rawValue).precision(.fractionLength(0)).locale(AppLanguage.locale))
    }

    /// 12 345 -> 12K, 1.2M ... for chart axes.
    static func moneyCompact(_ v: Double, currency: PortfolioCurrency) -> String {
        v.formatted(.currency(code: currency.rawValue).notation(.compactName).precision(.significantDigits(1...3)).locale(AppLanguage.locale))
    }

    /// "2016-10" -> localized "Oct 2016".
    static func month(_ ym: String) -> String {
        let p = ym.split(separator: "-")
        guard p.count == 2, let y = Int(p[0]), let m = Int(p[1]),
              let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: 1)) else { return ym }
        return date.formatted(.dateTime.month(.abbreviated).year().locale(AppLanguage.locale))
    }

    static func year(_ y: Int) -> String { String(y) }

    /// Decimal year for chart x-axis: "2016-10" -> 2016.75.
    static func decimalYear(_ ym: String) -> Double {
        let p = ym.split(separator: "-")
        guard p.count == 2, let y = Double(p[0]), let m = Double(p[1]) else { return 0 }
        return y + (m - 1) / 12
    }
}
