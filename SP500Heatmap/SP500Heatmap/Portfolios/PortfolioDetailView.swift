import SwiftUI
import Charts

struct PortfolioDetailView: View {
    @StateObject private var store = PortfolioStore.shared
    let info: PortfolioInfo
    @AppStorage("pfPeriod") private var periodRaw = PortfolioPeriod.y10.rawValue
    @AppStorage("pfCurrency") private var currencyRaw = PortfolioCurrency.usd.rawValue
    @AppStorage("pfReal") private var real = false
    @State private var logScale = false
    @State private var showCalculator = false

    private var period: Binding<PortfolioPeriod> {
        Binding(get: { PortfolioPeriod(rawValue: periodRaw) ?? .y10 }, set: { periodRaw = $0.rawValue })
    }
    private var currency: Binding<PortfolioCurrency> {
        Binding(get: { PortfolioCurrency(rawValue: currencyRaw) ?? .usd }, set: { currencyRaw = $0.rawValue })
    }

    private static let palette: [Color] = [Color(hex: 0xC9A96E), Color(hex: 0x8FBF9A), Color(hex: 0x7FA8D1), Color(hex: 0xD69DC2),
                                           Color(hex: 0xE0A15C), Color(hex: 0xA79BD6), Color(hex: 0x9C968A), Color(hex: 0xD6D06E)]

    private var sortedWeights: [(String, Double)] {
        info.weights.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    var body: some View {
        let p = period.wrappedValue, c = currency.wrappedValue
        let run = store.run(info, period: p, currency: c, real: real)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                PortfolioOptionsBar(period: period, currency: currency, real: $real).padding(.horizontal, -16)
                if let run {
                    metricsGrid(run, period: p, currency: c)
                    growthSection(run, currency: c)
                } else {
                    Text("Not enough history").font(Theme.ui(.footnote)).foregroundColor(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12).panelCard()
                }
                allocationSection
                erasSection(currency: c)
                aboutSection
                Button { showCalculator = true } label: {
                    Label { Text("Calculator") } icon: { Image(systemName: "function") }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(OutlinedButtonStyle())
                PortfolioDisclaimer()
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .themeScreen()
        .navigationTitle(Text("Portfolio"))
        .navigationBarTitleDisplayMode(.inline)
        .themeNavBar()
        .sheet(isPresented: $showCalculator) {
            PortfolioCalculatorView(initialKeys: [info.key])
                .presentationSizing(.form)
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: store.name(info.key))
                .font(Theme.serif(.title))
                .foregroundColor(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                RiskBadge(risk: info.risk)
                let author = store.author(info.key)
                let year = store.year(info.key)
                if !author.isEmpty {
                    Text(verbatim: year.isEmpty ? author : "\(author) · \(year)")
                        .font(Theme.ui(.caption)).foregroundColor(Theme.muted).lineLimit(2)
                }
            }
            if store.namesAreMachineMade && info.key != PortfolioStore.referenceKey {
                Text("Name translated automatically").font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
            }
            let short = store.shortText(info.key)
            if !short.isEmpty {
                Text(verbatim: short).font(Theme.ui(.subheadline)).foregroundColor(Theme.text.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                if store.descriptionsAreEnglishFallback {
                    Text("Text is shown in English for this language.").font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
                }
            }
        }
    }

    private func metricsGrid(_ run: PortfolioRun, period: PortfolioPeriod, currency: PortfolioCurrency) -> some View {
        let m = run.metrics
        let ref = store.reference.flatMap { store.run($0, from: m.from, to: nil, currency: currency, real: real) }
        let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "\(PortfolioFormat.month(m.from)) – \(PortfolioFormat.month(m.to))")
                .font(Theme.ui(.caption)).foregroundColor(Theme.muted)
            LazyVGrid(columns: cols, spacing: 10) {
                MetricCell(title: "Return per year", value: PortfolioFormat.percent(m.cagr),
                           sub: ref.map { "S&P 500: " + PortfolioFormat.percent($0.metrics.cagr) }, tint: Theme.changeColor(m.cagr))
                MetricCell(title: "Total return", value: PortfolioFormat.percent(m.totalReturn, digits: 0), tint: Theme.changeColor(m.totalReturn))
                MetricCell(title: "Max drawdown", value: PortfolioFormat.percent(m.maxDrawdown),
                           sub: "\(PortfolioFormat.month(m.ddPeak)) → \(PortfolioFormat.month(m.ddTrough))", tint: Theme.danger)
                MetricCell(title: "Volatility", value: PortfolioFormat.percent(m.volatility),
                           sub: ref.map { "S&P 500: " + PortfolioFormat.percent($0.metrics.volatility) })
                MetricCell(title: "Worst year", value: m.worstYear.map { PortfolioFormat.percent($0) } ?? "—",
                           sub: m.worstYearLabel, tint: Theme.danger)
                MetricCell(title: "Best year", value: m.bestYear.map { PortfolioFormat.percent($0) } ?? "—",
                           sub: m.bestYearLabel, tint: Theme.ok)
            }
        }
    }

