import SwiftUI
import WidgetKit

@main
struct SP500HeatmapWidgetsBundle: WidgetBundle {
    var body: some Widget {
        WorldMarketsWidget()
        FavoritesWidget()
        IndexLockScreenWidget()
        OpenAppControl()
        OpenIndexControl()
    }
}

// MARK: Мировые рынки

struct WorldMarketsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "WorldMarketsWidget", intent: SelectRegionIntent.self, provider: WorldProvider()) { entry in
            WorldMarketsView(entry: entry)
                .environment(\.locale, WTheme.locale)
                .containerBackground(WTheme.bg, for: .widget)
        }
        .configurationDisplayName("World markets")
        .description("A map of regions and indices coloured by today's change.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct WorldMarketsView: View {
    let entry: MarketEntry

    var body: some View {
        let regions = (entry.snapshot?.drawableRegions ?? []).filter { entry.region == "all" || $0.id == entry.region }
        if !regions.isEmpty {
            VStack(spacing: 0) {
                HStack {
                    Text("World markets")
                        .font(.system(.footnote, design: .serif).weight(.semibold))
                        .foregroundColor(WTheme.text)
                    Spacer()
                    Text("1d")
                        .font(.caption2)
                        .foregroundColor(WTheme.gold)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                TreemapLayout(weights: regions.map { $0.totalCap }) {
                    ForEach(regions) { region in
                        TreemapLayout(weights: region.drawable.map { $0.capUSD ?? 0 }) {
                            ForEach(region.drawable) { index in
                                WorldTile(index: index)
                            }
                        }
                        .padding(1.5)
                    }
                }
                .padding(.horizontal, 3)
                .padding(.bottom, 3)
            }
        } else {
            EmptyHint(symbol: "chart.bar.xaxis", text: "Open the app to load the markets.")
        }
    }
}

private struct WorldTile: View {
    let index: WidgetSnapshot.Idx
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        let change = index.changes["1d"]
        GeometryReader { geo in
            ZStack {
                WTheme.tileFill(change, mode: mode)
                if geo.size.width >= 46 && geo.size.height >= 26 {
                    VStack(spacing: 1) {
                        Text(verbatim: index.name)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        if let change {
                            Text(verbatim: WTheme.arrow(change, mode) + WTheme.percent(change))
                                .font(.system(size: 9))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .opacity(0.9)
                        }
                    }
                    .foregroundColor(WTheme.text)
                    .padding(.horizontal, 2)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .padding(0.5)
    }
}

// MARK: Избранное

struct FavoritesWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "FavoritesWidget", intent: SelectListIntent.self, provider: FavoritesProvider()) { entry in
            FavoritesView(entry: entry)
                .environment(\.locale, WTheme.locale)
                .containerBackground(WTheme.bg, for: .widget)
        }
        .configurationDisplayName("My favorites")
        .description("Your favorite stocks with today's change.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct FavoritesView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.showsWidgetContainerBackground) private var showsBackground
    let entry: MarketEntry

    /// Бумаги выбранного списка в его порядке (старый снимок без списков — все бумаги).
    private var favorites: [WidgetSnapshot.Fav] {
        let all = entry.snapshot?.favorites ?? []
        guard let lists = entry.snapshot?.favLists, !lists.isEmpty else { return all }
        let list = lists.first { $0.id == entry.listId } ?? lists.first { $0.id == "default" } ?? lists[0]
        let byTicker = Dictionary(all.map { ($0.ticker, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = list.tickers.compactMap { byTicker[$0] }
        switch list.sort {
        case "change": return ordered.sorted { ($0.changes["1d"] ?? -.infinity) > ($1.changes["1d"] ?? -.infinity) }
        case "name": return ordered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        default: return ordered
        }
    }

    private var listName: String? {
        (entry.snapshot?.favLists ?? []).first { $0.id == entry.listId }?.name
    }

    var body: some View {
        let favorites = favorites
        if favorites.isEmpty {
            EmptyHint(symbol: "star", text: "Add favorites in the app: tap the star on a company.")
        } else {
            let columns = family == .systemSmall ? 2 : 4
            let limit = columns * 2
            let shown = Array(favorites.prefix(limit))
            VStack(spacing: 4) {
                HStack {
                    Group {
                        if let listName { Text(verbatim: listName) } else { Text("My favorites") }
                    }
                        .font(.system(.caption, design: .serif).weight(.semibold))
                        .foregroundColor(WTheme.text)
                        .lineLimit(1)
                    Spacer()
                    Text("1d")
                        .font(.caption2)
                        .foregroundColor(WTheme.gold)
                }
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(0..<columns, id: \.self) { col in
                            let i = row * columns + col
                            if i < shown.count {
                                FavCell(fav: shown[i], large: !showsBackground)
                            } else {
                                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct FavCell: View {
    let fav: WidgetSnapshot.Fav
    /// StandBy: виджет без своей подложки и крупнее — шрифт больше.
    var large = false
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        let change = fav.changes["1d"]
        VStack(spacing: 1) {
            Text(verbatim: fav.ticker)
                .font(.system(size: large ? 15 : 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let change {
                Text(verbatim: WTheme.arrow(change, mode) + WTheme.percent(change))
                    .font(.system(size: large ? 13 : 10, weight: large ? .medium : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .opacity(0.95)
            }
        }
        .foregroundColor(WTheme.text)
        .widgetAccentable()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WTheme.tileFill(change, mode: mode))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: Экран блокировки

struct IndexLockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "IndexLockScreenWidget", intent: SelectIndexIntent.self, provider: IndexProvider()) { entry in
            IndexLockView(entry: entry)
                .environment(\.locale, WTheme.locale)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Index on Lock Screen")
        .description("Today's change of the index you choose (S&P 500 by default).")
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
}

struct IndexLockView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MarketEntry

    private var index: WidgetSnapshot.Idx? {
        entry.snapshot?.allIndices.first { $0.id == entry.indexId }
    }

    var body: some View {
        let change = index?.changes["1d"]
        let name = index?.name ?? "S&P 500"
        let arrow = (change ?? 0) >= 0 ? "arrow.up.right" : "arrow.down.right"
        switch family {
        case .accessoryInline:
            if let change {
                Label(title: { Text(verbatim: "\(name) \(WTheme.percent(change))") },
                      icon: { Image(systemName: arrow) })
            } else {
                Text(verbatim: name)
            }
        default:
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(verbatim: name)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer()
                    Image(systemName: arrow)
                }
                Text(verbatim: change.map { WTheme.percent($0) } ?? "—")
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("1d")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Пустое состояние

private struct EmptyHint: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundColor(WTheme.gold)
            Text(text)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(WTheme.muted)
        }
        .padding(8)
    }
}
