import SwiftUI

/// Компания для поиска при добавлении сделки.
struct PfCatalogEntry: Codable, Identifiable, Hashable {
    var t: String      // тикер
    var n: String      // название
    var i: String      // id индекса
    var s: String      // сектор (англ.)
    var id: String { t }
}

/// Данные рынка для личного портфеля: каталог бумаг всех индексов, котировки, курсы валют, дивиденды.
/// Всё кэшируется на диске (Caches), чтобы экран открывался без сети.
@MainActor
final class PfMarketData: ObservableObject {
    static let shared = PfMarketData()

    @Published private(set) var catalog: [PfCatalogEntry] = []
    @Published private(set) var catalogLoading = false
    @Published private(set) var quotes: [String: PfQuote] = [:]
    @Published private(set) var fx = PfFX()
    @Published private(set) var meta: [String: PfMeta] = [:]
    @Published private(set) var isLoading = false

    private struct InfoCache: Codable { var y: Double?; var c: String?; var day: String }
    private var info: [String: InfoCache] = [:]
    private var histories: [String: [DailyClose]] = [:]
    private let dir: URL

    private init() {
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("portfolio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        catalog = read([PfCatalogEntry].self, "catalog.json") ?? []
        quotes = read([String: PfQuote].self, "quotes.json") ?? [:]
        fx = PfFX(series: read([String: [PfFX.Point]].self, "fx.json") ?? [:])
        info = read([String: InfoCache].self, "info.json") ?? [:]
    }

    private func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, _ name: String) {
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: dir.appendingPathComponent(name), options: .atomic) }
    }

    private static func apiIndex(_ id: String) -> String? { id == "sp500" || id.isEmpty ? nil : id }

    // MARK: каталог (поиск тикеров)

    /// Каталог собирается из иерархий всех индексов и обновляется раз в неделю.
    func loadCatalog(indices: [IndexInfo]) async {
        let stamp = dir.appendingPathComponent("catalog.json")
        let age = (try? stamp.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { Date().timeIntervalSince($0) } ?? .infinity
        guard !catalogLoading, catalog.isEmpty || age > 7 * 86400 else { return }
        catalogLoading = true
        defer { catalogLoading = false }
        var parts: [(Int, [PfCatalogEntry])] = []
        await withTaskGroup(of: (Int, [PfCatalogEntry]).self) { group in
            var running = 0
            for (pos, index) in indices.enumerated() {
                if running >= 4, let done = await group.next() { parts.append(done); running -= 1 }
                running += 1
                group.addTask {
                    guard let sectors = try? await NetworkService.shared.fetchMarketHierarchy(index: Self.apiIndex(index.id)) else { return (pos, []) }
                    var rows: [PfCatalogEntry] = []
                    for s in sectors { for sub in s.subsectors { for c in sub.companies {
                        rows.append(PfCatalogEntry(t: c.ticker, n: c.name, i: index.id, s: s.name))
                    } } }
                    return (pos, rows)
                }
            }
            for await done in group { parts.append(done) }
        }
        var seen = Set<String>()
        var merged: [PfCatalogEntry] = []
        for (_, rows) in parts.sorted(by: { $0.0 < $1.0 }) {
            for r in rows where seen.insert(r.t).inserted { merged.append(r) }
        }
        guard !merged.isEmpty else { return }
        catalog = merged
        write(merged, "catalog.json")
    }

    func entry(_ ticker: String) -> PfCatalogEntry? { catalog.first { $0.t == ticker } }

    func search(_ query: String, limit: Int = 40) -> [PfCatalogEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let exact = catalog.filter { $0.t.lowercased() == q }
        let prefix = catalog.filter { $0.t.lowercased().hasPrefix(q) && $0.t.lowercased() != q }
        let name = catalog.filter { !$0.t.lowercased().hasPrefix(q) && $0.n.lowercased().contains(q) }
        return Array((exact + prefix + name).prefix(limit))
    }

    // MARK: история

    func history(_ ticker: String, range: String? = nil) async -> [DailyClose] {
        let key = ticker + "|" + (range ?? "")
        if let h = histories[key] { return h }
        var result: [DailyClose]?
        if let range { result = try? await NetworkService.shared.fetchHistory(ticker: ticker, range: range) }
        if result?.isEmpty ?? true { result = try? await NetworkService.shared.fetchHistory(ticker: ticker) }
        let h = result ?? []
        if !h.isEmpty { histories[key] = h }
        return h
    }

    /// Цена закрытия на день или ближайшая до него; nil — нет истории.
    func close(_ ticker: String, on day: String, range: String? = nil) async -> Double? {
        let h = await history(ticker, range: range)
        return h.last(where: { $0.date <= day })?.close ?? h.first?.close
    }

    static func range(forOldest day: String?) -> String? {
        guard let day, let d = PfDay.date(day) else { return nil }
        let years = Date().timeIntervalSince(d) / (365.25 * 86400)
        if years <= 0.95 { return nil }
        return years <= 2.9 ? "3y" : (years <= 4.9 ? "5y" : "10y")
    }

    // MARK: обновление для портфеля

    func refresh(_ portfolio: MyPortfolio, indices: [IndexInfo]) async {
        let tickers = portfolio.tickers
        guard !tickers.isEmpty else { meta = [:]; return }
        isLoading = true
        defer { isLoading = false }
        let today = PfDay.today

        // 1. Котировки и дивиденды параллельно.
        let indexById = Dictionary(uniqueKeysWithValues: indices.map { ($0.id, $0) })
        var indexOf: [String: String] = [:]
        for t in portfolio.transactions where !t.indexId.isEmpty { indexOf[t.ticker] = t.indexId }
        var txCurrency: [String: String] = [:]
        for t in portfolio.transactions { txCurrency[t.ticker] = t.currency }

        await withTaskGroup(of: (String, [DailyClose], CompanyInfo?).self) { group in
            for ticker in tickers {
                let cached = info[ticker]
                let needInfo = cached == nil || cached?.day != today
                group.addTask {
                    let h = (try? await NetworkService.shared.fetchHistory(ticker: ticker)) ?? []
                    let i = needInfo ? try? await NetworkService.shared.fetchCompanyInfo(ticker: ticker) : nil
                    return (ticker, h, i)
                }
            }
            for await (ticker, h, i) in group {
                if let last = h.last {
                    let cur = info[ticker]?.c ?? indexById[indexOf[ticker] ?? ""]?.currency ?? txCurrency[ticker] ?? "USD"
                    quotes[ticker] = PfQuote(last: last.close, prev: h.count > 1 ? h[h.count - 2].close : nil,
                                             currency: cur, day: last.date)
                    histories[ticker + "|"] = h
                }
                if let i { info[ticker] = InfoCache(y: i.divYield, c: i.currency, day: today) }
            }
        }
        // Валюта котировки могла уточниться после загрузки информации о компании.
        for ticker in tickers {
            if var q = quotes[ticker], let c = info[ticker]?.c, !c.isEmpty { q.currency = c; quotes[ticker] = q }
        }

        // 2. Мета: название, сектор, страна, валюта, дивидендная доходность.
        var newMeta: [String: PfMeta] = [:]
        for ticker in tickers {
            let e = entry(ticker)
            let idx = indexById[indexOf[ticker] ?? e?.i ?? ""]
            newMeta[ticker] = PfMeta(name: e?.n ?? "", sector: e?.s, country: idx?.country,
                                     quoteCurrency: info[ticker]?.c ?? quotes[ticker]?.currency ?? idx?.currency ?? txCurrency[ticker],
                                     divYield: info[ticker]?.y)
        }
        meta = newMeta

        // 3. Курсы валют.
        var currencies: Set<String> = [portfolio.baseCurrency.rawValue]
        for t in portfolio.transactions { currencies.insert(t.currency) }
        newMeta.values.compactMap(\.quoteCurrency).forEach { currencies.insert($0) }
        currencies.remove("USD")
        let range = Self.range(forOldest: portfolio.firstDay)
        var newFX = fx
        await withTaskGroup(of: (String, [PfFX.Point]).self) { group in
            for cur in currencies {
                group.addTask {
                    var h: [DailyClose] = []
                    if let range { h = (try? await NetworkService.shared.fetchHistory(ticker: PfFX.symbol(cur), range: range)) ?? [] }
                    if h.isEmpty { h = (try? await NetworkService.shared.fetchHistory(ticker: PfFX.symbol(cur))) ?? [] }
                    return (cur, h.map { PfFX.Point(d: $0.date, r: $0.close) })
                }
            }
            for await (cur, points) in group where !points.isEmpty {
                // Новый ряд дополняет старый кэш (старые даты не теряем).
                let old = newFX.series[cur] ?? []
                let firstNew = points.first?.d ?? ""
                newFX.series[cur] = (old.filter { $0.d < firstNew } + points)
            }
        }
        fx = newFX
        write(quotes, "quotes.json")
        write(fx.series, "fx.json")
        write(info, "info.json")
    }

    /// Символы индексов для графика сравнения; пробуем по очереди. Если сервер не отдаёт ни одного — графика индекса не будет.
    static func benchmarkSymbols(_ indexId: String) -> [String] {
        let known: [String: [String]] = [
            "sp500": ["^GSPC", "SPY"], "nasdaq100": ["^NDX", "QQQ"], "dow30": ["^DJI", "DIA"],
            "dax40": ["^GDAXI"], "cac40": ["^FCHI"], "ibex35": ["^IBEX"], "ftse100": ["^FTSE"],
            "nikkei225": ["^N225"], "csi300": ["000300.SS"], "asx50": ["^AXJO"]
        ]
        return known[indexId] ?? ["^GSPC", "SPY"]
    }

    func benchmarkHistory(_ indexId: String, range: String?) async -> [DailyClose]? {
        for sym in Self.benchmarkSymbols(indexId) {
            let h = await history(sym, range: range)
            if h.count > 5 { return h }
        }
        return nil
    }
}
