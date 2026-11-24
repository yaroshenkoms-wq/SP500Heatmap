import SwiftUI
import Charts

// MARK: Карта позиций

struct PfTreemapCard: View {
    let holdings: [PfHolding]
    @State private var mode = 0   // 0 — за сегодня, 1 — общий результат

    private var shown: [PfHolding] { holdings.filter { ($0.value ?? 0) > 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Holdings map").font(Theme.ui(.headline)).foregroundColor(Theme.text)
                Spacer()
                PortfolioChip(title: "Today", selected: mode == 0) { mode = 0 }
                PortfolioChip(title: "Total P/L", selected: mode == 1) { mode = 1 }
            }
            if shown.isEmpty {
                Text("No data yet.").font(Theme.ui(.subheadline)).foregroundColor(Theme.muted)
            } else {
                TreemapLayout(weights: shown.map { $0.value ?? 0 }) {
                    ForEach(shown) { h in tile(h) }
                }
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("holdingsTreemap")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
    }

    private func pct(_ h: PfHolding) -> Double? { mode == 0 ? h.todayPct : h.unrealizedPct }

    private func tile(_ h: PfHolding) -> some View {
        let p = pct(h)
        return ZStack {
            Rectangle().fill(SharedHeat.color(for: p, cap: mode == 0 ? 3 : 30))
            VStack(spacing: 2) {
                Text(verbatim: h.ticker).font(Theme.ui(.caption, weight: .semibold))
                if let p { Text(verbatim: pfSignedPercent(p)).font(Theme.ui(.caption2)) }
            }
            .foregroundColor(HeatmapColor.tileText)
            .minimumScaleFactor(0.5).lineLimit(1)
            .padding(2)
        }
        .overlay(Rectangle().strokeBorder(Theme.bg, lineWidth: 1))
    }
}

// MARK: Структура: сектор / страна / валюта

struct PfAllocationCard: View {
    let holdings: [PfHolding]
    let base: PfBase
    @State private var mode = 0

    static let palette: [Color] = [
        Color(hex: 0xC9A96E), Color(hex: 0x6FA8C9), Color(hex: 0x8FBF9A), Color(hex: 0xC97F9A),
        Color(hex: 0x9A8FD0), Color(hex: 0xD99A5B), Color(hex: 0x5BB5B0), Color(hex: 0xB0B05B), Color(hex: 0x8A8478)
    ]

    private var slices: [PfSlice] {
        let raw: [PfSlice]
        switch mode {
        case 0: raw = PfCalc.allocation(holdings) { $0.sector }
        case 1: raw = PfCalc.allocation(holdings) { $0.country }
        default: raw = PfCalc.allocation(holdings) { $0.quoteCurrency }
        }
        // Мелкие доли сливаем в «Other», чтобы график читался.
        let top = Array(raw.prefix(8))
        let rest = raw.dropFirst(8).reduce(0) { $0 + $1.value }
        return rest > 0 ? top + [PfSlice(label: "·other", value: rest)] : top
    }

    private func label(_ s: PfSlice) -> String {
        if s.label == "·other" { return AppLanguage.string("Other") }
        if s.label == "—" { return AppLanguage.string("Unknown") }
        switch mode {
        case 0: return localizedSectorName(s.label)
        case 1: return pfCountryName(s.label)
        default: return s.label
        }
    }

