import Foundation

// Calculation engine for model portfolios. A port of the udak.eu calculator
// (site/static/calc/core.js and models/hist/backtest.py) so the numbers match the site:
// monthly returns, weights reset to target in January of every year, missing early
// classes replaced by proxies, no fees. Only depends on Foundation.

struct PortfolioDataset: Decodable {
    struct Model: Decodable {
        let key: String
        let w: [String: Double]
        let risk: String
    }
    struct Era: Decodable {
        let id: String
        let start: String
        let end: String
    }
    let months: [String]
    let assets: [String: [Double?]]
    let cpi: [Double?]
    let fx: [Double?]
    let cpiEur: [Double?]
    let models: [Model]
    let eras: [Era]
}

enum PortfolioCurrency: String, CaseIterable {
    case usd = "USD", eur = "EUR"
}

enum PortfolioPeriod: String, CaseIterable, Identifiable {
    case y1, y5, y10, y20, y30, all
    var id: String { rawValue }
    /// Number of months, nil = whole history of the model.
    var months: Int? {
        switch self {
        case .y1: return 12
        case .y5: return 60
        case .y10: return 120
        case .y20: return 240
        case .y30: return 360
        case .all: return nil
        }
    }
}

struct PortfolioMetrics {
    var from: String
    var to: String
    var months: Int
    var cagr: Double
    var totalReturn: Double
    var maxDrawdown: Double
    var ddPeak: String
    var ddTrough: String
    var volatility: Double
    var worstYear: Double?
    var worstYearLabel: String?
    var bestYear: Double?
    var bestYearLabel: String?
}

struct PortfolioEraResult {
    var total: Double
    var annualized: Double?
    var maxDrawdown: Double
    var months: Int
}

/// Result of one run: monthly returns (nominal or real) with their months.
struct PortfolioRun {
    var firstIndex: Int
    var months: [String]
    var returns: [Double]
    var metrics: PortfolioMetrics

    /// Growth of `initial` with an optional monthly contribution at the start of every month
    /// (same as the site: value = (value + contribution) * (1 + r)). Index 0 is the starting amount.
    func growth(initial: Double = 10_000, monthly: Double = 0) -> [Double] {
        var out = [initial]
        out.reserveCapacity(returns.count + 1)
        var v = initial
        for r in returns {
            v = (v + monthly) * (1 + r)
            out.append(v)
        }
        return out
    }
}

final class PortfolioEngine {
    static let classes = ["us_large", "us_small", "us_large_value", "us_large_growth", "us_small_value", "intl_dev", "em", "reit",
                          "bond_short", "bond_mid", "bond_long", "bond_agg", "bond_corp", "tips", "cash", "gold", "commodities"]
    // Substitutes while a class has no data yet, in order. The order of keys matters: a proxy is filled first.
    private static let sub: [String: [String]] = ["intl_dev": ["us_large"], "em": ["intl_dev", "us_large"], "reit": ["us_large_value"],
                                                  "bond_short": ["cash"], "bond_long": ["bond_mid"], "bond_agg": ["bond_mid"],
                                                  "bond_corp": ["bond_mid"], "tips": ["bond_mid"]]
    private static let subOrder = ["intl_dev", "em", "reit", "bond_short", "bond_long", "bond_agg", "bond_corp", "tips"]

    let currency: PortfolioCurrency
    let months: [String]
    let eras: [PortfolioDataset.Era]
    private let eff: [String: [Double]]   // NaN = no data
    private let cpi: [Double]

    var count: Int { months.count }
    var lastMonth: String { months.last ?? "" }

    init(dataset d: PortfolioDataset, currency: PortfolioCurrency) {
        self.currency = currency
        var n = d.months.count
        let eur = currency == .eur
        if eur {
            while n > 0 && (d.fx[n - 1] == nil || d.cpiEur[n - 1] == nil) { n -= 1 }
        }
        months = Array(d.months.prefix(n))
        eras = d.eras
        var raw: [String: [Double]] = [:]
        for c in Self.classes {
            var a = [Double](repeating: .nan, count: n)
            let src = d.assets[c] ?? []
            for i in 0..<n {
                guard i < src.count, let v = src[i] else { continue }
                if eur {
                    guard let f = d.fx[i] else { continue }
                    a[i] = (1 + v) * (1 + f) - 1
                } else {
                    a[i] = v
                }
            }
            raw[c] = a
        }
        for c in Self.subOrder {
            for i in 0..<n where raw[c]![i].isNaN {
                for s in Self.sub[c] ?? [] {
                    let v2 = raw[s]![i]
                    if !v2.isNaN { raw[c]![i] = v2; break }
                }
            }
        }
        eff = raw
        cpi = (0..<n).map { i in (eur ? d.cpiEur[i] : d.cpi[i]) ?? .nan }
    }

    // MARK: Series

