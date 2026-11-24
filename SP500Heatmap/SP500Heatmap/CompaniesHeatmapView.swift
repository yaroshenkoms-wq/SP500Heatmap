import SwiftUI

struct CompaniesHeatmapView: View {
    let subsector: Subsector
    @ObservedObject var webSocketManager: WebSocketManager
    @ObservedObject var performanceStore: PerformanceStore
    @State private var selectedPeriod = "SC"
    @EnvironmentObject private var indexStore: IndexStore
    @AppStorage(ColorMetric.storageKey) private var metricRaw = "change"
    @ObservedObject private var metrics = MetricStore.shared

    private var metricOptions: [ColorMetric] { metrics.available(for: indexStore.selectedId) }
    private var metric: ColorMetric {
        let m = ColorMetric(rawValue: metricRaw) ?? .change
        return metricOptions.contains(m) ? m : .change
    }
    private var metricBinding: Binding<ColorMetric> {
        Binding(get: { metric }, set: { metricRaw = $0.rawValue })
    }
    @Environment(\.dismiss) private var dismiss

    private func changePercent(for ticker: String) -> Double? {
        let period = indexStore.effectivePeriod(selectedPeriod)
        if period == "SC" {
            // Нет живой цены (например, ASML в Nasdaq-100 вне подписки Finnhub) — берём изменение за день.
            return webSocketManager.priceUpdates[ticker]?.changePercent
                ?? performanceStore.changePercent(for: ticker, period: "1d")
        }
        return performanceStore.changePercent(for: ticker, period: period)
    }

    var companiesWithChanges: [(company: Company, change: Double?)] {
        subsector.companies.map { company in
            (company, metric == .change ? changePercent(for: company.ticker)
                : metrics.value(metric, ticker: company.ticker, index: indexStore.selectedId))
        }
    }

    // Пересчитывается от selectedPeriod вместо статичного значения с
    // родительского экрана, иначе заголовок не реагирует на смену периода.
    var subsectorChange: Double {
        var weightedChange = 0.0
        var totalWeight = 0.0
        for company in subsector.companies {
            if let change = changePercent(for: company.ticker) {
                let w = startWeight(company.marketCap, change)
                weightedChange += change * w
                totalWeight += w
            }
        }
        return totalWeight > 0 ? weightedChange / totalWeight : 0
    }
    
    // Сортировка по убыванию капитализации
    var sortedCompaniesWithChanges: [(company: Company, change: Double?)] {
        companiesWithChanges.sorted { $0.company.marketCap > $1.company.marketCap }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                HStack {
                    Button(action: { dismiss() }) {
                        HStack {
                            Image(systemName: "chevron.backward")
                            Text("Back")
                        }
                        .font(Theme.ui(.subheadline, weight: .medium))
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .outlinedControl()
                    }
                    .buttonStyle(.plain)
                    HomeButton()
                    Spacer()
                    Text(verbatim: localizedSectorName(subsector.name))
                        .font(Theme.serif(.title))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Spacer()
                    ShareMapButton(title: localizedSectorName(subsector.name) + " · " + indexStore.current.name,
                                   subtitle: shareSubtitle(period: indexStore.effectivePeriod(selectedPeriod),
                                                           asOf: indexStore.current.historyThrough)) {
                        TreemapLayout(weights: sortedCompaniesWithChanges.map { SizeMode.weight($0.company.marketCap) }) {
                            ForEach(sortedCompaniesWithChanges, id: \.company.ticker) { item in
                                CompanyTile(company: item.company, changePercent: item.change, metric: metric, period: indexStore.effectivePeriod(selectedPeriod))
                            }
                        }
                    }
                    Text(formatPercent(subsectorChange))
                        .font(Theme.ui(.title2, weight: .medium))
                        .foregroundColor(Theme.changeColor(subsectorChange))
                }
                .padding(.horizontal)
                MetricPeriodRow(period: $selectedPeriod, metric: metricBinding, options: metricOptions)
                MetricLegend(metric: metric)
                ClosingPricesNote()
            }
            .padding(.top, 8)
            .background(Theme.bg)
            
            GeometryReader { geometry in
                TreemapLayout(weights: sortedCompaniesWithChanges.map { SizeMode.weight($0.company.marketCap) }) {
                    ForEach(sortedCompaniesWithChanges, id: \.company.ticker) { item in
                        NavigationLink(destination: CompanyDetailView(company: item.company, webSocketManager: webSocketManager)) {
                            CompanyTile(company: item.company, changePercent: item.change, metric: metric, period: indexStore.effectivePeriod(selectedPeriod))
                        }
                        .favoriteContextMenu(ticker: item.company.ticker, name: item.company.name, indexId: indexStore.selectedId)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .themeScreen()
        .navigationBarHidden(true)
        .edgesIgnoringSafeArea(.bottom)
        .task(id: indexStore.selectedId) { await metrics.load(index: indexStore.selectedId) }
    }
}

struct CompanyTile: View {
    let company: Company
    let changePercent: Double?   // значение выбранного показателя (при «% change» — изменение)
    var metric: ColorMetric = .change
    var period: String? = nil

    var body: some View {
        TileContainer {
            VStack(spacing: 4) {
                Text(company.ticker)
                    .font(Theme.ui(.caption, weight: .medium))
                    .foregroundColor(HeatmapColor.tileText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let change = changePercent {
                    Text(metric.format(change))
                        .font(Theme.ui(.caption2))
                        .foregroundColor(HeatmapColor.tileText.opacity(0.9))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .padding(.horizontal, 2)
        }
        .background(metric.color(changePercent, period: period))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(1)
    }
}
