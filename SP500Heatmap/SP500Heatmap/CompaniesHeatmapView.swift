import SwiftUI

struct CompaniesHeatmapView: View {
    let subsector: Subsector
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
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                        .foregroundColor(.blue)
                    }
                    Spacer()
                    Text(subsector.name)
                        .font(.largeTitle)
                        .bold()
                    Spacer()
                    Text(String(format: "%.2f%%", subsectorChange))
                        .font(.title2)
                        .foregroundColor(subsectorChange >= 0 ? .green : .red)
                }
                .padding(.horizontal)
                PeriodSwitchView(selectedPeriod: $selectedPeriod)
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
        VStack(spacing: 4) {
            Text(company.ticker)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let change = changePercent {
                Text(String(format: "%.2f%%", change))
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.9))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HeatmapColor.color(for: changePercent))
        .cornerRadius(6)
        .padding(1)
    }
}
