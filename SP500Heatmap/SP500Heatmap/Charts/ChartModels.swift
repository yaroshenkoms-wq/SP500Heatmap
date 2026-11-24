import Foundation

/// Одна свеча для графика (индекс в массиве — координата X, чтобы не было дыр на выходных).
struct ChartBar: Identifiable {
    let id: Int
    let date: Date
    let o: Double
    let h: Double
    let l: Double
    let c: Double
    let v: Double?
}

enum ProRange: String, CaseIterable, Identifiable {
    case m1 = "1m", m3 = "3m", m6 = "6m", y1 = "1y", y3 = "3y", y5 = "5y", y10 = "10y"
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }

    /// Примерно сколько календарных дней в диапазоне (для запасного варианта без /ohlc).
    var days: Int {
        switch self {
        case .m1: return 31
        case .m3: return 92
        case .m6: return 183
        case .y1: return 366
        case .y3: return 1096
        case .y5: return 1827
        case .y10: return 3653
        }
    }
}

enum ChartStyle: String, CaseIterable { case line, candles }
enum LowerPane: String, CaseIterable { case none, rsi, macd }

enum ChartOverlay: String, CaseIterable, Identifiable {
    case sma20, sma50, sma200, ema20
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sma20: return "SMA 20"
        case .sma50: return "SMA 50"
        case .sma200: return "SMA 200"
        case .ema20: return "EMA 20"
        }
    }
}

/// Какой ETF / индекс показывать как «индекс» для сравнения.
enum ChartIndexProxy {
    static func ticker(forIndexId id: String) -> String? {
        switch id {
        case "sp500": return "SPY"
        case "nasdaq100": return "QQQ"
        case "dow30": return "DIA"
        case "ibex35": return "^IBEX"
        case "dax40": return "^GDAXI"
        case "eurostoxx50": return "^STOXX50E"
        case "nikkei225": return "^N225"
        default: return nil
        }
    }

    /// Ряд индекса, пересчитанный на 100 в начале диапазона акции: берётся последняя известная
    /// цена индекса на дату каждой свечи. Пусто, если у индекса нет данных.
    static func rebased(index: [ChartBar], to stock: [ChartBar]) -> [Double?] {
        guard !index.isEmpty, !stock.isEmpty else { return [] }
        var values: [Double?] = []
        var j = 0
        for bar in stock {
            while j + 1 < index.count && index[j + 1].date <= bar.date { j += 1 }
            values.append(index[j].date <= bar.date ? index[j].c : nil)
        }
        guard let base = values.compactMap({ $0 }).first, base > 0 else { return [] }
        return values.map { $0.map { $0 / base * 100 } }
    }
}

enum ChartBarLoader {
    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func bars(from series: OHLCSeries) -> [ChartBar] {
        var out: [ChartBar] = []
        for b in series.bars {
            guard let d = parser.date(from: String(b.t.prefix(10))) else { continue }
            out.append(ChartBar(id: out.count, date: d, o: b.o, h: b.h, l: b.l, c: b.c, v: b.v))
        }
        return out
    }

    /// Запасной вариант, если на сервере нет /ohlc: линия по старой истории закрытий.
    static func fallbackBars(ticker: String, range: ProRange) async -> [ChartBar] {
        let closes: [DailyClose]
        switch range {
        case .y3, .y5, .y10:
            let key = range.rawValue
            if let long = try? await NetworkService.shared.fetchHistory(ticker: ticker, range: key), long.count >= 2 {
                closes = long
            } else {
                closes = (try? await NetworkService.shared.fetchHistory(ticker: ticker)) ?? []
            }
        default:
            closes = (try? await NetworkService.shared.fetchHistory(ticker: ticker)) ?? []
        }
        let dated = closes.compactMap { p -> (Date, Double)? in parser.date(from: p.date).map { ($0, p.close) } }
        guard let last = dated.last?.0 else { return [] }
        let cutoff = last.addingTimeInterval(-Double(range.days) * 86_400)
        let cut = dated.filter { $0.0 >= cutoff }
        return cut.enumerated().map { i, p in ChartBar(id: i, date: p.0, o: p.1, h: p.1, l: p.1, c: p.1, v: nil) }
    }
}
