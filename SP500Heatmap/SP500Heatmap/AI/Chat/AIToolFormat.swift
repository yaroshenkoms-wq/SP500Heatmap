import Foundation

// Тексты, которые инструменты чата отдают модели (и шаблонные ответы без модели).
// Всё — чистые функции без сети и интерфейса: числа в формате с точкой, даты yyyy-MM-dd, по-английски.
// Язык ответа модели задаётся инструкцией; цифры и даты она берёт отсюда без пересчёта.

struct AIQuoteFacts: Equatable {
    var ticker: String
    var name: String?
    var currency: String?
    var last: Double?
    var lastDate: String?
    var live = false
    var change1d: Double?
    var change1M: Double?
    var changeYTD: Double?
    var high52w: Double?
    var low52w: Double?
    var pe: Double?
    var divYield: Double?     // в процентах

    /// Из ряда закрытий (по возрастанию дат), данных /company и живой цены (если есть).
    static func make(ticker: String, name: String?, history: [DailyClose], info: CompanyInfo?,
                     live: (price: Double, changePercent: Double)?) -> AIQuoteFacts {
        var q = AIQuoteFacts(ticker: ticker, name: name)
        let h = history.sorted { $0.date < $1.date }
        q.currency = info?.currency
        q.high52w = info?.high52w; q.low52w = info?.low52w; q.pe = info?.pe; q.divYield = info?.divYield
        if let l = h.last {
            q.last = l.close; q.lastDate = l.date
            if h.count >= 2, h[h.count - 2].close > 0 { q.change1d = (l.close / h[h.count - 2].close - 1) * 100 }
            if let day = AIToolFormat.day(l.date) {
                let monthAgo = AIToolFormat.string(day.addingTimeInterval(-30 * 86400))
                if let base = h.last(where: { $0.date <= monthAgo }), base.close > 0 { q.change1M = (l.close / base.close - 1) * 100 }
                let year = l.date.prefix(4)
                if let base = h.last(where: { $0.date < "\(year)-01-01" }), base.close > 0 { q.changeYTD = (l.close / base.close - 1) * 100 }
            }
        }
        if let live, live.price > 0 {
            q.last = live.price; q.live = true
            q.change1d = live.changePercent
            q.lastDate = AIToolFormat.string(Date())
        }
        return q
    }
}

enum AIToolFormat {
    private static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    static func day(_ s: String) -> Date? { utc.date(from: s) }
    static func string(_ d: Date) -> String { utc.string(from: d) }

    // MARK: числа

    static func pct(_ v: Double?, digits: Int = 2) -> String {
        guard let v, v.isFinite else { return "n/a" }
        return String(format: "%+.\(digits)f%%", v)
    }

    static func plainPct(_ v: Double?, digits: Int = 1) -> String {
        guard let v, v.isFinite else { return "n/a" }
        return String(format: "%.\(digits)f%%", v)
    }

    static func num(_ v: Double?, digits: Int = 2) -> String {
        guard let v, v.isFinite else { return "n/a" }
        return String(format: "%.\(digits)f", v)
    }

