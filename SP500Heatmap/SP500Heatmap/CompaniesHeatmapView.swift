import SwiftUI

struct CompaniesHeatmapView: View {
    let subsector: Subsector
    let subsectorChange: Double
    @ObservedObject var webSocketManager: WebSocketManager
    @State private var selectedPeriod = "SC"
    @Environment(\.dismiss) private var dismiss
    
    var companiesWithChanges: [(company: Company, change: Double?)] {
        subsector.companies.map { company in
            let change = webSocketManager.priceUpdates[company.ticker]?.changePercent
            return (company, change)
        }
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
    
    var tileColor: Color {
        guard let change = changePercent else { return Color.gray }
        if change > 3.0 { return .green }
        if change > 0.5 { return Color(red: 0.55, green: 0.76, blue: 0.29) }
        if change < -3.0 { return .red }
        if change < -0.5 { return Color(red: 1.0, green: 0.54, blue: 0.40) }
        return .gray
    }
    
    var body: some View {
        VStack(spacing: 4) {
            Text(company.ticker)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let change = changePercent {
                Text(String(format: "%.2f%%", change))
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.9))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tileColor)
        .cornerRadius(6)
        .padding(1)
    }
}
