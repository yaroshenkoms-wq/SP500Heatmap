import SwiftUI

/// Списки избранного (из iCloud или с iPhone) → бумаги → карточка компании.
struct WatchlistsView: View {
    @EnvironmentObject private var store: WatchListsStore

    var body: some View {
        List {
            if store.lists.allSatisfy({ $0.items.isEmpty }) {
                Text("Your lists are empty. Add stocks in the iPhone app.")
                    .font(.footnote).foregroundStyle(WTheme.muted)
            }
            ForEach(store.lists) { list in
                NavigationLink {
                    WatchlistView(list: list)
                } label: {
                    HStack {
                        Text(verbatim: list.name).foregroundStyle(WTheme.text)
                        Spacer()
                        Text(verbatim: "\(list.items.count)").font(.caption).foregroundStyle(WTheme.gold)
                    }
                }
            }
        }
        .navigationTitle(Text("Watchlists"))
        .onAppear { store.refresh() }
    }
}

struct WatchlistView: View {
    let list: WList
    @EnvironmentObject private var world: WatchWorldStore
    @AppStorage("watchPeriod") private var period = "1d"
    @State private var perf: [String: [String: [String: Double?]]] = [:]   // индекс → тикер → период → %

    var body: some View {
        List {
            ForEach(list.items) { item in
                let change = perf[item.indexId]?[item.ticker]?[period] ?? nil
                NavigationLink {
                    CompanyView(ticker: item.ticker, name: item.name, currency: world.currency(forIndex: item.indexId))
                } label: {
                    HStack(spacing: 8) {
                        ChangeBar(change: change, period: period)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: item.ticker).font(.footnote.weight(.semibold)).foregroundStyle(WTheme.text)
                            Text(verbatim: item.name).font(.caption2).foregroundStyle(WTheme.muted).lineLimit(1)
                        }
                        Spacer()
                        Text(verbatim: WTheme.pct(change)).font(.footnote.weight(.semibold))
                            .foregroundStyle(WTheme.textColor(change))
                    }
                }
            }
        }
        .navigationTitle(Text(verbatim: list.name))
        .toolbar { ToolbarItem(placement: .topBarTrailing) { PeriodMenu() } }
        .task {
            for indexId in Set(list.items.map(\.indexId)) {
                if let p = try? await WatchAPI.performance(index: indexId) { perf[indexId] = p }
            }
        }
    }
}
