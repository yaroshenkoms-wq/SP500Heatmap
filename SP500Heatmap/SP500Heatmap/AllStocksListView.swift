import SwiftUI

struct AllStocksListView: View {
    let sectors: [Sector]
    @ObservedObject var webSocketManager: WebSocketManager
    @State private var selectedTab = "Overview"
    @State private var sortColumn = "Market Cap"
    @State private var sortAscending = false
    @State private var performance: [String: PerformanceMetrics] = [:]

    var allCompanies: [Company] {
        sectors.flatMap { $0.subsectors.flatMap { $0.companies } }
    }

    var overviewData: [OverviewRow] {
        allCompanies.map { company in
            let price = webSocketManager.priceUpdates[company.ticker]?.price ?? 0
            let change = webSocketManager.priceUpdates[company.ticker]?.changePercent ?? 0
            return OverviewRow(
                ticker: company.ticker,
                name: company.name,
                marketCap: company.marketCap,
                price: price,
                changePercent: change
            )
        }
    }

    var performanceData: [PerformanceRow] {
        allCompanies.map { company in
            let metrics = performance[company.ticker]
            return PerformanceRow(
                ticker: company.ticker,
                name: company.name,
                return1M: metrics?.return1M,
                return6M: metrics?.return6M,
                returnYTD: metrics?.returnYTD,
                return1Y: metrics?.return1Y
            )
        }
    }

    private func loadPerformance() async {
        do {
            performance = try await NetworkService.shared.fetchPerformance()
        } catch {
            print("Failed to load performance: \(error)")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Вкладки
            HStack {
                Button("Overview") { selectedTab = "Overview" }
                    .font(.headline)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(selectedTab == "Overview" ? Color.blue.opacity(0.2) : Color.clear)
                    .cornerRadius(8)
                Button("Performance") { selectedTab = "Performance" }
                    .font(.headline)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(selectedTab == "Performance" ? Color.blue.opacity(0.2) : Color.clear)
                    .cornerRadius(8)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 4)
            
            if selectedTab == "Overview" {
                OverviewTableView(rows: overviewData, sortColumn: $sortColumn, sortAscending: $sortAscending)
            } else {
                PerformanceTableView(rows: performanceData, sortColumn: $sortColumn, sortAscending: $sortAscending)
            }
        }
        .navigationTitle("All Stocks")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadPerformance()
        }
    }
}

// MARK: - Модели данных
struct OverviewRow: Identifiable {
    let id = UUID()
    let ticker: String
    let name: String
    let marketCap: Double
    let price: Double
    let changePercent: Double
}

struct PerformanceRow: Identifiable {
    let id = UUID()
    let ticker: String
    let name: String
    let return1M: Double?
    let return6M: Double?
    let returnYTD: Double?
    let return1Y: Double?
}

// MARK: - Overview Table
struct OverviewTableView: View {
    let rows: [OverviewRow]
    @Binding var sortColumn: String
    @Binding var sortAscending: Bool
    
    var sortedRows: [OverviewRow] {
        rows.sorted { a, b in
            switch sortColumn {
            case "Symbol":
                return sortAscending ? a.ticker < b.ticker : a.ticker > b.ticker
            case "Company Name":
                return sortAscending ? a.name < b.name : a.name > b.name
            case "Market Cap":
                return sortAscending ? a.marketCap < b.marketCap : a.marketCap > b.marketCap
            case "Stock Price":
                return sortAscending ? a.price < b.price : a.price > b.price
            case "% Change":
                return sortAscending ? a.changePercent < b.changePercent : a.changePercent > b.changePercent
            default:
                return sortAscending ? a.marketCap < b.marketCap : a.marketCap > b.marketCap
            }
        }
    }
    
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Заголовки
                HStack(spacing: 4) {
                    SortableHeader(title: "Symbol", column: "Symbol", sortColumn: $sortColumn, sortAscending: $sortAscending)
                        .frame(width: 60, alignment: .leading)
                    SortableHeader(title: "Company Name", column: "Company Name", sortColumn: $sortColumn, sortAscending: $sortAscending)
                        .frame(minWidth: 70, maxWidth: 80, alignment: .leading)
                    SortableHeader(title: "Market Cap", column: "Market Cap", sortColumn: $sortColumn, sortAscending: $sortAscending)
                        .frame(width: 75, alignment: .trailing)
                    SortableHeader(title: "Stock Price", column: "Stock Price", sortColumn: $sortColumn, sortAscending: $sortAscending)
                        .frame(width: 70, alignment: .trailing)
                    SortableHeader(title: "% Change", column: "% Change", sortColumn: $sortColumn, sortAscending: $sortAscending)
                        .frame(width: 65, alignment: .trailing)
                }
                .font(.caption.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 10)
                .background(Color.gray.opacity(0.2))
                
