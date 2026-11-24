import SwiftUI

struct SectorsHeatmapView: View {
    let sectors: [Sector]
    @ObservedObject var webSocketManager: WebSocketManager
    @ObservedObject var performanceStore: PerformanceStore
    @State private var selectedPeriod = "SC"
    @State private var showIndexPicker = false
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

    private func changePercent(for ticker: String) -> Double? {
        let period = indexStore.effectivePeriod(selectedPeriod)
        if period == "SC" {
            // Нет живой цены (например, ASML в Nasdaq-100 вне подписки Finnhub) — берём изменение за день.
            return webSocketManager.priceUpdates[ticker]?.changePercent
                ?? performanceStore.changePercent(for: ticker, period: "1d")
        }
        return performanceStore.changePercent(for: ticker, period: period)
    }

    var indexChange: Double {
        let allCompanies = sectors.flatMap { $0.subsectors.flatMap { $0.companies } }
        var weightedChange = 0.0
        var totalWeight = 0.0
        for company in allCompanies {
            if let change = changePercent(for: company.ticker) {
                weightedChange += change * company.marketCap
                totalWeight += company.marketCap
            }
        }
        return totalWeight > 0 ? weightedChange / totalWeight : 0
    }

    var sectorStats: [SectorStat] {
        sectors.map { sector in
            let companies = sector.subsectors.flatMap { $0.companies }
            let totalCap = companies.reduce(0) { $0 + $1.marketCap }
            var weightedChange = 0.0
            var totalWeight = 0.0
            for company in companies {
                if let change = changePercent(for: company.ticker) {
                    weightedChange += change * company.marketCap
                    totalWeight += company.marketCap
                }
            }
            let avgChange = totalWeight > 0 ? weightedChange / totalWeight : 0
            let value = metric == .change ? avgChange
                : metrics.aggregate(metric, companies: companies, index: indexStore.selectedId)
            return SectorStat(name: sector.name, totalMarketCap: totalCap, changePercent: value, sector: sector)
        }
    }
    
    // Сортировка по убыванию капитализации
    var sortedSectorStats: [SectorStat] {
        sectorStats.sorted { $0.totalMarketCap > $1.totalMarketCap }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                HStack {
                    HomeButton()
                    if indexStore.pickerAvailable {
                        // Pop-up-button look: name + flag + up/down chevrons in a capsule.
                        Button {
                            showIndexPicker = true
                        } label: {
                            HStack(spacing: 6) {
                                Text(indexStore.current.flag)
                                Text(verbatim: indexStore.current.name)
                                    .font(Theme.serif(.title2))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                    .foregroundColor(Theme.text)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(Theme.gold)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .outlinedControl()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Select index"))
                        NavigationLink(destination: AllStocksListView(sectors: sectors, webSocketManager: webSocketManager)) {
                            Image(systemName: "list.bullet")
                                .font(.subheadline)
                                .frame(width: 34, height: 34)
                                .outlinedControl()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("All Stocks"))
                    } else {
                        NavigationLink(destination: AllStocksListView(sectors: sectors, webSocketManager: webSocketManager)) {
                            Text(verbatim: indexStore.current.name)
                                .font(Theme.serif(.largeTitle))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .foregroundColor(Theme.text)
                        }
                    }
                    Spacer()
                    ShareMapButton(title: indexStore.current.name,
                                   subtitle: shareSubtitle(period: indexStore.effectivePeriod(selectedPeriod),
                                                           asOf: indexStore.current.historyThrough)) {
                        TreemapLayout(weights: sortedSectorStats.map { SizeMode.weight($0.totalMarketCap) }) {
                            ForEach(sortedSectorStats) { stat in SectorTile(stat: stat, metric: metric, period: indexStore.effectivePeriod(selectedPeriod)) }
                        }
                    }
                    Text(formatPercent(indexChange))
                        .font(Theme.ui(.title2, weight: .medium))
                        .foregroundColor(Theme.changeColor(indexChange))
                }
                .padding(.horizontal)
                MetricPeriodRow(period: $selectedPeriod, metric: metricBinding, options: metricOptions)
                MetricLegend(metric: metric)
                ClosingPricesNote()
            }
            .padding(.top, 8)
            .background(Theme.bg)
            
            GeometryReader { geometry in
                TreemapLayout(weights: sortedSectorStats.map { SizeMode.weight($0.totalMarketCap) }) {
                    ForEach(sortedSectorStats) { stat in
                        NavigationLink(destination: SubsectorsHeatmapView(sector: stat.sector, webSocketManager: webSocketManager, performanceStore: performanceStore)) {
                            SectorTile(stat: stat, metric: metric, period: indexStore.effectivePeriod(selectedPeriod))
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .themeScreen()
        .navigationBarHidden(true)
        .edgesIgnoringSafeArea(.bottom)
        .task(id: indexStore.selectedId) { await metrics.load(index: indexStore.selectedId) }
        .sheet(isPresented: $showIndexPicker) {
            IndexPickerView(indexStore: indexStore)
                .presentationDetents([.medium, .large])
                .presentationSizing(.form)
        }
    }
}

struct SectorStat: Identifiable {
    let id = UUID()
    let name: String
    let totalMarketCap: Double
    let changePercent: Double?   // значение выбранного показателя (при «% change» — изменение)
    let sector: Sector
}

struct SectorTile: View {
    let stat: SectorStat
    var metric: ColorMetric = .change
    var period: String? = nil

    var body: some View {
        TileContainer {
            VStack {
                Text(verbatim: localizedSectorName(stat.name))
                    .font(Theme.ui(.headline, weight: .semibold))
                    .foregroundColor(HeatmapColor.tileText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                if let value = stat.changePercent {
                    Text(metric.format(value))
                        .font(Theme.ui(.caption))
                        .foregroundColor(HeatmapColor.tileText.opacity(0.9))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .padding(.horizontal, 3)
        }
        .background(metric.color(stat.changePercent, period: period))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(1)
    }
}
