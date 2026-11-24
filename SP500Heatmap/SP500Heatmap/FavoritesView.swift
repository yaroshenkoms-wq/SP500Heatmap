import SwiftUI

extension PerformanceMetrics {
    /// Доходности по ключам периодов, как в PeriodSwitchView.
    var changesByPeriod: [String: Double] {
        var result: [String: Double] = [:]
        for (key, value) in [("1d", day1), ("3d", day3), ("7d", day7), ("30d", day30), ("180d", day180), ("1y", year1), ("3y", year3), ("5y", year5), ("10y", year10)] {
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
        var cap: Double?
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
                                            changes: metrics[item.ticker]?.changesByPeriod ?? [:], cap: nil)
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

    /// Капитализации для сортировки «по капитализации»: один запрос иерархии на индекс.
    func loadCaps(items: [FavoriteItem]) async {
        for indexId in Set(items.map(\.indexId)) {
            guard let sectors = try? await NetworkService.shared.fetchMarketHierarchy(index: indexId == "sp500" ? nil : indexId) else { continue }
            let caps = Dictionary(sectors.flatMap { $0.subsectors.flatMap(\.companies) }.map { ($0.ticker, $0.marketCap) },
                                  uniquingKeysWith: { first, _ in first })
            for item in items where item.indexId == indexId { quotes[item.ticker]?.cap = caps[item.ticker] }
        }
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
    /// True when shown as the root of the Watchlists tab: no Back / Home buttons.
    var isRoot = false
    @ObservedObject private var favorites = FavoritesStore.shared
    @StateObject private var quotesStore = FavoritesQuotesStore()
    @ObservedObject private var webSocket = WebSocketManager.shared
    @EnvironmentObject private var indexStore: IndexStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("worldPeriod") private var period = "1d"
    @AppStorage("favSelectedList") private var selectedId = FavoriteList.defaultId
    @AppStorage("favViewMode") private var viewMode = "list"
    @State private var openItem: FavoriteItem?
    @State private var showManage = false
    @State private var showNew = false
    @State private var newName = ""
    @State private var noteItem: FavoriteItem?
    @State private var noteText = ""
    @State private var editMode: EditMode = .inactive
    private let periods = ["1d", "3d", "7d", "30d", "180d", "1y", "3y", "5y", "10y"]

    private var currencies: [String: String] {
        Dictionary(indexStore.indices.compactMap { index in index.currency.map { (index.id, $0) } },
                   uniquingKeysWith: { first, _ in first })
    }

    private var current: FavoriteList {
        favorites.list(selectedId) ?? favorites.list(FavoriteList.defaultId) ?? favorites.lists[0]
    }

    private func change(_ item: FavoriteItem) -> Double? {
        quotesStore.quotes[item.ticker]?.changes[period]
    }

    private func price(_ item: FavoriteItem) -> Double? {
        if item.indexId == "sp500", let live = webSocket.priceUpdates[item.ticker]?.price, live > 0 { return live }
        return quotesStore.quotes[item.ticker]?.price
    }

    /// Бумаги выбранного списка в выбранном порядке.
    private var shown: [FavoriteItem] {
        let items = favorites.items(in: current.id)
        switch current.sort {
        case .manual: return items
        case .change: return items.sorted { (change($0) ?? -.infinity) > (change($1) ?? -.infinity) }
        case .name: return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .cap: return items.sorted { (quotesStore.quotes[$0.ticker]?.cap ?? 0) > (quotesStore.quotes[$1.ticker]?.cap ?? 0) }
        }
    }

    var body: some View {
        let items = shown
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                HStack {
                    if !isRoot {
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
                    }
                    Spacer()
                    Text("Favorites")
                        .font(Theme.serif(.title))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                .padding(.horizontal)
                listChips
                PeriodSwitchView(selectedPeriod: $period, availablePeriods: periods)
                controlsRow(items)
            }
            .padding(.top, 8)
            .background(Theme.bg)

            if items.isEmpty {
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
            } else if viewMode == "map" {
                TreemapLayout(weights: items.map { _ in 1.0 }) {
                    ForEach(items) { item in
                        Button {
                            indexStore.selectedId = item.indexId
                            openItem = item
                        } label: {
                            FavoriteTile(item: item, change: change(item), period: period)
                        }
                        .buttonStyle(.plain)
                        .favoriteContextMenu(ticker: item.ticker, name: item.name, indexId: item.indexId)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            } else {
                rowsList(items)
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
        .task(id: favorites.allItems.map(\.ticker)) {
            await quotesStore.load(items: favorites.allItems, currencies: currencies)
            if current.sort == .cap { await quotesStore.loadCaps(items: favorites.allItems) }
        }
        .task(id: current.sort) {
            if current.sort == .cap { await quotesStore.loadCaps(items: favorites.allItems) }
        }
        .sheet(isPresented: $showManage) { ManageListsSheet() }
        .alert("New list", isPresented: $showNew) {
            TextField("List name", text: $newName)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Create") {
                let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { selectedId = favorites.createList(name: trimmed) }
                newName = ""
            }
        }
        .alert("Note", isPresented: Binding(get: { noteItem != nil }, set: { if !$0 { noteItem = nil } })) {
            TextField("Short note", text: $noteText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let noteItem { favorites.setNote(noteItem.ticker, in: current.id, note: noteText) }
            }
        }
    }

    // MARK: Части экрана

    private var listChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(favorites.lists) { list in
                    Button { selectedId = list.id; editMode = .inactive } label: {
                        Text(verbatim: list.name).lineLimit(1)
                            .themeChip(selected: list.id == current.id)
                    }
                    .buttonStyle(.plain)
                }
                Button { showNew = true } label: {
                    Image(systemName: "plus").themeChip(selected: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("New list"))
                Button { showManage = true } label: {
                    Image(systemName: "ellipsis").themeChip(selected: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Manage lists"))
            }
            .padding(.horizontal)
        }
    }

    private func controlsRow(_ items: [FavoriteItem]) -> some View {
        HStack(spacing: 8) {
            Menu {
                Picker(selection: Binding(get: { current.sort }, set: { favorites.setSort(current.id, $0); editMode = .inactive })) {
                    ForEach(FavSort.allCases) { sort in Text(sort.title).tag(sort) }
                } label: { Text("Sort by") }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 10, weight: .semibold))
                    Text(current.sort.title).lineLimit(1)
                }
                .themeChip(selected: current.sort != .manual)
            }
            .accessibilityLabel(Text("Sort by"))
            if current.sort == .manual, viewMode != "map", items.count > 1 {
                Button {
                    editMode = editMode == .active ? .inactive : .active
                } label: {
                    Text(editMode == .active ? "Done" : "Reorder")
                        .themeChip(selected: editMode == .active)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            HStack(spacing: 0) {
                modeButton("list.bullet", "list")
                modeButton("square.grid.2x2", "map")
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private func modeButton(_ symbol: String, _ mode: String) -> some View {
        Button { viewMode = mode; editMode = .inactive } label: {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundColor(viewMode == mode ? Theme.bg : Theme.gold)
                .frame(width: 38, height: 30)
                .background(viewMode == mode ? Theme.gold : Color.clear)
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.gold.opacity(0.5), lineWidth: 1))
        .accessibilityLabel(Text(LocalizedStringKey(mode == "map" ? "Map" : "List")))
    }

    private func rowsList(_ items: [FavoriteItem]) -> some View {
        List {
            ForEach(items) { item in
                Button {
                    indexStore.selectedId = item.indexId
                    openItem = item
                } label: {
                    FavoriteRow(item: item, price: price(item),
                                currency: quotesStore.quotes[item.ticker]?.currency ?? currencies[item.indexId],
                                change: change(item))
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Theme.bg)
                .listRowSeparatorTint(Theme.line)
                .contextMenu {
                    Button {
                        noteText = item.note
                        noteItem = item
                    } label: { Label("Note…", systemImage: "note.text") }
                    Menu {
                        FavoriteListMenuItems(ticker: item.ticker, name: item.name, indexId: item.indexId)
                    } label: { Label("Add to list", systemImage: "star") }
                    Button(role: .destructive) {
                        favorites.setMembership(ticker: item.ticker, name: item.name, indexId: item.indexId, list: current.id, on: false)
                    } label: { Label("Remove from this list", systemImage: "trash") }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        favorites.setMembership(ticker: item.ticker, name: item.name, indexId: item.indexId, list: current.id, on: false)
                    } label: { Label("Remove from this list", systemImage: "trash") }
                }
                .moveDisabled(current.sort != .manual)
            }
            .onMove { from, to in
                favorites.moveItems(in: current.id, shown: items, from: from, to: to)
            }
            Text("Prices are the last close; the S&P 500 may show live prices.")
                .font(Theme.ui(.caption2))
                .foregroundColor(Theme.muted)
                .listRowBackground(Theme.bg)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, $editMode)
    }
}

/// Управление списками: создать, переименовать, удалить, поменять порядок.
private struct ManageListsSheet: View {
    @ObservedObject private var favorites = FavoritesStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: FavoriteList?
    @State private var text = ""
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(favorites.lists) { list in
                    Button {
                        text = list.name
                        renaming = list
                    } label: {
                        HStack {
                            Text(verbatim: list.name)
                                .font(Theme.ui(.body))
                                .foregroundColor(Theme.text)
                            Spacer()
                            Text(verbatim: "\(favorites.items(in: list.id).count)")
                                .font(Theme.ui(.subheadline))
                                .foregroundColor(Theme.muted)
                        }
                    }
                    .deleteDisabled(list.id == FavoriteList.defaultId)
                    .listRowBackground(Theme.panel)
                }
                .onMove { favorites.moveLists(from: $0, to: $1) }
                .onDelete { offsets in
                    let lists = favorites.lists
                    for i in offsets { favorites.deleteList(lists[i].id) }
                }
                Button { text = ""; creating = true } label: {
                    Label("New list…", systemImage: "plus")
                        .foregroundColor(Theme.gold)
                }
                .listRowBackground(Theme.panel)
            }
            .scrollContentBackground(.hidden)
            .themeScreen()
            .environment(\.editMode, .constant(.active))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Manage lists").font(Theme.serif(.title3)).foregroundColor(Theme.text)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.font(Theme.ui(.body, weight: .medium))
                }
            }
            .themeNavBar()
            .alert("Rename list", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("List name", text: $text)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    if let renaming {
                        // Пустое имя у списка по умолчанию возвращает стандартное «Избранное».
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty || renaming.id == FavoriteList.defaultId {
                            favorites.renameList(renaming.id, to: trimmed)
                        }
                    }
                }
            }
            .alert("New list", isPresented: $creating) {
                TextField("List name", text: $text)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { favorites.createList(name: trimmed) }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct FavoriteTile: View {
    let item: FavoriteItem
    let change: Double?
    var period: String? = nil

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
        .background(HeatmapColor.color(for: change, period: period))
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
                if !item.note.isEmpty {
                    Text(verbatim: item.note)
                        .font(Theme.ui(.caption2))
                        .foregroundColor(Theme.gold)
                        .lineLimit(2)
                }
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
