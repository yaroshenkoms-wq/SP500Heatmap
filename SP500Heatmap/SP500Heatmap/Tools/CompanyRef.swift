import SwiftUI

/// Lightweight reference to a company, used to open the company page from calendar and screener rows.
struct CompanyRef: Hashable, Identifiable {
    let ticker: String
    let name: String
    let index: String?
    var id: String { ticker }
}

extension View {
    /// Pushes the company page when `item` is set.
    func companyDestination(_ item: Binding<CompanyRef?>) -> some View {
        navigationDestination(item: item) { ref in
            CompanyDetailView(
                company: Company(ticker: ref.ticker, name: ref.name, marketCap: 0, description: nil, peRatio: nil, volume: nil),
                webSocketManager: WebSocketManager.shared)
        }
    }
}

/// Switches the shared index to the company's index (price format, chart source), as the watchlist does.
@MainActor func prepareCompany(_ ref: CompanyRef, store: IndexStore) {
    if let idx = ref.index, store.indices.contains(where: { $0.id == idx }) { store.selectedId = idx }
}
