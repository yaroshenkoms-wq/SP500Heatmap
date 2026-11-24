import SwiftUI

extension PerformanceMetrics {
    /// Доходности по ключам периодов, как в PeriodSwitchView.
    var changesByPeriod: [String: Double] {
        var result: [String: Double] = [:]
        for (key, value) in [("1d", day1), ("3d", day3), ("7d", day7), ("30d", day30), ("180d", day180), ("1y", year1)] {
            if let value { result[key] = value }
        }
        return result
    }
}

/// Цена и изменения избранных бумаг: по одному запросу доходностей на индекс, цена — последнее закрытие.
@MainActor
final class FavoritesQuotesStore: ObservableObject {
    struct Quote {
        var price: Double?
        var currency: String?
        var changes: [String: Double]
    }

    @Published private(set) var quotes: [String: Quote] = [:]
    @Published private(set) var isLoading = false

    func load(items: [FavoriteItem], currencies: [String: String]) async {
        guard !items.isEmpty else { quotes = [:]; return }
        isLoading = true
        defer { isLoading = false }

        var result: [String: Quote] = [:]
        let byIndex = Dictionary(grouping: items, by: \.indexId)
        for (indexId, group) in byIndex {
            let metrics = (try? await NetworkService.shared.fetchPerformance(index: indexId == "sp500" ? nil : indexId)) ?? [:]
            for item in group {
                result[item.ticker] = Quote(price: nil, currency: currencies[indexId],
                                            changes: metrics[item.ticker]?.changesByPeriod ?? [:])
            }
        }
        quotes = result

        await withTaskGroup(of: (String, Double?).self) { taskGroup in
            for item in items {
                taskGroup.addTask {
                    let history = try? await NetworkService.shared.fetchHistory(ticker: item.ticker)
                    return (item.ticker, history?.last?.close)
                }
            }
            for await (ticker, price) in taskGroup {
                quotes[ticker]?.price = price
            }
        }
        publishToWidget(items: items)
    }

    private func publishToWidget(items: [FavoriteItem]) {
        let favs = items.compactMap { item -> WidgetSnapshot.Fav? in
            guard let quote = quotes[item.ticker] else { return nil }
            return WidgetSnapshot.Fav(ticker: item.ticker, name: item.name, indexId: item.indexId,
                                      price: quote.price, currency: quote.currency, changes: quote.changes)
        }
        WidgetBridge.publish(favorites: favs)
    }
}

func formatPrice(_ value: Double, currency: String?) -> String {
    let code = currency ?? "USD"
    if code == "USD" { return "$" + formatDecimal(value) }
    return value.formatted(.currency(code: code).locale(AppLanguage.locale))
}

struct FavoritesView: View {
    @ObservedObject private var favorites = FavoritesStore.shared
    @StateObject private var quotesStore = FavoritesQuotesStore()
    @ObservedObject private var webSocket = WebSocketManager.shared
    @EnvironmentObject private var indexStore: IndexStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("worldPeriod") private var period = "1d"
    @State private var openItem: FavoriteItem?
    private let periods = ["1d", "3d", "7d", "30d", "180d", "1y"]

    private var currencies: [String: String] {
        Dictionary(indexStore.indices.compactMap { index in index.currency.map { (index.id, $0) } },
                   uniquingKeysWith: { first, _ in first })
    }

    private func change(_ item: FavoriteItem) -> Double? {
        quotesStore.quotes[item.ticker]?.changes[period]
    }

    private func price(_ item: FavoriteItem) -> Double? {
        if item.indexId == "sp500", let live = webSocket.priceUpdates[item.ticker]?.price, live > 0 { return live }
        return quotesStore.quotes[item.ticker]?.price
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
                        .font(Theme.ui(.subheadline, weight: .medium))
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .outlinedControl()
                    }
                    .buttonStyle(.plain)
                    HomeButton()
                    Spacer()
                    Text("Favorites")
                        .font(Theme.serif(.title))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                .padding(.horizontal)
                PeriodSwitchView(selectedPeriod: $period, availablePeriods: periods)
            }
            .padding(.top, 8)
            .background(Theme.bg)

            if favorites.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "star")
                        .font(.largeTitle)
                        .foregroundColor(Theme.gold)
                    Text("No favorites yet")
                        .font(Theme.serif(.title2))
                        .foregroundColor(Theme.text)
                    Text("Open a company and tap the star, or long-press a tile.")
                        .font(Theme.ui(.footnote))
                        .foregroundColor(Theme.muted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    if favorites.items.count >= 3 {
                        TreemapLayout(weights: favorites.items.map { _ in 1.0 }) {
                            ForEach(favorites.items) { item in
                                FavoriteTile(item: item, change: change(item))
                            }
                        }
                        .frame(height: 190)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(favorites.items) { item in
                            Button {
                                indexStore.selectedId = item.indexId
                                openItem = item
                            } label: {
                                FavoriteRow(item: item, price: price(item),
                                            currency: quotesStore.quotes[item.ticker]?.currency ?? currencies[item.indexId],
                                            change: change(item))
                            }
                            .buttonStyle(.plain)
                            .favoriteContextMenu(ticker: item.ticker, name: item.name, indexId: item.indexId)
                            Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 16)
                        }
                    }
                    .padding(.top, 8)
                    Text("Prices are the last close; the S&P 500 may show live prices.")
                        .font(Theme.ui(.caption2))
                        .foregroundColor(Theme.muted)
                        .padding()
                }
            }
        }
        .themeScreen()
        .navigationBarHidden(true)
        .navigationDestination(item: $openItem) { item in
            CompanyDetailView(
                company: Company(ticker: item.ticker, name: item.name, marketCap: 0,
                                 description: nil, peRatio: nil, volume: nil),
                webSocketManager: WebSocketManager.shared)
        }
        .task(id: favorites.items.map(\.ticker)) {
            await quotesStore.load(items: favorites.items, currencies: currencies)
        }
    }
}

private struct FavoriteTile: View {
    let item: FavoriteItem
    let change: Double?

    var body: some View {
        TileContainer {
            VStack(spacing: 2) {
                Text(verbatim: item.ticker)
                    .font(Theme.ui(.subheadline, weight: .semibold))
                    .foregroundColor(HeatmapColor.tileText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let change {
                    Text(formatPercent(change))
                        .font(Theme.ui(.caption))
                        .foregroundColor(HeatmapColor.tileText.opacity(0.9))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .padding(.horizontal, 3)
        }
        .background(HeatmapColor.color(for: change))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(1)
    }
}

private struct FavoriteRow: View {
    let item: FavoriteItem
    let price: Double?
    let currency: String?
    let change: Double?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.ticker)
                    .font(Theme.ui(.body, weight: .semibold))
                    .foregroundColor(Theme.text)
                Text(verbatim: item.name)
                    .font(Theme.ui(.caption))
                    .foregroundColor(Theme.muted)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: price.map { formatPrice($0, currency: currency) } ?? "—")
                    .font(Theme.ui(.subheadline, weight: .medium))
                    .foregroundColor(Theme.text)
                if let change {
                    Text(formatPercent(change))
                        .font(Theme.ui(.caption))
                        .foregroundColor(Theme.changeColor(change))
                } else {
                    Text(verbatim: "—")
                        .font(Theme.ui(.caption))
                        .foregroundColor(Theme.muted)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