    private func growthSection(_ run: PortfolioRun, currency: PortfolioCurrency) -> some View {
        let start = 10_000.0
        let ref = store.reference.flatMap { store.run($0, from: run.metrics.from, to: nil, currency: currency, real: real) }
        var lines = [GrowthChart.Line(name: store.name(info.key), color: Theme.gold, dashed: false,
                                      points: chartPoints(months: run.months, values: run.growth(initial: start), series: "m"))]
        if info.key != PortfolioStore.referenceKey, let ref {
            lines.append(GrowthChart.Line(name: store.name(PortfolioStore.referenceKey), color: Theme.muted, dashed: true,
                                          points: chartPoints(months: ref.months, values: ref.growth(initial: start), series: "s")))
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Growth of \(PortfolioFormat.money(start, currency: currency))")
                    .font(Theme.ui(.headline)).foregroundColor(Theme.text)
                Spacer()
                PortfolioChip(title: "Log scale", selected: logScale) { logScale.toggle() }
            }
            GrowthChart(lines: lines, currency: currency, log: logScale)
            ChartLegend(items: lines.map { ($0.name, $0.color, $0.dashed) })
            if let last = run.growth(initial: start).last {
                Text(verbatim: PortfolioFormat.money(last, currency: currency))
                    .font(Theme.ui(.subheadline, weight: .semibold)).foregroundColor(Theme.gold)
            }
        }
        .padding(12)
        .panelCard()
    }

    private var allocationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Allocation").font(Theme.ui(.headline)).foregroundColor(Theme.text)
            HStack(alignment: .center, spacing: 14) {
                Chart(Array(sortedWeights.enumerated()), id: \.offset) { i, w in
                    SectorMark(angle: .value("Weight", w.1), innerRadius: .ratio(0.6), angularInset: 1.5)
                        .foregroundStyle(Self.palette[i % Self.palette.count])
                }
                .frame(width: 130, height: 130)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(sortedWeights.enumerated()), id: \.offset) { i, w in
                        HStack(spacing: 6) {
                            Circle().fill(Self.palette[i % Self.palette.count]).frame(width: 8, height: 8)
                            Text(verbatim: store.className(w.0)).font(Theme.ui(.caption2)).foregroundColor(Theme.text)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Text(verbatim: PortfolioFormat.percent(w.1, digits: w.1 * 100 == (w.1 * 100).rounded() ? 0 : 1))
                                .font(Theme.ui(.caption2, weight: .semibold)).foregroundColor(Theme.gold)
                        }
                    }
                }
            }
        }
        .padding(12)
        .panelCard()
    }

    @ViewBuilder
    private func erasSection(currency: PortfolioCurrency) -> some View {
        if let engine = store.engine(currency),
           let full = store.run(info, period: .all, currency: currency, real: real),
           let refFull = store.reference.flatMap({ store.run($0, period: .all, currency: currency, real: real) }) {
            let mine = engine.eraResults(for: full)
            let spy = engine.eraResults(for: refFull)
            let eras = engine.eras.filter { mine[$0.id] != nil }
            if !eras.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Historical eras").font(Theme.ui(.headline)).foregroundColor(Theme.text)
                    HStack {
                        Text("Era").frame(maxWidth: .infinity, alignment: .leading)
                        Text("This portfolio").frame(width: 78, alignment: .trailing).lineLimit(1).minimumScaleFactor(0.6)
                        Text(verbatim: "S&P 500").frame(width: 70, alignment: .trailing).lineLimit(1).minimumScaleFactor(0.6)
                    }
                    .font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
                    ForEach(eras, id: \.id) { e in
                        if let r = mine[e.id] {
                            Divider().overlay(Theme.line)
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: store.eraName(e.id)).font(Theme.ui(.caption)).foregroundColor(Theme.text)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(verbatim: "\(PortfolioFormat.month(e.start)) – \(PortfolioFormat.month(e.end))")
                                        .font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(verbatim: PortfolioFormat.percent(r.total, digits: 0, signed: true))
                                    .font(Theme.ui(.caption, weight: .semibold)).foregroundColor(Theme.changeColor(r.total))
                                    .frame(width: 78, alignment: .trailing)
                                Text(verbatim: spy[e.id].map { PortfolioFormat.percent($0.total, digits: 0, signed: true) } ?? "—")
                                    .font(Theme.ui(.caption)).foregroundColor(spy[e.id].map { Theme.changeColor($0.total) } ?? Theme.muted)
                                    .frame(width: 70, alignment: .trailing)
                            }
                        }
                    }
                    Text("Total return over each era.").font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
                }
                .padding(12)
                .panelCard()
            }
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        let rationale = store.rationale(info.key)
        let crit = store.criticisms(info.key)
        let sources = store.sources(info.key)
        if !rationale.isEmpty || !sources.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if !rationale.isEmpty {
                    Text("Rationale").font(Theme.ui(.headline)).foregroundColor(Theme.text)
                    Text(verbatim: rationale).font(Theme.ui(.footnote)).foregroundColor(Theme.text.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !crit.isEmpty {
                    Text("Criticism").font(Theme.ui(.headline)).foregroundColor(Theme.text).padding(.top, 4)
                    ForEach(crit, id: \.self) { c in
                        HStack(alignment: .top, spacing: 6) {
                            Text(verbatim: "•").foregroundColor(Theme.gold)
                            Text(verbatim: c).font(Theme.ui(.footnote)).foregroundColor(Theme.text.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if !sources.isEmpty {
                    Text("Sources").font(Theme.ui(.headline)).foregroundColor(Theme.text).padding(.top, 4)
                    ForEach(sources, id: \.self) { s in
                        if let url = URL(string: s) {
                            Link(destination: url) {
                                Text(verbatim: url.host ?? s).font(Theme.ui(.caption)).foregroundColor(Theme.gold)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                if store.descriptionsAreEnglishFallback {
                    Text("Text is shown in English for this language.").font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .panelCard()
        }
    }
}
