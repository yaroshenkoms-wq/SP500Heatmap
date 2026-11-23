import SwiftUI

struct SubsectorsHeatmapView: View {
    let sector: Sector
    @ObservedObject var webSocketManager: WebSocketManager
    @ObservedObject var performanceStore: PerformanceStore
    @State private var selectedPeriod = "SC"
    @EnvironmentObject private var indexStore: IndexStore
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

    // Пересчитывается от selectedPeriod, а не приходит статичным значением с
    // родительского экрана - иначе заголовок "застывает" на периоде, который
    // был выбран в момент перехода сюда.
    var sectorChange: Double {
        let companies = sector.subsectors.flatMap { $0.companies }
        var weightedChange = 0.0
        var totalWeight = 0.0
        for company in companies {
            if let change = changePercent(for: company.ticker) {
                weightedChange += change * company.marketCap
                totalWeight += company.marketCap
            }
        }
        return totalWeight > 0 ? weightedChange / totalWeight : 0
    }

    var subsectorStats: [SubsectorStat] {
        sector.subsectors.map { subsector in
            let companies = subsector.companies
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
            return SubsectorStat(name: subsector.name, totalMarketCap: totalCap, changePercent: avgChange, subsector: subsector)
        }
    }
    
    // Сортировка по убыванию капитализации
    var sortedSubsectorStats: [SubsectorStat] {
        subsectorStats.sorted { $0.totalMarketCap > $1.totalMarketCap }
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
                    Text(verbatim: localizedSectorName(sector.name))
                        .font(Theme.serif(.title))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Spacer()
                    Text(formatPercent(sectorChange))
                        .font(Theme.ui(.title2, weight: .medium))
                        .foregroundColor(Theme.changeColor(sectorChange))
                }
                .padding(.horizontal)
                PeriodSwitchView(selectedPeriod: $selectedPeriod)
                ClosingPricesNote()
            }
            .padding(.top, 8)
            .background(Theme.bg)
            
            GeometryReader { geometry in
                TreemapLayout(weights: sortedSubsectorStats.map { $0.totalMarketCap }) {
                    ForEach(sortedSubsectorStats) { stat in
                        NavigationLink(destination: CompaniesHeatmapView(subsector: stat.subsector, webSocketManager: webSocketManager, performanceStore: performanceStore)) {
                            SubsectorTile(stat: stat)
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .themeScreen()
        .navigationBarHidden(true)
        .edgesIgnoringSafeArea(.bottom)
    }
}

struct SubsectorStat: Identifiable {
    let id = UUID()
    let name: String
    let totalMarketCap: Double
    let changePercent: Double
    let subsector: Subsector
}

struct SubsectorTile: View {
    let stat: SubsectorStat

    var body: some View {
        TileContainer {
            VStack {
                Text(verbatim: localizedSectorName(stat.name))
                    .font(Theme.ui(.headline, weight: .semibold))
                    .foregroundColor(HeatmapColor.tileText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                Text(formatPercent(stat.changePercent))
                    .font(Theme.ui(.caption))
                    .foregroundColor(HeatmapColor.tileText.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(.horizontal, 3)
        }
        .background(HeatmapColor.color(for: stat.changePercent))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(1)
    }
}
