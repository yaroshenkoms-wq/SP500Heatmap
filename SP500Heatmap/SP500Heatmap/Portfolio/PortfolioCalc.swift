import Foundation

// Чистые расчёты личного портфеля (без сети и интерфейса — всё покрыто тестами).

// MARK: Курсы валют

/// Курсы «долларов за 1 единицу валюты» по дням (Yahoo EURUSD=X и т. п.). USD всегда 1.
struct PfFX: Equatable {
    struct Point: Codable, Equatable {
        var d: String
        var r: Double
    }
    var series: [String: [Point]] = [:]

    static func symbol(_ currency: String) -> String { "\(currency)USD=X" }

    /// Курс на день `day`: последняя точка не позже этого дня; до начала ряда — первая точка; нет ряда — nil.
    func usdPerUnit(_ currency: String, on day: String) -> Double? {
        if currency == "USD" { return 1 }
        guard let points = series[currency], !points.isEmpty else { return nil }
        var lo = 0, hi = points.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if points[mid].d <= day { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return points[max(found, 0)].r
    }

    func convert(_ amount: Double, from: String, to: String, on day: String) -> Double? {
        if from == to { return amount }
        guard let a = usdPerUnit(from, on: day), let b = usdPerUnit(to, on: day), b > 0 else { return nil }
        return amount * a / b
    }

    static let latestDay = "9999-12-31"
}

// MARK: Результаты

struct PfQuote: Codable, Equatable {
    var last: Double
    var prev: Double?
    var currency: String
    var day: String?
}

struct PfMeta: Equatable {
    var name: String = ""
    var sector: String?
    var country: String?
    var quoteCurrency: String?
    var divYield: Double?      // в процентах (1.5 = 1,5 %)
}

struct PfHolding: Identifiable, Equatable {
    var ticker: String
    var indexId: String
    var name: String
    var quantity: Double
    var quoteCurrency: String
    /// Средняя цена покупки (FIFO, с комиссией) в валюте котировки.
    var avgCost: Double
    var costBase: Double
    var last: Double?
    var value: Double?          // в базовой валюте
    var unrealized: Double?
    var unrealizedPct: Double?
    var todayChange: Double?
    var todayPct: Double?
    var weight: Double = 0      // доля в стоимости, %
    var realized: Double
    var dividends: Double
    var sector: String?
    var country: String?
    var id: String { ticker }
}

struct PfSummary: Equatable {
    var value = 0.0
    var cost = 0.0
    var invested = 0.0          // сумма всех покупок в базовой валюте
    var todayChange = 0.0
    var todayPct = 0.0
    var unrealized = 0.0
    var realized = 0.0
    var dividends = 0.0
    var expectedAnnualDividends = 0.0
    var missingPrices = 0
    var missingFX = false
    var totalPL: Double { unrealized + realized + dividends }
    /// Общий результат к сумме всех покупок.
    var totalPLPct: Double { invested > 0 ? totalPL / invested * 100 : 0 }
    var unrealizedPct: Double { cost > 0 ? unrealized / cost * 100 : 0 }
}

struct PfResult: Equatable {
    var holdings: [PfHolding] = []
    var summary = PfSummary()
}

struct PfSlice: Identifiable, Equatable {
    var label: String
    var value: Double
    var id: String { label }
}

// MARK: Расчёт

enum PfCalc {
    private struct Lot {
        var qty: Double
        var costBase: Double
        var costLocal: Double
    }

