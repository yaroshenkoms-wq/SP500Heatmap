import Foundation

struct StockListItem: Identifiable {
    let id = UUID()
    let symbol: String
    let name: String
    let marketCap: Double
    let price: Double
    let changePercent: Double
}
