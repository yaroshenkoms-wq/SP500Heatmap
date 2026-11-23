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

    var flag: String {
        IndexInfo(id: id, name: name, region: nil, country: country, currency: nil,
                  live: false, count: nil, historyThrough: nil).flag
    }
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
    private let periods = ["1d", "3d", "7d", "30d", "180d", "1y"]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text("World markets")
                    .font(.largeTitle)
                    .bold()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                PeriodSwitchView(selectedPeriod: $period, availablePeriods: periods)
                Group {
                    if let date = localizedShortDate(store.overview?.asOf) {
                        Text("Closing prices · \(date)")
                    } else {
                        Text("Closing prices")
                    }
                }
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }
            .padding(.top, 8)
            .background(Color(.systemBackground))

            GeometryReader { geometry in
                TreemapLayout(weights: store.regions.map { $0.totalCap }) {
                    ForEach(store.regions) { region in
                        RegionBlock(region: region, period: period, onSelect: onSelect)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .navigationBarHidden(true)
        .edgesIgnoringSafeArea(.bottom)
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
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                }
                TreemapLayout(weights: region.drawable.map { $0.capUSD ?? 0 }) {
                    ForEach(region.drawable) { index in
                        Button { onSelect(index) } label: {
                            WorldIndexTile(index: index, change: index.change(for: period))
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

    var body: some View {
        TileContainer {
            VStack(spacing: 2) {
                Text(verbatim: "\(index.flag) \(index.name)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let change {
                    Text(formatPercent(change))
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .padding(.horizontal, 3)
        }
        .background(HeatmapColor.color(for: change))
        .cornerRadius(6)
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
                    .font(.body)
                    .foregroundColor(.blue)
                    .frame(width: 34, height: 34)
                    .background(Color.blue.opacity(0.12), in: Circle())
            }
            .accessibilityLabel(Text("Home"))
        }
    }
}