    var body: some View {
        let data = slices
        let total = data.reduce(0) { $0 + $1.value }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Allocation").font(Theme.ui(.headline)).foregroundColor(Theme.text)
                Spacer()
                PortfolioChip(title: "Sector", selected: mode == 0) { mode = 0 }
                PortfolioChip(title: "Country", selected: mode == 1) { mode = 1 }
                PortfolioChip(title: "Currency", selected: mode == 2) { mode = 2 }
            }
            if data.isEmpty {
                Text("No data yet.").font(Theme.ui(.subheadline)).foregroundColor(Theme.muted)
            } else {
                HStack(alignment: .center, spacing: 16) {
                    Chart(Array(data.enumerated()), id: \.element.id) { i, s in
                        SectorMark(angle: .value("Value", s.value), innerRadius: .ratio(0.62), angularInset: 1)
                            .foregroundStyle(Self.palette[i % Self.palette.count])
                    }
                    .frame(width: 140, height: 140)
                    .accessibilityIdentifier("allocationDonut")
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(data.enumerated()), id: \.element.id) { i, s in
                            HStack(spacing: 6) {
                                Circle().fill(Self.palette[i % Self.palette.count]).frame(width: 8, height: 8)
                                Text(verbatim: label(s)).font(Theme.ui(.caption)).foregroundColor(Theme.text).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(verbatim: formatPercent(total > 0 ? s.value / total * 100 : 0))
                                    .font(Theme.ui(.caption)).foregroundColor(Theme.muted)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
    }
}

// MARK: Доходность против индекса

struct PfPerformanceCard: View {
    let portfolio: MyPortfolio
    @ObservedObject private var market = PfMarketData.shared
    @ObservedObject private var store = MyPortfolioStore.shared
    @EnvironmentObject private var indexStore: IndexStore

    @State private var points: [PfPerformance.Point] = []
    @State private var loading = false
    @State private var benchmarkMissing = false
    @State private var window = "all"

    private static let windows: [(String, LocalizedStringKey, Int?)] = [
        ("1m", "1M", 30), ("6m", "6M", 182), ("1y", "1Y", 365), ("all", "All", nil)
    ]

    private var benchmarkName: String {
        indexStore.indices.first { $0.id == portfolio.benchmark }?.name ?? "S&P 500"
    }

    /// Окно по времени, пересчитанное так, чтобы начало было 100.
    private var shown: [PfPerformance.Point] {
        guard let days = Self.windows.first(where: { $0.0 == window })?.2, let last = points.last,
              let end = PfDay.date(last.day) else { return points }
        let cutoff = PfDay.string(end.addingTimeInterval(-Double(days) * 86400))
        let part = points.filter { $0.day >= cutoff }
        guard let f = part.first else { return points }
        return part.map {
            PfPerformance.Point(day: $0.day, portfolio: $0.portfolio / f.portfolio * 100,
                                benchmark: ($0.benchmark != nil && f.benchmark != nil) ? $0.benchmark! / f.benchmark! * 100 : nil)
        }
    }

    var body: some View {
        let data = shown
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Performance").font(Theme.ui(.headline)).foregroundColor(Theme.text)
                Spacer()
                ForEach(Self.windows, id: \.0) { w in
                    PortfolioChip(title: w.1, selected: window == w.0) { window = w.0 }
                }
            }
            HStack(spacing: 6) {
                Text("vs").font(Theme.ui(.caption)).foregroundColor(Theme.muted)
                Menu {
                    ForEach(indexStore.indices) { idx in
                        Button(idx.name) { var p = portfolio; p.benchmark = idx.id; store.update(p) }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(verbatim: benchmarkName).font(Theme.ui(.caption, weight: .medium))
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .foregroundColor(Theme.gold)
                }
                Spacer()
                if let f = data.first, let l = data.last {
                    let r = l.portfolio / f.portfolio * 100 - 100
                    Text(verbatim: pfSignedPercent(r)).font(Theme.ui(.caption, weight: .semibold)).foregroundColor(Theme.changeColor(r))
                    if let fb = f.benchmark, let lb = l.benchmark {
                        let b = lb / fb * 100 - 100
                        Text(verbatim: pfSignedPercent(b)).font(Theme.ui(.caption)).foregroundColor(Theme.muted)
                    }
                }
            }
            if data.count > 1 {
                chart(data)
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Text("Not enough price history yet.").font(Theme.ui(.subheadline)).foregroundColor(Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
            if benchmarkMissing && !data.isEmpty {
                Text("Index history is not available from the server yet; showing the portfolio only.")
                    .font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
        .task(id: key) { await load() }
    }

    private var key: String {
        portfolio.id.uuidString + portfolio.benchmark + portfolio.baseCurrency.rawValue
            + String(portfolio.transactions.count) + String(market.fx.series.values.reduce(0) { $0 + $1.count }) + String(market.quotes.count)
    }

    private func chart(_ data: [PfPerformance.Point]) -> some View {
        let vals = data.flatMap { [$0.portfolio, $0.benchmark ?? $0.portfolio] }
        let lo = (vals.min() ?? 90) - 2, hi = (vals.max() ?? 110) + 2
        return Chart {
            ForEach(data) { p in
                if let b = p.benchmark {
                    LineMark(x: .value("Date", PfDay.date(p.day) ?? Date()), y: .value("Index", b), series: .value("S", "b"))
                        .foregroundStyle(Theme.muted).lineStyle(StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
                }
                LineMark(x: .value("Date", PfDay.date(p.day) ?? Date()), y: .value("Portfolio", p.portfolio), series: .value("S", "p"))
                    .foregroundStyle(Theme.gold).lineStyle(StrokeStyle(lineWidth: 2))
            }
        }
        .chartYScale(domain: lo...hi)
        .chartYAxis { AxisMarks(position: .trailing) { _ in AxisGridLine().foregroundStyle(Theme.line); AxisValueLabel().foregroundStyle(Theme.muted) } }
        .chartXAxis { AxisMarks { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits)).foregroundStyle(Theme.muted) } }
        .frame(height: 190)
        .accessibilityIdentifier("performanceChart")
    }

    private func load() async {
        guard !portfolio.transactions.isEmpty else { points = []; return }
        loading = true
        defer { loading = false }
        let range = PfMarketData.range(forOldest: portfolio.firstDay)
        var histories: [String: [DailyClose]] = [:]
        for t in portfolio.tickers { histories[t] = await market.history(t, range: range) }
        let bench = await market.benchmarkHistory(portfolio.benchmark, range: range)
        benchmarkMissing = bench == nil
        var currencies: [String: String] = [:]
        for t in portfolio.tickers { currencies[t] = market.meta[t]?.quoteCurrency ?? market.quotes[t]?.currency }
        points = PfPerformance.series(transactions: portfolio.transactions, base: portfolio.baseCurrency, fx: market.fx,
                                      histories: histories, quoteCurrency: currencies.compactMapValues { $0 },
                                      benchmark: bench)
    }
}
