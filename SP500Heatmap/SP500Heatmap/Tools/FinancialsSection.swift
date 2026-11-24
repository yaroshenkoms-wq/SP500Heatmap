import SwiftUI
import Charts

/// "Financials" block of the company page: statements, margins, ratios, analysts, famous holders.
/// Loads /api/v1/financials/{ticker}; shows nothing when the server has no data (crypto, ETFs, old server).
struct FinancialsSection: View {
    let ticker: String
    let currentPrice: Double
    @State private var data: Financials?
    @AppStorage("finQuarterly") private var quarterly = false

    private var periods: [FinancialPeriod] {
        let list = quarterly ? data?.quarterly ?? [] : data?.annual ?? []
        return list.isEmpty ? (quarterly ? data?.annual ?? [] : data?.quarterly ?? []) : list
    }

    var body: some View {
        Group {
            if let data, !data.isEmpty { content(data) }
        }
        .task(id: ticker) {
            data = try? await NetworkService.shared.fetchFinancials(ticker: ticker)
        }
    }

    private func content(_ data: Financials) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Financials")
                    .font(Theme.serif(.title3))
                    .foregroundColor(Theme.text)
                Spacer()
                if !data.annual.isEmpty && !data.quarterly.isEmpty {
                    HStack(spacing: 6) {
                        Button { quarterly = false } label: {
                            Text("Annual").themeChip(selected: !quarterly)
                        }
                        Button { quarterly = true } label: {
                            Text("Quarterly").themeChip(selected: quarterly)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            let ps = periods
            if ps.contains(where: { $0.revenue != nil || $0.netIncome != nil }) {
                card("Revenue and net income") {
                    FinBars(periods: ps, series: [
                        FinSeries(name: AppLanguage.string("Revenue"), color: Theme.gold, value: { $0.revenue }),
                        FinSeries(name: AppLanguage.string("Net income"), color: Theme.gold2.opacity(0.55), value: { $0.netIncome })
                    ], compact: true)
                }
            }
            if ps.contains(where: { ($0.revenue ?? 0) != 0 && ($0.grossProfit != nil || $0.operatingIncome != nil || $0.netIncome != nil) }) {
                card("Margins") {
                    FinLines(periods: ps)
                }
            }
            HStack(alignment: .top, spacing: 8) {
                if ps.contains(where: { $0.eps != nil }) {
                    card("EPS") {
                        FinBars(periods: ps, series: [FinSeries(name: "EPS", color: Theme.gold, value: { $0.eps })], compact: false)
                    }
                }
                if ps.contains(where: { $0.freeCashFlow != nil }) {
                    card("Free cash flow") {
                        FinBars(periods: ps, series: [FinSeries(name: AppLanguage.string("Free cash flow"), color: Theme.gold, value: { $0.freeCashFlow })], compact: true)
                    }
                }
            }
            if ps.contains(where: { $0.totalDebt != nil || $0.cash != nil }) {
                card("Debt and cash") {
                    FinBars(periods: ps, series: [
                        FinSeries(name: AppLanguage.string("Debt"), color: Theme.danger.opacity(0.85), value: { $0.totalDebt }),
                        FinSeries(name: AppLanguage.string("Cash"), color: Theme.ok.opacity(0.85), value: { $0.cash })
                    ], compact: true)
                }
            }
            if let r = data.ratios { ratiosGrid(r) }
            if let a = data.analysts, a.recommendation != nil || a.targetMean != nil {
                AnalystsCard(info: a, price: currentPrice, currency: data.currency)
            }
            if !data.holders.isEmpty { HoldersCard(holders: data.holders) }
            Text("Not investment advice.")
                .font(Theme.ui(.caption2))
                .foregroundColor(Theme.muted)
        }
        .padding(.horizontal)
    }

    private func card<C: View>(_ title: LocalizedStringKey, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.ui(.subheadline, weight: .medium)).foregroundColor(Theme.muted)
            body()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .panelCard()
    }

    // MARK: Ratios