    /// Сделки по дням; в один день покупки раньше продаж.
    static func ordered(_ txns: [MyPortfolio.Transaction]) -> [MyPortfolio.Transaction] {
        func rank(_ t: PfTxType) -> Int { t == .buy ? 0 : (t == .dividend ? 1 : 2) }
        return txns.enumerated().sorted { a, b in
            if a.element.day != b.element.day { return a.element.day < b.element.day }
            if rank(a.element.type) != rank(b.element.type) { return rank(a.element.type) < rank(b.element.type) }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Сколько штук бумаги было на руках после всех сделок до конца дня `day`.
    static func quantity(of ticker: String, in txns: [MyPortfolio.Transaction], upTo day: String = PfPortfolioDay.max) -> Double {
        var q = 0.0
        for t in ordered(txns) where t.ticker == ticker && t.day <= day {
            if t.type == .buy { q += t.quantity } else if t.type == .sell { q = max(0, q - t.quantity) }
        }
        return q
    }

    static func compute(transactions: [MyPortfolio.Transaction], base: PfBase, fx: PfFX,
                        quotes: [String: PfQuote], meta: [String: PfMeta]) -> PfResult {
        let baseCode = base.rawValue
        var lots: [String: [Lot]] = [:]
        var realized: [String: Double] = [:]
        var dividends: [String: Double] = [:]
        var indexOf: [String: String] = [:]
        var txnCurrency: [String: String] = [:]
        var summary = PfSummary()

        func toBase(_ amount: Double, _ cur: String, _ day: String) -> Double {
            if let v = fx.convert(amount, from: cur, to: baseCode, on: day) { return v }
            summary.missingFX = true
            return amount
        }

        for t in ordered(transactions) {
            if !t.indexId.isEmpty { indexOf[t.ticker] = t.indexId }
            txnCurrency[t.ticker] = t.currency
            let quoteCur = meta[t.ticker]?.quoteCurrency ?? quotes[t.ticker]?.currency ?? t.currency
            switch t.type {
            case .buy:
                let cost = t.gross + t.fee
                let costBase = toBase(cost, t.currency, t.day)
                let local = fx.convert(cost, from: t.currency, to: quoteCur, on: t.day) ?? cost
                lots[t.ticker, default: []].append(Lot(qty: t.quantity, costBase: costBase, costLocal: local))
                summary.invested += costBase
            case .sell:
                var remaining = t.quantity
                var consumedCost = 0.0
                var consumedQty = 0.0
                var list = lots[t.ticker] ?? []
                while remaining > 1e-12, !list.isEmpty {
                    let take = min(remaining, list[0].qty)
                    let share = take / list[0].qty
                    consumedCost += list[0].costBase * share
                    list[0].costBase -= list[0].costBase * share
                    list[0].costLocal -= list[0].costLocal * share
                    list[0].qty -= take
                    remaining -= take
                    consumedQty += take
                    if list[0].qty <= 1e-12 { list.removeFirst() }
                }
                lots[t.ticker] = list
                guard t.quantity > 0, consumedQty > 0 else { continue }
                // Продать больше, чем есть, нельзя: считаем только проданную часть.
                let proceeds = toBase(t.gross - t.fee, t.currency, t.day) * (consumedQty / t.quantity)
                realized[t.ticker, default: 0] += proceeds - consumedCost
            case .dividend:
                dividends[t.ticker, default: 0] += toBase(t.gross - t.fee, t.currency, t.day)
            }
        }

        var holdings: [PfHolding] = []
        for (ticker, list) in lots {
            let qty = list.reduce(0) { $0 + $1.qty }
            guard qty > 1e-9 else { continue }
            let costBase = list.reduce(0) { $0 + $1.costBase }
            let costLocal = list.reduce(0) { $0 + $1.costLocal }
            let m = meta[ticker]
            let quote = quotes[ticker]
            let quoteCur = m?.quoteCurrency ?? quote?.currency ?? txnCurrency[ticker] ?? baseCode
            var h = PfHolding(ticker: ticker, indexId: indexOf[ticker] ?? "", name: m?.name ?? "", quantity: qty,
                              quoteCurrency: quoteCur, avgCost: costLocal / qty, costBase: costBase,
                              realized: realized[ticker] ?? 0, dividends: dividends[ticker] ?? 0,
                              sector: m?.sector, country: m?.country)
            if let quote, let v = fx.convert(quote.last * qty, from: quoteCur, to: baseCode, on: PfFX.latestDay) {
                h.last = quote.last
                h.value = v
                h.unrealized = v - costBase
                h.unrealizedPct = costBase > 0 ? (v - costBase) / costBase * 100 : nil
                if let prev = quote.prev, prev > 0,
                   let d = fx.convert((quote.last - prev) * qty, from: quoteCur, to: baseCode, on: PfFX.latestDay) {
                    h.todayChange = d
                    h.todayPct = (quote.last / prev - 1) * 100
                }
            } else {
                summary.missingPrices += 1
            }
            holdings.append(h)
        }

        // Закрытые позиции: в итог входит их реализованный результат и дивиденды.
        summary.realized = realized.values.reduce(0, +)
        summary.dividends = dividends.values.reduce(0, +)

        for h in holdings {
            guard let v = h.value else { continue }
            summary.value += v
            summary.cost += h.costBase
            summary.unrealized += h.unrealized ?? 0
            summary.todayChange += h.todayChange ?? 0
            if let y = meta[h.ticker]?.divYield, y > 0 { summary.expectedAnnualDividends += v * y / 100 }
        }
        let prevValue = summary.value - summary.todayChange
        summary.todayPct = prevValue > 0 ? summary.todayChange / prevValue * 100 : 0

        for i in holdings.indices {
            holdings[i].weight = summary.value > 0 ? (holdings[i].value ?? 0) / summary.value * 100 : 0
        }
        holdings.sort { ($0.value ?? 0) > ($1.value ?? 0) }
        return PfResult(holdings: holdings, summary: summary)
    }

    /// Доли по признаку (сектор, страна, валюта), по убыванию; без признака — "—" (подставляет экран).
    static func allocation(_ holdings: [PfHolding], key: (PfHolding) -> String?) -> [PfSlice] {
        var sums: [String: Double] = [:]
        for h in holdings { sums[key(h) ?? "—", default: 0] += h.value ?? 0 }
        return sums.filter { $0.value > 0 }.map { PfSlice(label: $0.key, value: $0.value) }
            .sorted { $0.value > $1.value }
    }
}

enum PfPortfolioDay { static let max = "9999-12-31" }

// MARK: График: доходность портфеля против индекса

enum PfPerformance {
    struct Point: Identifiable, Equatable {
        var day: String
        var portfolio: Double      // 100 = начало
        var benchmark: Double?
        var id: String { day }
    }

    /// Доходность портфеля с учётом вводов и выводов (цепочка дневных доходностей, как в TWR):
    /// покупка — ввод денег, продажа — вывод; сама покупка не считается доходом.
    static func series(transactions: [MyPortfolio.Transaction], base: PfBase, fx: PfFX,
                       histories: [String: [DailyClose]], quoteCurrency: [String: String],
                       benchmark: [DailyClose]?) -> [Point] {
        guard let first = transactions.map(\.day).min() else { return [] }
        let baseCode = base.rawValue
        // Сетка дат — даты бенчмарка (или объединение истории бумаг), начиная с первой сделки.
        var gridSet = Set<String>()
        if let benchmark { benchmark.forEach { gridSet.insert($0.date) } }
        if gridSet.isEmpty { histories.values.forEach { $0.forEach { gridSet.insert($0.date) } } }
        let grid = gridSet.filter { $0 >= first }.sorted()
        guard !grid.isEmpty else { return [] }

        let txns = PfCalc.ordered(transactions).filter { $0.type != .dividend }
        var cursor: [String: Int] = [:]
        func price(_ ticker: String, _ day: String) -> Double? {
            guard let h = histories[ticker], !h.isEmpty else { return nil }
            var i = cursor[ticker] ?? 0
            while i + 1 < h.count, h[i + 1].date <= day { i += 1 }
            cursor[ticker] = i
            return h[i].close
        }

        var result: [Point] = []
        var qty: [String: Double] = [:]
        var txIndex = 0
        var prevValue = 0.0
        var level = 100.0
        var benchBase: Double?
        let benchByDay: [String: Double] = benchmark.map { Dictionary($0.map { ($0.date, $0.close) }, uniquingKeysWith: { $1 }) } ?? [:]
        var started = false
        var lastDay = ""
        for day in grid {
            var flow = 0.0
            // Сделки до конца этого дня (включая до первого узла сетки).
            while txIndex < txns.count, txns[txIndex].day <= day {
                let t = txns[txIndex]
                let amount = fx.convert(t.gross, from: t.currency, to: baseCode, on: t.day) ?? t.gross
                if t.type == .buy {
                    qty[t.ticker, default: 0] += t.quantity
                    flow += amount + (fx.convert(t.fee, from: t.currency, to: baseCode, on: t.day) ?? t.fee)
                } else {
                    let sold = min(t.quantity, qty[t.ticker] ?? 0)
                    qty[t.ticker, default: 0] -= sold
                    flow -= amount * (t.quantity > 0 ? sold / t.quantity : 0)
                }
                txIndex += 1
            }
            var value = 0.0
            for (ticker, q) in qty where q > 1e-12 {
                guard let p = price(ticker, day) else { continue }
                let cur = quoteCurrency[ticker] ?? baseCode
                value += (fx.convert(p * q, from: cur, to: baseCode, on: day) ?? p * q)
            }
            if !started {
                guard value > 0 else { continue }
                started = true
                level = 100
            } else if prevValue > 0 {
                level *= (value - flow) / prevValue
            }
            prevValue = value
            if benchBase == nil, let b = benchByDay[day] { benchBase = b }
            var bench: Double?
            if let b = benchBase { bench = (benchByDay[day] ?? benchByDay[lastDay]).map { $0 / b * 100 } }
            lastDay = day
            result.append(Point(day: day, portfolio: level, benchmark: bench))
        }
        return result
    }
}

// MARK: CSV

enum PfCSV {
    static let header = "date,type,ticker,quantity,price,currency,fee,index"

    private static func number(_ v: Double) -> String {
        var s = String(format: "%.8f", v)
        while s.contains("."), s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    private static func field(_ s: String) -> String {
        s.contains(",") || s.contains("\"") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    static func export(_ txns: [MyPortfolio.Transaction]) -> String {
        var lines = [header]
        for t in PfCalc.ordered(txns) {
            lines.append([t.day, t.type.rawValue, field(t.ticker), number(t.quantity), number(t.price),
                          t.currency, number(t.fee), field(t.indexId)].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func split(_ line: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { cur.append("\""); i += 1 } else { quoted = false }
                } else { cur.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," || c == ";" { out.append(cur); cur = "" }
            else { cur.append(c) }
            i += 1
        }
        out.append(cur)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Колонки: date,type,ticker,quantity,price,currency,fee[,index]. Заголовок необязателен.
    /// Возвращает сделки и номера строк (с 1), которые не удалось прочитать.
    static func parse(_ text: String) -> (transactions: [MyPortfolio.Transaction], badLines: [Int]) {
        var txns: [MyPortfolio.Transaction] = []
        var bad: [Int] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (n, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let f = split(trimmed)
            if f.first?.lowercased() == "date" { continue }
            guard f.count >= 6, let date = PfDay.date(f[0]), let type = PfTxType(rawValue: f[1].lowercased()),
                  !f[2].isEmpty, let q = Double(f[3]), let p = Double(f[4]), q > 0, p >= 0, f[5].count == 3 else {
                bad.append(n + 1); continue
            }
            let fee = f.count > 6 ? (Double(f[6]) ?? (f[6].isEmpty ? 0 : -1)) : 0
            if fee < 0 { bad.append(n + 1); continue }
            txns.append(.init(ticker: f[2].uppercased(), indexId: f.count > 7 ? f[7] : "", type: type, date: date,
                              quantity: q, price: p, currency: f[5].uppercased(), fee: fee))
        }
        return (txns, bad)
    }
}
