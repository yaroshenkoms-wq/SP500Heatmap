import SwiftUI

struct CompaniesHeatmapView: View {
    let subsector: Subsector
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

    var companiesWithChanges: [(company: Company, change: Double?)] {
        subsector.companies.map { company in
            (company, changePercent(for: company.ticker))
        }
    }

    // Пересчитывается от selectedPeriod вместо статичного значения с
    // родительского экрана, иначе заголовок не реагирует на смену периода.
    var subsectorChange: Double {
        var weightedChange = 0.0
        var totalWeight = 0.0
        for company in subsector.companies {
            if let change = changePercent(for: company.ticker) {
                weightedChange += change * company.marketCap
                totalWeight += company.marketCap
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
                        .foregroundColor(.blue)
                    }
                    HomeButton()
                    Spacer()
                    Text(verbatim: localizedSectorName(subsector.name))
                        .font(.largeTitle)
                        .bold()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Spacer()
                    Text(formatPercent(subsectorChange))
                        .font(.title2)
                        .foregroundColor(subsectorChange >= 0 ? .green : .red)
                }
                .padding(.horizontal)
                PeriodSwitchView(selectedPeriod: $selectedPeriod)
                ClosingPricesNote()
            }
            .padding(.top, 8)
            .background(Color(.systemBackground))
            
            GeometryReader { geometry in
                TreemapLayout(weights: sortedCompaniesWithChanges.map { $0.company.marketCap }) {
                    ForEach(sortedCompaniesWithChanges, id: \.company.ticker) { item in
                        NavigationLink(destination: CompanyDetailView(company: item.company, webSocketManager: webSocketManager)) {
                            CompanyTile(company: item.company, changePercent: item.change)
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

struct CompanyTile: View {
    let company: Company
    let changePercent: Double?

    var body: some View {
        TileContainer {
            VStack(spacing: 4) {
                Text(company.ticker)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let change = changePercent {
                    Text(formatPercent(change))
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .padding(.horizontal, 2)
        }
        .background(HeatmapColor.color(for: changePercent))
        .cornerRadius(6)
        .padding(1)
    }
}