    private func ratiosGrid(_ r: FinancialRatios) -> some View {
        let items: [(LocalizedStringKey, String?)] = [
            ("EV/EBITDA", r.evToEbitda.map { formatDecimal($0, fractionDigits: 1) }),
            ("PEG", r.peg.map { formatDecimal($0) }),
            ("P/FCF", r.priceToFcf.map { formatDecimal($0, fractionDigits: 1) }),
            ("ROE", r.roe.map { formatPercent($0) }),
            ("ROA", r.roa.map { formatPercent($0) }),
            ("Debt/Equity", r.debtToEquity.map { formatDecimal($0) }),
            ("Current ratio", r.currentRatio.map { formatDecimal($0) })
        ]
        let shown = items.filter { $0.1 != nil }
        return Group {
            if !shown.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
                        VStack(spacing: 2) {
                            Text(item.0).font(Theme.ui(.caption)).foregroundColor(Theme.muted)
                            Text(verbatim: item.1 ?? "").font(Theme.ui(.body, weight: .semibold)).foregroundColor(Theme.text)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .panelCard()
                    }
                }
            }
        }
    }
}

// MARK: Charts

struct FinSeries {
    let name: String
    let color: Color
    let value: (FinancialPeriod) -> Double?
}

private func shortPeriod(_ p: String) -> String {
    // "2026-Q3" -> "Q3 26", "2025" stays.
    if p.contains("-Q") {
        let parts = p.components(separatedBy: "-Q")
        if parts.count == 2 { return "Q\(parts[1]) \(parts[0].suffix(2))" }
    }
    return p
}

private func axisAmount(_ v: Double) -> String {
    let a = abs(v), sign = v < 0 ? "-" : ""
    if a >= 1e12 { return sign + formatDecimal(a / 1e12, fractionDigits: 1) + "T" }
    if a >= 1e9 { return sign + formatDecimal(a / 1e9, fractionDigits: a >= 1e10 ? 0 : 1) + "B" }
    if a >= 1e6 { return sign + formatDecimal(a / 1e6, fractionDigits: 0) + "M" }
    return sign + formatDecimal(a, fractionDigits: a < 100 ? 2 : 0)
}

struct FinBars: View {
    let periods: [FinancialPeriod]
    let series: [FinSeries]
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Chart {
                ForEach(periods) { p in
                    ForEach(series, id: \.name) { s in
                        if let v = s.value(p) {
                            BarMark(x: .value("Period", shortPeriod(p.period)), y: .value("Value", v))
                                .position(by: .value("Series", s.name))
                                .foregroundStyle(s.color)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Theme.line)
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(verbatim: compact ? axisAmount(v) : formatDecimal(v))
                                .font(Theme.ui(.caption2)).foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel().font(Theme.ui(.caption2)).foregroundStyle(Theme.muted)
                }
            }
            .frame(height: 150)
            .environment(\.layoutDirection, .leftToRight)
            if series.count > 1 {
                HStack(spacing: 12) {
                    ForEach(series, id: \.name) { s in
                        HStack(spacing: 4) {
                            Circle().fill(s.color).frame(width: 8, height: 8)
                            Text(verbatim: s.name).font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
                        }
                    }
                }
            }
        }
    }
}

/// Gross / operating / net margin per period, computed from the statements.
struct FinLines: View {
    let periods: [FinancialPeriod]
    private struct Pt: Identifiable { let id = UUID(); let period: String; let kind: String; let pct: Double }

    private var points: [Pt] {
        var out: [Pt] = []
        for p in periods {
            guard let rev = p.revenue, rev != 0 else { continue }
            if let g = p.grossProfit { out.append(Pt(period: shortPeriod(p.period), kind: AppLanguage.string("Gross"), pct: g / rev * 100)) }
            if let o = p.operatingIncome { out.append(Pt(period: shortPeriod(p.period), kind: AppLanguage.string("Operating"), pct: o / rev * 100)) }
            if let n = p.netIncome { out.append(Pt(period: shortPeriod(p.period), kind: AppLanguage.string("Net"), pct: n / rev * 100)) }
        }
        return out
    }

