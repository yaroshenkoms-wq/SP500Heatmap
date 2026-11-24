import Foundation
import SwiftUI

/// Загрузка фактов (сервер) и выбор «модель или шаблон». Результат кэшируется на день.
enum AIService {
    /// Модель, если она доступна и знает язык; иначе шаблон на языке интерфейса.
    static func insight(for facts: AIFacts, cacheKey: String, languageCode: String) async -> AIInsight {
        let modelOK = AIEngine.isUsable(languageCode: languageCode)
        if let cached = AICache.get(cacheKey), cached.usedModel || !modelOK { return cached }
        guard facts.hasContent else { return AITemplate.empty(languageCode) }
        var out: AIInsight?
        if modelOK, let generated = try? await AIEngine.generate(facts, languageCode: languageCode),
           !generated.headline.isEmpty {
            out = generated
            if out!.sources.isEmpty { out!.sources = Array(facts.headlines.prefix(3)) }
        }
        let result = out ?? AITemplate.make(facts, language: languageCode)
        AICache.set(result, for: cacheKey)
        return result
    }

    // MARK: Факты по бумаге

    static func stockFacts(ticker: String) async -> AIFacts {
        let net = NetworkService.shared
        let indexId = await MainActor.run { IndexStore.shared.apiIndexId }
        let indexName = await MainActor.run { IndexStore.shared.current.name }
        async let infoTask = try? net.fetchCompanyInfo(ticker: ticker)
        async let briefTask = fetchBrief()
        async let hierarchyTask = try? net.fetchMarketHierarchy(index: indexId)

        var facts = AIFacts(kind: .stock, subject: ticker)
        var change = await MainActor.run { PerformanceStore.shared.metrics[ticker]?.day1 }
        if change == nil, let perf = try? await net.fetchPerformance(index: indexId) { change = perf[ticker]?.day1 }
        facts.changePct = change
        if let info = await infoTask {
            facts.headlines = info.news.filter { URL(string: $0.url) != nil }.prefix(6)
                .map { AIHeadline(title: $0.title, publisher: $0.publisher, url: $0.url, ticker: ticker) }
        }
        let brief = await briefTask
        let selected = indexId ?? "sp500"
        if let b = brief?.indices.first(where: { $0.id == selected }) {
            facts.benchmark = AINamedChange(name: indexName, change: b.change1d)
        }
        if let sectors = await hierarchyTask,
           let sector = sectors.first(where: { $0.subsectors.contains { $0.companies.contains { $0.ticker == ticker } } }) {
            facts.name = sector.subsectors.flatMap(\.companies).first { $0.ticker == ticker }?.name ?? ""
            if let s = brief?.sectors.first(where: { $0.name == sector.name }) {
                facts.sector = AINamedChange(name: s.name, change: s.change)
            }
        }
        return facts
    }

    // MARK: Бриф рынка

    static func marketFacts() async -> AIFacts {
        var facts = AIFacts(kind: .market, subject: "market")
        guard let b = await fetchBrief() else { return facts }
        let names = await MainActor.run { Dictionary(uniqueKeysWithValues: IndexStore.shared.indices.map { ($0.id, $0.name) }) }
        facts.indices = b.indices.map { AINamedChange(name: names[$0.id] ?? $0.id, change: $0.change1d) }
        facts.gainers = b.topGainers
        facts.losers = b.topLosers
        facts.sectors = b.sectors
        facts.headlines = b.headlines
        return facts
    }

    // MARK: Портфолио

    static func portfolioFacts(_ holdings: [PortfolioInsightHolding]) async -> AIFacts {
        var facts = AIFacts(kind: .portfolio, subject: "portfolio")
        facts.portfolio = AIPortfolioSummary.make(holdings)
        // Заголовки — по трём самым крупным позициям, по два на каждую.
        let top = holdings.sorted { $0.weightPct > $1.weightPct }.prefix(3)
        var out: [AIHeadline] = []
        for h in top {
            if let info = try? await NetworkService.shared.fetchCompanyInfo(ticker: h.ticker) {
                out += info.news.filter { URL(string: $0.url) != nil }.prefix(2)
                    .map { AIHeadline(title: $0.title, publisher: $0.publisher, url: $0.url, ticker: h.ticker) }
            }
        }
        facts.headlines = out
        return facts
    }

    static func portfolioKey(_ holdings: [PortfolioInsightHolding]) -> String {
        let s = holdings.sorted { $0.ticker < $1.ticker }
            .map { "\($0.ticker):\(Int($0.weightPct.rounded()))" }.joined(separator: ",")
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }
        return String(h, radix: 16)
    }

    // MARK: /api/v1/brief

    struct Brief {
        struct Idx { let id: String; let change1d: Double }
        var indices: [Idx]
        var topGainers: [AINamedChange]
        var topLosers: [AINamedChange]
        var sectors: [AINamedChange]
        var headlines: [AIHeadline]
    }

    static func fetchBrief() async -> Brief? {
        guard let url = URL(string: "\(Config.baseURL)/api/v1/brief?date=today") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
        return parseBrief(data)
    }

    /// Терпимый разбор: элементы топов могут быть объектами {ticker,name,change} или строками.
    static func parseBrief(_ data: Data) -> Brief? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func num(_ d: [String: Any], _ keys: [String]) -> Double? {
            for k in keys { if let v = d[k] as? Double { return v }; if let v = d[k] as? Int { return Double(v) } }
            return nil
        }
        func named(_ any: Any?) -> [AINamedChange] {
            (any as? [Any] ?? []).compactMap { el in
                guard let d = el as? [String: Any],
                      let name = (d["ticker"] ?? d["symbol"] ?? d["name"]) as? String,
                      let c = num(d, ["change", "change1d", "changePct", "changePercent"]) else { return nil }
                return AINamedChange(name: name, change: c)
            }
        }
        let indices: [Brief.Idx] = (root["indices"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? String, let c = num($0, ["change1d", "change"]) else { return nil }
            return Brief.Idx(id: id, change1d: c)
        }
        let headlines: [AIHeadline] = (root["headlines"] as? [[String: Any]] ?? []).compactMap {
            guard let t = $0["title"] as? String else { return nil }
            return AIHeadline(title: t, publisher: $0["publisher"] as? String, url: $0["url"] as? String, ticker: $0["ticker"] as? String)
        }
        return Brief(indices: indices, topGainers: named(root["topGainers"]), topLosers: named(root["topLosers"]),
                     sectors: named(root["sectors"]), headlines: headlines)
    }
}
