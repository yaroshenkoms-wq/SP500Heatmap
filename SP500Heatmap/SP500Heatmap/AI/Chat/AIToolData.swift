import Foundation

/// Загрузка данных для инструментов чата. Каждая функция возвращает готовый текст
/// (ошибки — тоже текстом, чтобы модель могла сказать «данных нет», а не падала сессия).
@MainActor
enum AIToolData {
    // MARK: тикер по названию

    static func resolve(_ raw: String) async -> (ticker: String, name: String?) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = q.uppercased()
        let market = PfMarketData.shared
        if await MainActor.run(body: { market.catalog.isEmpty }) {
            let indices = await MainActor.run { IndexStore.shared.indices }
            await market.loadCatalog(indices: indices)
        }
        return await MainActor.run {
            if let e = market.entry(upper) { return (e.t, e.n) }
            if let e = market.search(q, limit: 1).first { return (e.t, e.n) }
            return (upper, nil)
        }
    }

    // MARK: бумага

    static func quote(_ query: String) async -> String {
        let (ticker, name) = await resolve(query)
        async let hist = try? await NetworkService.shared.fetchHistory(ticker: ticker)
        async let info = try? await NetworkService.shared.fetchCompanyInfo(ticker: ticker)
        let live = await MainActor.run { WebSocketManager.shared.priceUpdates[ticker] }
        let q = AIQuoteFacts.make(ticker: ticker, name: name, history: await hist ?? [], info: await info,
                                  live: live.map { (price: $0.price, changePercent: $0.changePercent) })
        return AIToolFormat.quote(q)
    }

    static func quoteFacts(_ ticker: String) async -> AIQuoteFacts {
        let (t, name) = await resolve(ticker)
        async let hist = try? await NetworkService.shared.fetchHistory(ticker: t)
        async let info = try? await NetworkService.shared.fetchCompanyInfo(ticker: t)
        let live = await MainActor.run { WebSocketManager.shared.priceUpdates[t] }
        return AIQuoteFacts.make(ticker: t, name: name, history: await hist ?? [], info: await info,
                                 live: live.map { (price: $0.price, changePercent: $0.changePercent) })
    }

    // MARK: индексы

    static func overview() async -> WorldOverview? {
        if let o = await MainActor.run(body: { WorldStore.shared.overview }) { return o }
        return try? await NetworkService.shared.fetchWorldOverview()
    }

    static func index(_ query: String) async -> String {
        guard let o = await overview() else { return "Index data is not available right now." }
        return AIToolFormat.indexes(o, query: query)
    }

    // MARK: отчётность

    static func financials(_ query: String) async -> String {
        let (ticker, _) = await resolve(query)
        guard let f = try? await NetworkService.shared.fetchFinancials(ticker: ticker) else {
            return "Financial statements are not available for \(ticker) right now."
        }
        return AIToolFormat.financials(f, ticker: ticker)
    }

    // MARK: новости

    static func news(_ query: String) async -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = await MainActor.run { AppLanguage.effectiveCode }
        if q.isEmpty || ["market", "markets", "all", "general", "world"].contains(q.lowercased()) {
            let items = await NewsService.fetch(scope: .market, lang: code) ?? []
            return AIToolFormat.news(items, title: "the market")
        }
        let (ticker, _) = await resolve(q)
        let items = await NewsService.fetch(scope: .tickers([ticker]), lang: code) ?? []
        return AIToolFormat.news(items, title: ticker)
    }

    // MARK: скринер

    static func screen(preset: String, indexId: String) async -> String {
        let p = AIToolFormat.normalizePreset(preset)
        let idx = await resolveIndexId(indexId)
        var f = ScreenerFilters()
        f.preset = p
        f.index = idx
        (f.sort, f.ascending) = ScreenerFilters.defaultSort(for: p)
        guard let r = try? await NetworkService.shared.fetchScreener(f.query()) else {
            return "The screener is not available right now."
        }
        return AIToolFormat.screener(r.rows, total: r.total, preset: p, indexId: idx)
    }

    /// «IBEX 35», «ibex35», «Spain» → id индекса из списка; не нашли — "all".
    static func resolveIndexId(_ raw: String) async -> String {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty || q.lowercased() == "all" { return "all" }
        guard let o = await overview() else { return q.lowercased() }
        let all = o.regions.flatMap(\.indices)
        return AIToolFormat.matchIndexes(all, query: q).first?.id ?? "all"
    }

    // MARK: личный портфель

    static func portfolio() async -> String {
        guard let r = await portfolioResult() else { return "The user has no personal portfolio data in the app yet." }
        return AIToolFormat.portfolio(name: r.name, base: r.base, result: r.result)
    }

    /// Итог личного портфеля для шаблонного ответа (нужны и сами позиции).
    static func portfolioResult() async -> (name: String, base: String, result: PfResult)? {
        let (p, indices): (MyPortfolio?, [IndexInfo]) = await MainActor.run { (MyPortfolioStore.shared.selected, IndexStore.shared.indices) }
        guard let p, !p.transactions.isEmpty else { return nil }
        let market = PfMarketData.shared
        let missing = await MainActor.run { p.tickers.contains { market.quotes[$0] == nil } }
        if missing { await market.refresh(p, indices: indices) }
        let r: PfResult = await MainActor.run {
            PfCalc.compute(transactions: p.transactions, base: p.baseCurrency, fx: market.fx, quotes: market.quotes, meta: market.meta)
        }
        return (p.name, p.baseCurrency.rawValue, r)
    }

    // MARK: модельные портфели Udak

    static func modelKeys() -> [String] { PortfolioStore.shared.models.map(\.key) }

    static func englishName(_ key: String) -> String {
        PortfolioStore.shared.text?.models[key]?.name["en"] ?? key
    }

    static func findModel(_ query: String) -> PortfolioInfo? {
        let store = PortfolioStore.shared
        let squash = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let q = squash(query)
        guard !q.isEmpty else { return nil }
        if let m = store.models.first(where: { squash($0.key) == q || squash(englishName($0.key)) == q }) { return m }
        if let m = store.models.first(where: { squash(englishName($0.key)).contains(q) || squash($0.key).contains(q) }) { return m }
        return squash(store.reference.map { englishName($0.key) } ?? "") == q ? store.reference : nil
    }

    static func modelPortfolio(_ query: String) async -> String {
        let store = PortfolioStore.shared
        guard store.isAvailable else { return "Model portfolio data is not available." }
        guard let info = findModel(query) else {
            let names = store.models.prefix(40).map { "\(englishName($0.key)) [\($0.key)]" }.joined(separator: ", ")
            return "No model portfolio matches \"\(query)\". Available: \(names)."
        }
        guard let run = store.run(info, period: .y10, currency: .usd, real: false) ?? store.run(info, period: .all, currency: .usd, real: false) else {
            return "No backtest is available for \(englishName(info.key))."
        }
        return AIToolFormat.modelPortfolio(key: info.key, name: englishName(info.key), risk: info.risk, weights: info.weights,
                                           period: "last 10 years or the full history if shorter", metrics: run.metrics, currency: "USD")
    }
}