    private var kinds: [String] {
        var seen: [String] = []
        for p in points where !seen.contains(p.kind) { seen.append(p.kind) }
        return seen
    }

    private func color(_ kind: String) -> Color {
        switch kinds.firstIndex(of: kind) ?? 0 {
        case 0: return Theme.gold
        case 1: return Theme.gold2.opacity(0.6)
        default: return Theme.ok
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Chart(points) { pt in
                LineMark(x: .value("Period", pt.period), y: .value("Margin", pt.pct))
                    .foregroundStyle(by: .value("Kind", pt.kind))
                    .symbol(by: .value("Kind", pt.kind))
            }
            .chartForegroundStyleScale(domain: kinds, range: kinds.map { color($0) })
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Theme.line)
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(verbatim: formatDecimal(v, fractionDigits: 0) + "%")
                                .font(Theme.ui(.caption2)).foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
            .chartXAxis { AxisMarks { _ in AxisValueLabel().font(Theme.ui(.caption2)).foregroundStyle(Theme.muted) } }
            .frame(height: 130)
            .environment(\.layoutDirection, .leftToRight)
            HStack(spacing: 12) {
                ForEach(kinds, id: \.self) { k in
                    HStack(spacing: 4) {
                        Circle().fill(color(k)).frame(width: 8, height: 8)
                        Text(verbatim: k).font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
                    }
                }
            }
        }
    }
}

// MARK: Analysts

private struct AnalystsCard: View {
    let info: AnalystInfo
    let price: Double
    let currency: String?

    /// 0 = strong sell ... 1 = strong buy.
    private var score: Double? {
        guard let r = info.recommendation?.lowercased().replacingOccurrences(of: " ", with: "_") else { return nil }
        switch r {
        case "strong_buy": return 1
        case "buy", "outperform", "overweight": return 0.8
        case "hold", "neutral": return 0.5
        case "underperform", "underweight", "sell": return 0.2
        case "strong_sell": return 0
        default: return nil
        }
    }

    private var title: LocalizedStringKey {
        guard let s = score else { return "Hold" }
        switch s {
        case 1: return "Strong buy"
        case 0.8: return "Buy"
        case 0.5: return "Hold"
        case 0.2: return "Sell"
        default: return "Strong sell"
        }
    }

