import Foundation

// Данные и результат ИИ-обзоров. Ничего здесь не зависит от FoundationModels,
// поэтому всё тестируется без модели.

struct AIHeadline: Codable, Hashable, Identifiable {
    var title: String
    var publisher: String?
    var url: String?
    var ticker: String?
    var id: String { url ?? title }
}

/// Пара «название — изменение в %» (индекс, сектор, бумага).
struct AINamedChange: Codable, Hashable {
    var name: String
    var change: Double
}

/// Итог по портфолио, посчитанный из позиций (без модели).
struct PortfolioInsightHolding: Codable, Hashable {
    var ticker: String
    var name: String
    var sector: String
    var country: String
    var weightPct: Double       // доля в портфеле, %
    var dayChangePct: Double    // изменение за день, %
    var totalPLPct: Double      // результат с момента покупки, %

    init(ticker: String, name: String, sector: String, country: String,
         weightPct: Double, dayChangePct: Double, totalPLPct: Double) {
        self.ticker = ticker; self.name = name; self.sector = sector; self.country = country
        self.weightPct = weightPct; self.dayChangePct = dayChangePct; self.totalPLPct = totalPLPct
    }
}

struct AIPortfolioSummary: Codable, Hashable {
    var count: Int
    var dayChangePct: Double
    var totalPLPct: Double
    var largest: AINamedChange?          // change = доля в портфеле
    var largestDay: Double?              // изменение за день крупнейшей позиции
    var bestContributor: AINamedChange?  // change = вклад в дневной результат, п.п.
    var worstContributor: AINamedChange?
    var topSector: AINamedChange?        // change = доля
    var topCountry: AINamedChange?

    static func make(_ holdings: [PortfolioInsightHolding]) -> AIPortfolioSummary? {
        let h = holdings.filter { $0.weightPct > 0 }
        let total = h.reduce(0) { $0 + $1.weightPct }
        guard !h.isEmpty, total > 0 else { return nil }
        func w(_ x: PortfolioInsightHolding) -> Double { x.weightPct / total }
        let day = h.reduce(0) { $0 + w($1) * $1.dayChangePct }
        let pl = h.reduce(0) { $0 + w($1) * $1.totalPLPct }
        let largest = h.max { $0.weightPct < $1.weightPct }!
        func contrib(_ x: PortfolioInsightHolding) -> Double { w(x) * x.dayChangePct }
        let best = h.max { contrib($0) < contrib($1) }!
        let worst = h.min { contrib($0) < contrib($1) }!
        func top(_ key: (PortfolioInsightHolding) -> String) -> AINamedChange? {
            var sums: [String: Double] = [:]
            for x in h where !key(x).isEmpty { sums[key(x), default: 0] += 100 * w(x) }
            return sums.max { $0.value < $1.value }.map { AINamedChange(name: $0.key, change: $0.value) }
        }
        return AIPortfolioSummary(
            count: h.count, dayChangePct: day, totalPLPct: pl,
            largest: AINamedChange(name: largest.ticker, change: 100 * w(largest)),
            largestDay: largest.dayChangePct,
            bestContributor: contrib(best) > 0 ? AINamedChange(name: best.ticker, change: contrib(best)) : nil,
            worstContributor: contrib(worst) < 0 ? AINamedChange(name: worst.ticker, change: contrib(worst)) : nil,
            topSector: top { $0.sector }, topCountry: top { $0.country })
    }
}

/// Все факты, которые разрешено показать модели или шаблону.
struct AIFacts: Codable, Hashable {
    enum Kind: String, Codable { case stock, market, portfolio }
    var kind: Kind
    var subject: String                       // тикер, "market" или "portfolio"
    var name: String = ""
    var changePct: Double?                    // изменение за день
    var benchmark: AINamedChange?             // индекс, к которому относится бумага
    var sector: AINamedChange?                // сектор бумаги
    var indices: [AINamedChange] = []         // для брифа рынка
    var gainers: [AINamedChange] = []
    var losers: [AINamedChange] = []
    var sectors: [AINamedChange] = []
    var portfolio: AIPortfolioSummary?
    var headlines: [AIHeadline] = []

    /// Достаточно ли данных, чтобы что-то сказать.
    var hasContent: Bool {
        switch kind {
        case .stock: return changePct != nil || !headlines.isEmpty
        case .market: return !indices.isEmpty || !gainers.isEmpty || !sectors.isEmpty || !headlines.isEmpty
        case .portfolio: return portfolio != nil
        }
    }
}

enum AISentiment: String, Codable { case up, down, mixed }
enum AIConfidence: String, Codable { case low, medium, high }

struct AIInsight: Codable, Hashable {
    var headline: String
    var reasons: [String]
    var sentiment: AISentiment
    var confidence: AIConfidence
    var sources: [AIHeadline]
    var usedModel: Bool
    var language: String
}