    /// Monthly series of a portfolio from the first month (>= `from`) with data for all its classes.
    /// Weights drift between January resets.
    func portfolioReturns(weights: [String: Double], from: String? = nil, to: String? = nil) -> (first: Int, returns: [Double])? {
        var w: [String: Double] = [:]
        var s = 0.0
        for (_, v) in weights where v > 0 { s += v }
        guard s > 0 else { return nil }
        for (c, v) in weights where v > 0 { w[c] = v / s }
        let cl = Array(w.keys).sorted()
        var first = -1
        for i in 0..<count {
            if let from, months[i] < from { continue }
            if cl.allSatisfy({ !eff[$0]![i].isNaN }) { first = i; break }
        }
        guard first >= 0 else { return nil }
        var last = count - 1
        if let to { while last > first && months[last] > to { last -= 1 } }
        var hold = [String: Double]()
        var rets = [Double]()
        rets.reserveCapacity(last - first + 1)
        for i in first...last {
            if i == first || months[i].dropFirst(5) == "01" { hold = w }
            var r = 0.0
            for c in cl { r += hold[c]! * eff[c]![i] }
            rets.append(r)
            let tot = 1 + r
            for c in cl { hold[c] = hold[c]! * (1 + eff[c]![i]) / tot }
        }
        return (first, rets)
    }

    /// Full run with metrics. `real` deflates every month by CPI like the site.
    func run(weights: [String: Double], from: String? = nil, to: String? = nil, real: Bool = false) -> PortfolioRun? {
        guard let p = portfolioReturns(weights: weights, from: from, to: to) else { return nil }
        let ms = Array(months[p.first..<(p.first + p.returns.count)])
        var rets = p.returns
        if real {
            for i in 0..<rets.count { rets[i] = (1 + rets[i]) / (1 + cpi[p.first + i]) - 1 }
        }
        guard let m = Self.metrics(months: ms, rets: rets) else { return nil }
        return PortfolioRun(firstIndex: p.first, months: ms, returns: rets, metrics: m)
    }

    /// Run for a period ending at the last month. A fixed period requires data for the whole window
    /// (otherwise nil, "n/a"); `.all` starts at the model's own first month.
    func run(weights: [String: Double], period: PortfolioPeriod, real: Bool = false) -> PortfolioRun? {
        guard let n = period.months else { return run(weights: weights, real: real) }
        guard count >= n else { return nil }
        let startIdx = count - n
        guard let r = run(weights: weights, from: months[startIdx], real: real), r.firstIndex == startIdx else { return nil }
        return r
    }

    // MARK: Metrics

    static func cagr(_ rets: ArraySlice<Double>) -> Double {
        guard !rets.isEmpty else { return 0 }
        var s = 0.0
        for r in rets { s += log1p(r) }
        return exp(s * 12 / Double(rets.count)) - 1
    }

    static func drawdown(_ rets: ArraySlice<Double>) -> (depth: Double, peak: Int, trough: Int) {
        var peak = 1.0, v = 1.0, worst = 0.0, wp = 0, wt = 0, peakIdx = 0
        for (k, r) in rets.enumerated() {
            v *= 1 + r
            if v > peak { peak = v; peakIdx = k + 1 }
            let dd = v / peak - 1
            if dd < worst { worst = dd; wp = peakIdx; wt = k }
        }
        return (worst, wp, wt)
    }

    /// Series of drawdowns for a chart.
    static func drawdownSeries(_ rets: [Double]) -> [Double] {
        var out = [Double](), peak = 1.0, v = 1.0
        for r in rets { v *= 1 + r; peak = max(peak, v); out.append(v / peak - 1) }
        return out
    }

    static func metrics(months: [String], rets: [Double]) -> PortfolioMetrics? {
        let n = rets.count
        guard n >= 12, months.count == n else { return nil }
        let mean = rets.reduce(0, +) / Double(n)
        var ss = 0.0
        for r in rets { ss += (r - mean) * (r - mean) }
        let vol = (ss / Double(n - 1)).squareRoot() * 12.0.squareRoot()
        let dd = drawdown(rets[...])
        var total = 1.0
        for r in rets { total *= 1 + r }
        // calendar years that are complete (12 months)
        var years: [String: [Double]] = [:]
        var order: [String] = []
        for i in 0..<n {
            let y = String(months[i].prefix(4))
            if years[y] == nil { years[y] = []; order.append(y) }
            years[y]!.append(rets[i])
        }
        var worst = Double.infinity, best = -Double.infinity, wl: String?, bl: String?
        for y in order {
            guard let rs = years[y], rs.count == 12 else { continue }
            let g = rs.reduce(1.0) { $0 * (1 + $1) } - 1
            if g < worst { worst = g; wl = y }
            if g > best { best = g; bl = y }
        }
        return PortfolioMetrics(from: months[0], to: months[n - 1], months: n, cagr: cagr(rets[...]), totalReturn: total - 1,
                                maxDrawdown: dd.depth, ddPeak: months[min(dd.peak, n - 1)], ddTrough: months[dd.trough], volatility: vol,
                                worstYear: wl == nil ? nil : worst, worstYearLabel: wl, bestYear: bl == nil ? nil : best, bestYearLabel: bl)
    }

    // MARK: Eras

    /// Result per era id, only for eras lying fully inside the run.
    func eraResults(for run: PortfolioRun) -> [String: PortfolioEraResult] {
        var pos: [String: Int] = [:]
        for (i, m) in run.months.enumerated() { pos[m] = i }
        var out: [String: PortfolioEraResult] = [:]
        for e in eras {
            guard let a = pos[e.start], let b = pos[e.end], b >= a else { continue }
            let part = run.returns[a...b]
            let g = part.reduce(1.0) { $0 * (1 + $1) }
            out[e.id] = PortfolioEraResult(total: g - 1,
                                           annualized: part.count >= 12 ? pow(g, 12 / Double(part.count)) - 1 : nil,
                                           maxDrawdown: Self.drawdown(part).depth, months: part.count)
        }
        return out
    }
}