    private var current: Double { info.currentPrice ?? price }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Analysts").font(Theme.ui(.subheadline, weight: .medium)).foregroundColor(Theme.muted)
                Spacer()
                if let n = info.count, n > 0 {
                    Text("\(n) analysts").font(Theme.ui(.caption)).foregroundColor(Theme.muted)
                }
            }
            if let s = score {
                VStack(spacing: 6) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(LinearGradient(colors: [Theme.danger, Theme.chip, Theme.ok], startPoint: .leading, endPoint: .trailing))
                                .frame(height: 8)
                            Circle().fill(Theme.gold2).overlay(Circle().stroke(Theme.bg, lineWidth: 2))
                                .frame(width: 16, height: 16)
                                .offset(x: max(0, min(geo.size.width - 16, geo.size.width * s - 8)))
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .frame(height: 18)
                    .environment(\.layoutDirection, .leftToRight)
                    HStack {
                        Text("Sell").font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
                        Spacer()
                        Text(title).font(Theme.ui(.subheadline, weight: .semibold)).foregroundColor(Theme.gold)
                        Spacer()
                        Text("Buy").font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
                    }
                }
            }
            if let lo = info.targetLow, let hi = info.targetHigh, hi > lo {
                targetBar(lo: lo, hi: hi)
            } else if let mean = info.targetMean {
                HStack {
                    Text("Mean").font(Theme.ui(.subheadline)).foregroundColor(Theme.muted)
                    Spacer()
                    Text(verbatim: formatPrice(mean, currency: currency)).font(Theme.ui(.subheadline, weight: .medium)).foregroundColor(Theme.text)
                }
            }
            Text("Analyst opinions are not investment advice.")
                .font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .panelCard()
    }

    private func targetBar(lo: Double, hi: Double) -> some View {
        let lower = min(lo, current > 0 ? current : lo), upper = max(hi, current)
        let total = max(upper - lower, 0.0001)
        func pos(_ v: Double) -> Double { max(0, min(1, (v - lower) / total)) }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Price target").font(Theme.ui(.subheadline)).foregroundColor(Theme.muted)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.chip).frame(height: 6)
                    Capsule().fill(Theme.goldLine)
                        .frame(width: geo.size.width * (pos(hi) - pos(lo)), height: 6)
                        .offset(x: geo.size.width * pos(lo))
                    if let mean = info.targetMean {
                        Rectangle().fill(Theme.gold2).frame(width: 3, height: 14)
                            .offset(x: max(0, geo.size.width * pos(mean) - 1.5))
                    }
                    if current > 0 {
                        Circle().fill(Theme.text).frame(width: 12, height: 12)
                            .offset(x: max(0, min(geo.size.width - 12, geo.size.width * pos(current) - 6)))
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 16)
            .environment(\.layoutDirection, .leftToRight)
            HStack {
                VStack(alignment: .leading) {
                    Text("Low").font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
                    Text(verbatim: formatPrice(lo, currency: currency)).font(Theme.ui(.caption, weight: .medium)).foregroundColor(Theme.text)
                }
                Spacer()
                if let mean = info.targetMean {
                    VStack {
                        Text("Mean").font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
                        Text(verbatim: formatPrice(mean, currency: currency)).font(Theme.ui(.caption, weight: .semibold)).foregroundColor(Theme.gold)
                    }
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("High").font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
                    Text(verbatim: formatPrice(hi, currency: currency)).font(Theme.ui(.caption, weight: .medium)).foregroundColor(Theme.text)
                }
            }
            .environment(\.layoutDirection, .leftToRight)
            if current > 0, let mean = info.targetMean {
                let upside = (mean / current - 1) * 100
                HStack(spacing: 4) {
                    Text("Now").font(Theme.ui(.caption)).foregroundColor(Theme.muted)
                    Text(verbatim: formatPrice(current, currency: currency)).font(Theme.ui(.caption, weight: .medium)).foregroundColor(Theme.text)
                    Spacer()
                    Text(verbatim: formatPercent(upside)).font(Theme.ui(.caption, weight: .semibold)).foregroundColor(Theme.changeColor(upside))
                }
            }
        }
    }
}

// MARK: Famous holders

private struct HoldersCard: View {
    let holders: [FinancialHolder]

    private func badge(_ change: String?) -> (LocalizedStringKey, Color)? {
        switch change?.lowercased() {
        case "new": return ("New", Theme.gold)
        case "add": return ("Added", Theme.ok)
        case "reduce": return ("Reduced", Theme.danger)
        case "hold": return ("Unchanged", Theme.muted)
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Held by famous investors").font(Theme.ui(.subheadline, weight: .medium)).foregroundColor(Theme.muted)
            ForEach(Array(holders.prefix(12).enumerated()), id: \.element.id) { i, h in
                if i > 0 { Divider().overlay(Theme.line) }
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: h.name).font(Theme.ui(.subheadline, weight: .medium)).foregroundColor(Theme.text)
                            .multilineTextAlignment(.leading)
                        if let w = h.weightPct {
                            HStack(spacing: 3) {
                                Text("Portfolio weight").font(Theme.ui(.caption)).foregroundColor(Theme.muted)
                                Text(verbatim: formatDecimal(w, fractionDigits: 1) + "%").font(Theme.ui(.caption)).foregroundColor(Theme.muted)
                            }
                        }
                    }
                    Spacer(minLength: 6)
                    if let b = badge(h.changeQ) {
                        Text(b.0).font(Theme.ui(.caption2, weight: .semibold)).foregroundColor(b.1)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .overlay(Capsule().stroke(b.1.opacity(0.7), lineWidth: 1))
                    }
                }
                .padding(.vertical, 5)
            }
            Text("13F filings, latest quarter.").font(Theme.ui(.caption2)).foregroundColor(Theme.muted).padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .panelCard()
    }
}
