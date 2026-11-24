import SwiftUI

// GET /api/v1/world-overview
struct WorldOverview: Decodable {
    let asOf: String?
    let regions: [WorldRegion]
}

struct WorldRegion: Decodable, Identifiable {
    let id: String
    let indices: [WorldIndex]

    // Indices that can be drawn (capUSD known), biggest first.
    var drawable: [WorldIndex] {
        indices.filter { ($0.capUSD ?? 0) > 0 }.sorted { ($0.capUSD ?? 0) > ($1.capUSD ?? 0) }
    }
    var totalCap: Double { drawable.reduce(0) { $0 + ($1.capUSD ?? 0) } }

    var title: LocalizedStringKey {
        switch id {
        case "americas": return "Americas"
        case "europe": return "Europe"
        case "asia_pacific": return "Asia-Pacific"
        case "assets": return "Crypto & ETFs"
        default: return "Other"
        }
    }
}

struct WorldIndex: Decodable, Identifiable {
    let id: String
    let name: String
    let country: String?
    let capUSD: Double?
    let changes: [String: Double?]?

    func change(for period: String) -> Double? {
        guard let value = changes?[period] else { return nil }
        return value
    }

    var flag: String { countryFlag(country) }
}

@MainActor
final class WorldStore: ObservableObject {
    static let shared = WorldStore()

    @Published private(set) var overview: WorldOverview?
    @Published private(set) var didFinishFirstLoad = false

    var regions: [WorldRegion] {
        guard let overview else { return [] }
        return overview.regions
            .filter { !$0.drawable.isEmpty }
            .sorted { $0.totalCap > $1.totalCap }
    }

    // On failure keeps previously loaded data; with none the app falls back to the S&P 500 map.
    func load() async {
        do {
            let fetched = try await NetworkService.shared.fetchWorldOverview()
            overview = fetched.regions.contains { !$0.drawable.isEmpty } ? fetched : nil
            if let overview { WidgetBridge.publish(overview: overview) }
        } catch is CancellationError {
            return
        } catch {
            // keep old value
        }
        didFinishFirstLoad = true
    }
}

// Home screen: one treemap of all indices grouped by region.
struct WorldOverviewView: View {
    @ObservedObject var store: WorldStore
    let onSelect: (WorldIndex) -> Void
    @AppStorage("worldPeriod") private var period = "1d"
    private let periods = ["1d", "3d", "7d", "30d", "180d", "1y", "3y", "5y", "10y"]

    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isRegular: Bool { sizeClass == .regular }

    private var hasCrypto: Bool {
        store.regions.contains { $0.id == "assets" && $0.indices.contains { $0.id == "crypto50" } }
    }

    private var titleView: some View {
        Text("World markets")
            .font(Theme.serif(.largeTitle, scale: isRegular ? 1.35 : 1))
            .foregroundColor(Theme.text)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: isRegular ? nil : .infinity, alignment: .leading)
    }

    private var buttons: some View {
        HomeHeaderButtons(
            shareTitle: AppLanguage.string("World markets"),
            shareSubtitle: shareSubtitle(period: period, asOf: store.overview?.asOf)
        ) { WorldMapContent(regions: store.regions, period: period, onSelect: { _ in }) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                if isRegular {
                    // iPad: заголовок и кнопки в одной строке, шрифт крупнее.
                    HStack {
                        titleView
                        Spacer()
                        buttons
                    }
                    .padding(.horizontal)
                } else {
                    // iPhone: заголовок на своей строке, кнопки ниже — название не сжимается.
                    VStack(alignment: .leading, spacing: 8) {
                        titleView
                        buttons
                    }
                    .padding(.horizontal)
                }
                PeriodSwitchView(selectedPeriod: $period, availablePeriods: periods)
                VStack(alignment: .leading, spacing: 1) {
                    Group {
                        if let date = localizedShortDate(store.overview?.asOf) {
                            Text("Closing prices · \(date)")
                        } else {
                            Text("Closing prices")
                        }
                    }
                    if hasCrypto { Text("Data: CoinGecko") }
                }
                .font(Theme.ui(.caption2))
                .foregroundColor(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }
            .padding(.top, 8)
            .background(Theme.bg)

            GeometryReader { geometry in
                WorldMapContent(regions: store.regions, period: period, onSelect: onSelect)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .themeScreen()
        .navigationBarHidden(true)
    }
}

// Кнопки шапки главного экрана: утренняя сводка, поделиться, язык (остальное — во вкладках).
private struct HomeHeaderButtons<Map: View>: View {
    let shareTitle: String
    let shareSubtitle: String
    @ViewBuilder let map: () -> Map

    var body: some View {
        HStack(spacing: 6) {
            NavigationLink { MarketBriefView() } label: {
                Image(systemName: "sparkles")
                    .font(.subheadline)
                    .frame(width: 34, height: 34)
                    .outlinedControl()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Market brief"))
            ShareMapButton(title: shareTitle, subtitle: shareSubtitle, map: map)
            LanguageMenu()
        }
    }
}

// Карта мира: регионы, внутри них индексы.
struct WorldMapContent: View {
    let regions: [WorldRegion]
    let period: String
    let onSelect: (WorldIndex) -> Void

    var body: some View {
        TreemapLayout(weights: regions.map { SizeMode.weight($0.totalCap) }) {
            ForEach(regions) { region in
                RegionBlock(region: region, period: period, onSelect: onSelect)
            }
        }
    }
}

private struct RegionBlock: View {
    let region: WorldRegion
    let period: String
    let onSelect: (WorldIndex) -> Void

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                if geo.size.height > 60 && geo.size.width > 70 {
                    Text(region.title)
                        .font(Theme.ui(.caption, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundColor(Theme.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                }
                TreemapLayout(weights: region.drawable.map { SizeMode.weight($0.capUSD ?? 0) }) {
                    ForEach(region.drawable) { index in
                        Button { onSelect(index) } label: {
                            WorldIndexTile(index: index, change: index.change(for: period), period: period)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(2)
    }
}

struct WorldIndexTile: View {
    let index: WorldIndex
    let change: Double?
    var period: String? = nil

    var body: some View {
        TileContainer {
            VStack(spacing: 2) {
                Text(verbatim: "\(index.flag) \(index.name)")
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

// Shows its content only when the tile is big enough to read it.
struct TileContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geo in
            content()
                .frame(width: geo.size.width, height: geo.size.height)
                .opacity(geo.size.width >= 40 && geo.size.height >= 28 ? 1 : 0)
        }
    }
}

// "Home" returns to the world map (set by ContentView when the map is available).
private struct GoHomeKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var goHome: (() -> Void)? {
        get { self[GoHomeKey.self] }
        set { self[GoHomeKey.self] = newValue }
    }
}

struct HomeButton: View {
    @Environment(\.goHome) private var goHome

    var body: some View {
        if let goHome {
            Button(action: goHome) {
                Image(systemName: "house.fill")
                    .font(.subheadline)
                    .frame(width: 34, height: 34)
                    .outlinedControl()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Home"))
        }
    }
}
