import SwiftUI

struct SubsectorsHeatmapView: View {
    let sector: Sector
    @ObservedObject var webSocketManager: WebSocketManager
    @ObservedObject var performanceStore: PerformanceStore
    @State private var selectedPeriod = "SC"
    @Environment(\.dismiss) private var dismiss

    private func changePercent(for ticker: String) -> Double? {
        if selectedPeriod == "SC" {
            return webSocketManager.priceUpdates[ticker]?.changePercent
        }
        return performanceStore.changePercent(for: ticker, period: selectedPeriod)
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
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                        .foregroundColor(.blue)
                    }
                    Spacer()
                    Text(sector.name)
                        .font(.largeTitle)
                        .bold()
                    Spacer()
                    Text(String(format: "%.2f%%", sectorChange))
                        .font(.title2)
                        .foregroundColor(sectorChange >= 0 ? .green : .red)
                }
                .padding(.horizontal)
                PeriodSwitchView(selectedPeriod: $selectedPeriod)
            }
            .padding(.top, 8)
            .background(Color(.systemBackground))
            
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
