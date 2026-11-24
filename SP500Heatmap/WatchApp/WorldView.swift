import SwiftUI

/// Мировые рынки: регионы → список индексов с цветной полоской, % за период.
struct WorldView: View {
    @EnvironmentObject private var world: WatchWorldStore
    @AppStorage("watchPeriod") private var period = "1d"

    var body: some View {
        List {
            if world.regions.isEmpty {
                LoadingOrEmpty(loading: world.loading)
            }
            ForEach(world.regions) { region in
                NavigationLink {
                    RegionView(region: region)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(regionTitle(region.id)).font(.headline).foregroundStyle(WTheme.text)
                            Text(verbatim: "\(region.indices.count)").font(.caption2).foregroundStyle(WTheme.muted)
                        }
                        Spacer()
                        regionStrip(region)
                    }
                }
            }
        }
        .navigationTitle(Text("World markets"))
        .toolbar { ToolbarItem(placement: .topBarTrailing) { PeriodMenu() } }
        .refreshable { await world.load() }
    }

    /// Мини-полоски индексов региона (до 5 штук).
    private func regionStrip(_ region: WRegion) -> some View {
        HStack(spacing: 2) {
            ForEach(region.indices.sorted { ($0.capUSD ?? 0) > ($1.capUSD ?? 0) }.prefix(5)) { index in
                ChangeBar(change: index.change(period), period: period).frame(height: 22)
            }
        }
    }
}

struct RegionView: View {
    let region: WRegion
    @AppStorage("watchPeriod") private var period = "1d"

    var body: some View {
        List {
            ForEach(region.indices.sorted { ($0.capUSD ?? 0) > ($1.capUSD ?? 0) }) { index in
                NavigationLink {
                    IndexDetailView(index: index)
                } label: {
                    HStack(spacing: 8) {
                        ChangeBar(change: index.change(period), period: period)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: index.name).font(.footnote).lineLimit(1).minimumScaleFactor(0.7)
                                .foregroundStyle(WTheme.text)
                            Text(verbatim: WTheme.pct(index.change(period)))
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(WTheme.textColor(index.change(period)))
                        }
                    }
                }
            }
        }
        .navigationTitle(regionTitle(region.id))
        .toolbar { ToolbarItem(placement: .topBarTrailing) { PeriodMenu() } }
    }
}
