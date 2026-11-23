import SwiftUI

struct SectorsHeatmapView: View {
    let sectors: [Sector]
    @ObservedObject var webSocketManager: WebSocketManager
    @ObservedObject var performanceStore: PerformanceStore
    @State private var selectedPeriod = "SC"
    @State private var showIndexPicker = false
    @EnvironmentObject private var indexStore: IndexStore

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
            return SectorStat(name: sector.name, totalMarketCap: totalCap, changePercent: avgChange, sector: sector)
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
                    NavigationLink(destination: AllStocksListView(sectors: sectors, webSocketManager: webSocketManager)) {
                        Text(verbatim: indexStore.current.name)
                            .font(.largeTitle)
                            .bold()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .foregroundColor(.primary)
                    }
                    if indexStore.pickerAvailable {
                        Button {
                            showIndexPicker = true
                        } label: {
                            HStack(spacing: 4) {
                                Text(indexStore.current.flag)
                                Image(systemName: "chevron.down.circle.fill")
                                    .foregroundColor(.blue)
                            }
                        }
                        .accessibilityLabel(Text("Select index"))
                    }
                    Spacer()
                    Text(String(format: "%.2f%%", indexChange))
                        .font(.title2)
                        .foregroundColor(indexChange >= 0 ? .green : .red)
                }
                .padding(.horizontal)
                PeriodSwitchView(selectedPeriod: $selectedPeriod)
                ClosingPricesNote()
            }
            .padding(.top, 8)
            .background(Color(.systemBackground))
            
            GeometryReader { geometry in
                TreemapLayout(weights: sortedSectorStats.map { $0.totalMarketCap }) {
                    ForEach(sortedSectorStats) { stat in
                        NavigationLink(destination: SubsectorsHeatmapView(sector: stat.sector, webSocketManager: webSocketManager, performanceStore: performanceStore)) {
                            SectorTile(stat: stat)
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .navigationBarHidden(true)
        .edgesIgnoringSafeArea(.bottom)
        .sheet(isPresented: $showIndexPicker) {
            IndexPickerView(indexStore: indexStore)
                .presentationDetents([.medium, .large])
        }
    }
}

struct SectorStat: Identifiable {
    let id = UUID()
    let name: String
    let totalMarketCap: Double
    let changePercent: Double
    let sector: Sector
}

struct SectorTile: View {
    let stat: SectorStat

    var body: some View {
        VStack {
            Text(stat.name)
                .font(.headline)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            Text(String(format: "%.2f%%", stat.changePercent))
                .font(.caption)
                .foregroundColor(.white.opacity(0.9))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HeatmapColor.color(for: stat.changePercent))
        .cornerRadius(8)
        .padding(1)
    }
}
