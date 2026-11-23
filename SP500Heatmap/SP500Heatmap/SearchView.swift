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
                            .font(Theme.ui(.headline, weight: .semibold))
                            .foregroundColor(Theme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(width: 80, alignment: .leading)
                        Text(company.name)
                            .font(Theme.ui(.caption))
                            .foregroundColor(Theme.muted)
                            .lineLimit(1)
                        Spacer()
                        if let change = webSocketManager.priceUpdates[company.ticker]?.changePercent {
                            Text(formatPercent(change))
                                .font(Theme.ui(.caption))
                                .foregroundColor(Theme.changeColor(change))
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Theme.panel)
                .listRowSeparatorTint(Theme.line)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Ticker or company name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Search")
                        .font(Theme.serif(.title3))
                        .foregroundColor(Theme.text)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .font(Theme.ui(.subheadline, weight: .medium))
                }
            }
            .themeNavBar()
        }
    }
}