    /// 1.2T, 340.50B, 12.30M; меньшие числа — как есть.
    static func big(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "n/a" }
        let a = abs(v)
        if a >= 1e12 { return String(format: "%.2fT", v / 1e12) }
        if a >= 1e9 { return String(format: "%.2fB", v / 1e9) }
        if a >= 1e6 { return String(format: "%.2fM", v / 1e6) }
        return String(format: "%.0f", v)
    }

    static func money(_ v: Double?, _ currency: String?) -> String {
        guard let v, v.isFinite else { return "n/a" }
        let s = abs(v) >= 100_000 ? String(format: "%.0f", v) : String(format: "%.2f", v)
        return currency.map { "\(s) \($0)" } ?? s
    }

    // MARK: бумага

    static func quote(_ q: AIQuoteFacts) -> String {
        guard let last = q.last else { return "No price data available for \(q.ticker)." }
        var head = q.ticker
        if let n = q.name, !n.isEmpty { head += " (\(n))" }
        var s = "\(head): last \(money(last, q.currency))"
        if let d = q.lastDate { s += q.live ? " (live price, \(d))" : " (close of \(d))" }
        s += "."
        var moves: [String] = []
        if let c = q.change1d { moves.append("today \(pct(c))") }
        if let c = q.change1M { moves.append("1 month \(pct(c))") }
        if let c = q.changeYTD { moves.append("year to date \(pct(c))") }
        if !moves.isEmpty { s += " Change: " + moves.joined(separator: ", ") + "." }
        if let lo = q.low52w, let hi = q.high52w { s += " 52-week range \(num(lo))–\(num(hi))." }
        if let pe = q.pe { s += " P/E \(num(pe, digits: 1))." }
        if let y = q.divYield, y > 0 { s += " Dividend yield \(plainPct(y, digits: 2))." }
        return s
    }

    // MARK: индексы

    static func indexLine(_ i: WorldIndex) -> String {
        var parts: [String] = []
        for (label, key) in [("1d", "1d"), ("7d", "7d"), ("30d", "30d"), ("1y", "1y")] {
            if let c = i.change(for: key) { parts.append("\(label) \(pct(c))") }
        }
        let tail = parts.isEmpty ? "no change data" : parts.joined(separator: ", ")
        return "\(i.name) (id \(i.id)\(i.country.map { ", \($0)" } ?? "")): \(tail)"
    }

    private static let allWords: Set<String> = ["", "all", "world", "global", "market", "markets", "indices", "indexes", "main"]

    static func matchIndexes(_ all: [WorldIndex], query: String) -> [WorldIndex] {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if allWords.contains(q) { return Array(all.sorted { ($0.capUSD ?? 0) > ($1.capUSD ?? 0) }.prefix(10)) }
        let squash = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let sq = squash(q)
        let exact = all.filter { $0.id.lowercased() == q || squash($0.name) == sq || squash($0.id) == sq }
        if !exact.isEmpty { return exact }
        return Array(all.filter { squash($0.name).contains(sq) || squash($0.id).contains(sq) }.prefix(5))
    }

    static func indexes(_ overview: WorldOverview, query: String) -> String {
        let all = overview.regions.flatMap(\.indices)
        let hit = matchIndexes(all, query: query)
        guard !hit.isEmpty else {
            let ids = all.prefix(30).map(\.id).joined(separator: ", ")
            return "No index matches \"\(query)\". Available index ids: \(ids)."
        }
        let asOf = overview.asOf.map { " as of \($0) (closing prices)" } ?? ""
        return "Index changes\(asOf):\n" + hit.map(indexLine).joined(separator: "\n")
    }

    // MARK: отчётность

    static func financials(_ f: Financials, ticker: String) -> String {
        guard !f.isEmpty else { return "No financial statements available for \(ticker)." }
        var lines: [String] = []
        let cur = f.currency
        func period(_ p: FinancialPeriod, label: String) -> String {
            var parts = ["revenue \(big(p.revenue))", "net income \(big(p.netIncome))"]
            if let e = p.eps { parts.append("EPS \(num(e))") }
            if let c = p.freeCashFlow { parts.append("free cash flow \(big(c))") }
            if let r = p.revenue, r > 0 {
                if let g = p.grossProfit { parts.append("gross margin \(plainPct(g / r * 100))") }
                if let o = p.operatingIncome { parts.append("operating margin \(plainPct(o / r * 100))") }
                if let n = p.netIncome { parts.append("net margin \(plainPct(n / r * 100))") }
            }
            if let d = p.totalDebt { parts.append("total debt \(big(d))") }
            if let c = p.cash { parts.append("cash \(big(c))") }
            return "\(label) \(p.period): " + parts.joined(separator: ", ") + "."
        }
        lines.append("Financials of \(ticker)\(cur.map { " (\($0))" } ?? ""):")
        if let last = f.annual.last {
            lines.append(period(last, label: "Fiscal year"))
            if f.annual.count >= 2 {
                let prev = f.annual[f.annual.count - 2]
                lines.append(period(prev, label: "Previous fiscal year"))
                if let a = last.revenue, let b = prev.revenue, b > 0 { lines.append("Revenue growth year over year \(pct((a / b - 1) * 100, digits: 1)).") }
            }
        }
        if let q = f.quarterly.last { lines.append(period(q, label: "Latest quarter")) }
        if let r = f.ratios {
            var parts: [String] = []
            if let v = r.roe { parts.append("ROE \(plainPct(v))") }
            if let v = r.roa { parts.append("ROA \(plainPct(v))") }
            if let v = r.debtToEquity { parts.append("debt/equity \(num(v))") }
            if let v = r.currentRatio { parts.append("current ratio \(num(v))") }
            if let v = r.evToEbitda { parts.append("EV/EBITDA \(num(v, digits: 1))") }
            if let v = r.peg { parts.append("PEG \(num(v))") }
            if let v = r.priceToFcf { parts.append("P/FCF \(num(v, digits: 1))") }
            if !parts.isEmpty { lines.append("Ratios: " + parts.joined(separator: ", ") + ".") }
        }
        if let a = f.analysts, a.recommendation != nil || a.targetMean != nil {
            var s = "Analysts:"
            if let r = a.recommendation { s += " consensus \(r)" }
            if let n = a.count { s += " (\(n) analysts)" }
            if let t = a.targetMean { s += ", mean target price \(num(t))" }
            if let hi = a.targetHigh, let lo = a.targetLow { s += " (range \(num(lo))–\(num(hi)))" }
            lines.append(s + ".")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: новости

    static func news(_ items: [NewsArticle], title: String, limit: Int = 8) -> String {
        guard !items.isEmpty else { return "No recent headlines found for \(title)." }
        var lines = ["Latest headlines for \(title):"]
        for (i, a) in items.prefix(limit).enumerated() {
            var meta: [String] = []
            if let p = a.publisher, !p.isEmpty { meta.append(p) }
            if let d = a.date { meta.append(string(d)) }
            if !a.tickers.isEmpty { meta.append(a.tickers.prefix(3).joined(separator: ",")) }
            lines.append("\(i + 1). \(a.title)" + (meta.isEmpty ? "" : " (" + meta.joined(separator: ", ") + ")"))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: скринер

    static let screenerPresets = ScreenerFilters.presets

    /// Приводит слова модели к одному из готовых наборов скринера.
    static func normalizePreset(_ raw: String) -> String {
        let q = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if screenerPresets.contains(q) { return q }
        if q.contains("div") || q.contains("yield") { return "dividend" }
        if q.contains("gain") || q.contains("winner") || q.contains("rise") { return "gainers" }
        if q.contains("los") || q.contains("fall") || q.contains("drop") { return "losers" }
        if q.contains("active") || q.contains("volume") { return "active" }
        if q.contains("value") || q.contains("cheap") || q.contains("pe") { return "value" }
        if q.contains("high") { return "highs52" }
        if q.contains("low") { return "lows52" }
        return "gainers"
    }

    static func screener(_ rows: [ScreenerRow], total: Int, preset: String, indexId: String, limit: Int = 8) -> String {
        guard !rows.isEmpty else { return "The screener found no stocks for preset \(preset) in \(indexId)." }
        var lines = ["Screener preset \(preset) in \(indexId): \(total) matches, top \(min(limit, rows.count)) shown:"]
        for (i, r) in rows.prefix(limit).enumerated() {
            var parts: [String] = []
            if let s = r.sector { parts.append(s) }
            if let c = r.change { parts.append("today \(pct(c))") }
            if let d = r.divYield { parts.append("dividend yield \(plainPct(d, digits: 2))") }
            if let p = r.pe { parts.append("P/E \(num(p, digits: 1))") }
            if let c = r.capUSD { parts.append("market cap \(big(c)) USD") }
            if let p = r.pos52w { parts.append("52-week position \(plainPct(p * 100, digits: 0))") }
            lines.append("\(i + 1). \(r.ticker)\(r.name.map { " — \($0)" } ?? ""): " + parts.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: личный портфель

    static func portfolio(name: String, base: String, result: PfResult) -> String {
        let s = result.summary
        guard !result.holdings.isEmpty else { return "The portfolio \"\(name)\" has no open positions." }
        var lines = ["Portfolio \"\(name)\" (base currency \(base), daily closes, may be delayed):"]
        lines.append("Value \(money(s.value, base)), invested cost of open positions \(money(s.cost, base)), unrealized result \(money(s.unrealized, base)) (\(pct(s.unrealizedPct, digits: 1))).")
        lines.append("Today \(pct(s.todayPct)) (\(money(s.todayChange, base))). Realized result \(money(s.realized, base)), dividends received \(money(s.dividends, base)).")
        lines.append("Total result including realized and dividends: \(money(s.totalPL, base)) (\(pct(s.totalPLPct, digits: 1)) of all purchases).")
        let top = result.holdings.prefix(6).map { h in
            "\(h.ticker) \(plainPct(h.weight)) of value, today \(pct(h.todayPct)), since purchase \(pct(h.unrealizedPct, digits: 1))"
        }
        lines.append("Positions (\(result.holdings.count)); largest: " + top.joined(separator: "; ") + ".")
        let withDay = result.holdings.filter { $0.todayChange != nil }
        if let best = withDay.max(by: { ($0.todayChange ?? 0) < ($1.todayChange ?? 0) }), (best.todayChange ?? 0) > 0 {
            lines.append("Helped most today: \(best.ticker) (\(money(best.todayChange, base))).")
        }
        if let worst = withDay.min(by: { ($0.todayChange ?? 0) < ($1.todayChange ?? 0) }), (worst.todayChange ?? 0) < 0 {
            lines.append("Hurt most today: \(worst.ticker) (\(money(worst.todayChange, base))).")
        }
        if s.missingPrices > 0 { lines.append("Prices are missing for \(s.missingPrices) position(s).") }
        return lines.joined(separator: "\n")
    }

    // MARK: модельный портфель

    static func modelPortfolio(key: String, name: String, risk: String, weights: [String: Double],
                               period: String, metrics m: PortfolioMetrics, currency: String) -> String {
        let w = weights.filter { $0.value > 0 }.sorted { $0.value > $1.value }
            .map { "\($0.key) \(plainPct($0.value * 100, digits: 0))" }.joined(separator: ", ")
        var s = "Model portfolio \(name) (key \(key), risk \(risk)). Weights: \(w)."
        s += " Backtest \(m.from) to \(m.to) (\(period), \(currency), monthly returns, yearly rebalancing, no fees):"
        s += " annualized return \(plainPct(m.cagr * 100)), total return \(pct(m.totalReturn * 100, digits: 1)),"
        s += " maximum drawdown \(plainPct(m.maxDrawdown * 100)) (peak \(m.ddPeak), trough \(m.ddTrough)),"
        s += " volatility \(plainPct(m.volatility * 100))."
        if let b = m.bestYear, let l = m.bestYearLabel { s += " Best year \(l) \(pct(b * 100, digits: 1))." }
        if let b = m.worstYear, let l = m.worstYearLabel { s += " Worst year \(l) \(pct(b * 100, digits: 1))." }
        return s
    }
}