                // Строки
                ForEach(sortedRows) { row in
                    NavigationLink(destination: CompanyDetailView(
                        company: Company(
                            ticker: row.ticker,
                            name: row.name,
                            marketCap: row.marketCap,
                            description: nil,
                            peRatio: nil,
                            volume: nil
                        ),
                        webSocketManager: WebSocketManager.shared
                    )) {
                        HStack(spacing: 4) {
                            Text(row.ticker)
                                .font(.caption)
                                .frame(width: 60, alignment: .leading)
                            Text(row.name)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(minWidth: 70, maxWidth: 80, alignment: .leading)
                            Text(formatMarketCap(row.marketCap))
                                .font(.caption)
                                .frame(width: 75, alignment: .trailing)
                            Text(String(format: "$%.2f", row.price))
                                .font(.caption)
                                .frame(width: 70, alignment: .trailing)
                            Text(String(format: "%.2f%%", row.changePercent))
                                .font(.caption)
                                .foregroundColor(row.changePercent >= 0 ? .green : .red)
                                .frame(width: 65, alignment: .trailing)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(PlainButtonStyle())
                    Divider().padding(.leading, 6)
                }
            }
        }
    }
    
    private func formatMarketCap(_ value: Double) -> String {
        if value >= 1_000_000_000_000 {
            return String(format: "%.2fT", value / 1_000_000_000_000)
        } else if value >= 1_000_000_000 {
            return String(format: "%.2fB", value / 1_000_000_000)
        } else if value >= 1_000_000 {
            return String(format: "%.2fM", value / 1_000_000)
        } else {
            return String(format: "%.0f", value)
        }
    }
}

// MARK: - Performance Table
struct PerformanceTableView: View {
    let rows: [PerformanceRow]
    @Binding var sortColumn: String
    @Binding var sortAscending: Bool
    
    var sortedRows: [PerformanceRow] {
        rows.sorted { a, b in
            switch sortColumn {
            case "Symbol":
                return sortAscending ? a.ticker < b.ticker : a.ticker > b.ticker
            case "Company Name":
                return sortAscending ? a.name < b.name : a.name > b.name
            case "1M":
                return sortAscending ? (a.return1M ?? -.infinity) < (b.return1M ?? -.infinity) : (a.return1M ?? -.infinity) > (b.return1M ?? -.infinity)
            case "6M":
                return sortAscending ? (a.return6M ?? -.infinity) < (b.return6M ?? -.infinity) : (a.return6M ?? -.infinity) > (b.return6M ?? -.infinity)
            case "YTD":
                return sortAscending ? (a.returnYTD ?? -.infinity) < (b.returnYTD ?? -.infinity) : (a.returnYTD ?? -.infinity) > (b.returnYTD ?? -.infinity)
            case "1Y":
                return sortAscending ? (a.return1Y ?? -.infinity) < (b.return1Y ?? -.infinity) : (a.return1Y ?? -.infinity) > (b.return1Y ?? -.infinity)
            default:
                return sortAscending ? a.ticker < b.ticker : a.ticker > b.ticker
            }
        }
    }
    
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Заголовки
                HStack(spacing: 4) {
                    SortableHeader(title: "Symbol", column: "Symbol", sortColumn: $sortColumn, sortAscending: $sortAscending)
                        .frame(width: 60, alignment: .leading)
                    SortableHeader(title: "Company Name", column: "Company Name", sortColumn: $sortColumn, sortAscending: $sortAscending)
                        .frame(minWidth: 70, maxWidth: 80, alignment: .leading)
                    SortableHeader(title: "1M", column: "1M", sortColumn: $sortColumn, sortAscending: $sortAscending)
                        .frame(width: 55, alignment: .trailing)
                    SortableHeader(title: "6M", column: "6M", sortColumn: $sortColumn, sortAscending: $sortAscending)
                        .frame(width: 55, alignment: .trailing)
                    SortableHeader(title: "YTD", column: "YTD", sortColumn: $sortColumn, sortAscending: $sortAscending)
                        .frame(width: 55, alignment: .trailing)
                    SortableHeader(title: "1Y", column: "1Y", sortColumn: $sortColumn, sortAscending: $sortAscending)
                        .frame(width: 55, alignment: .trailing)
                }
                .font(.caption.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 10)
                .background(Color.gray.opacity(0.2))
                
                // Строки
                ForEach(sortedRows) { row in
                    NavigationLink(destination: CompanyDetailView(
                        company: Company(
                            ticker: row.ticker,
                            name: row.name,
                            marketCap: 0,
                            description: nil,
                            peRatio: nil,
                            volume: nil
                        ),
                        webSocketManager: WebSocketManager.shared
                    )) {
                        HStack(spacing: 4) {
                            Text(row.ticker)
                                .font(.caption)
                                .frame(width: 60, alignment: .leading)
                            Text(row.name)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(minWidth: 70, maxWidth: 80, alignment: .leading)
                            PerformanceCell(value: row.return1M).frame(width: 55, alignment: .trailing)
                            PerformanceCell(value: row.return6M).frame(width: 55, alignment: .trailing)
                            PerformanceCell(value: row.returnYTD).frame(width: 55, alignment: .trailing)
                            PerformanceCell(value: row.return1Y).frame(width: 55, alignment: .trailing)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(PlainButtonStyle())
                    Divider().padding(.leading, 6)
                }
            }
        }
    }
}

// MARK: - Ячейка доходности
struct PerformanceCell: View {
    let value: Double?

    var body: some View {
        if let value {
            Text(String(format: "%.2f%%", value))
                .font(.caption)
                .foregroundColor(value >= 0 ? .green : .red)
        } else {
            Text("N/A")
                .font(.caption)
                .foregroundColor(.gray)
        }
    }
}

// MARK: - Сортируемый заголовок
struct SortableHeader: View {
    let title: String
    let column: String
    @Binding var sortColumn: String
    @Binding var sortAscending: Bool
    
    var body: some View {
        Button(action: {
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = true
            }
        }) {
            HStack(spacing: 4) {
                Text(title)
                if sortColumn == column {
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                        .font(.caption2)
                }
            }
            .foregroundColor(.primary)
        }
        .buttonStyle(PlainButtonStyle())
    }
}
