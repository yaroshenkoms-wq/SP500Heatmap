import SwiftUI

struct SearchView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    let sectors: [Sector]
    
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss
    
    var searchResults: [Company] {
        guard !searchText.isEmpty else { return [] }
        let allCompanies = sectors.flatMap { $0.subsectors.flatMap { $0.companies } }
        return allCompanies.filter { company in
            company.ticker.localizedCaseInsensitiveContains(searchText) ||
            company.name.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        NavigationStack {
            List(searchResults, id: \.ticker) { company in
                NavigationLink(destination: CompanyDetailView(company: company, webSocketManager: webSocketManager)) {
                    HStack {
                        Text(company.ticker)
                            .font(.headline)
                            .frame(width: 70, alignment: .leading)
                        Text(company.name)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        if let change = webSocketManager.priceUpdates[company.ticker]?.changePercent {
                            Text(String(format: "%.2f%%", change))
                                .font(.caption)
                                .foregroundColor(change >= 0 ? .green : .red)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Ticker or company name")
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}
