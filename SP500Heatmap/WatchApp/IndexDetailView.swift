import SwiftUI

/// Индекс: % за период, мини-карта секторов и лидеры роста/падения.
struct IndexDetailView: View {
    let index: WIndex
    @AppStorage("watchPeriod") private var period = "1d"
    @State private var sectors: [WSector] = []
    @State private var perf: [String: [String: Double?]] = [:]
    @State private var loading = true

    private func change(_ ticker: String) -> Double? {
        guard let v = perf[ticker]?[period] else { return nil }
        return v
    }

    private struct SectorTile: Identifiable {
        let id: String
        let name: String
        let cap: Double
        let change: Double?
    }

    /// Изменение сектора — среднее по компаниям, взвешенное капитализацией.
    private var tiles: [SectorTile] {
        sectors.filter { $0.cap > 0 }.sorted { $0.cap > $1.cap }.map { s in
            var w = 0.0, sum = 0.0
            for c in s.companies where c.marketCap > 0 {
                if let ch = change(c.ticker) { w += c.marketCap; sum += ch * c.marketCap }
            }
            return SectorTile(id: s.id, name: s.name, cap: s.cap, change: w > 0 ? sum / w : nil)
        }
    }

    private var movers: [(company: WCompany, change: Double)] {
        let all = sectors.flatMap(\.companies).compactMap { c in change(c.ticker).map { (company: c, change: $0) } }
        return all.sorted { $0.change > $1.change }
    }

    var body: some View {
        let ranked = movers
        List {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: WTheme.pct(index.change(period)))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(WTheme.textColor(index.change(period)))
                    Text(verbatim: "\(index.flag) \(period)").font(.caption2).foregroundStyle(WTheme.muted)
                }
            }
            if loading && sectors.isEmpty {
                ProgressView()
            }
            if !tiles.isEmpty {
                Section("Sectors") {
                    TreemapLayout(weights: tiles.map(\.cap)) {
                        ForEach(tiles) { tile in
                            ZStack {
                                WTheme.fill(tile.change, period: period)
                                Text(verbatim: String(tile.name.prefix(4)))
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(WTheme.text)
                                    .lineLimit(1).minimumScaleFactor(0.5)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .padding(0.5)
                        }
                    }
                    .frame(height: 96)
                    .listRowInsets(EdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2))
                    .listRowBackground(Color.clear)
                }
            }
            if ranked.count >= 6 {
                Section("Top gainers") { rows(Array(ranked.prefix(3))) }
                Section("Top losers") { rows(Array(ranked.suffix(3).reversed())) }
            }
        }
        .navigationTitle(Text(verbatim: index.name))
        .toolbar { ToolbarItem(placement: .topBarTrailing) { PeriodMenu() } }
        .task { await load() }
    }

    private func rows(_ items: [(company: WCompany, change: Double)]) -> some View {
        ForEach(items, id: \.company.ticker) { item in
            NavigationLink {
                CompanyView(ticker: item.company.ticker, name: item.company.name,
                            currency: index.currency)
            } label: {
                HStack {
                    ChangeBar(change: item.change, period: period)
                    Text(verbatim: item.company.ticker).font(.footnote).foregroundStyle(WTheme.text)
                    Spacer()
                    Text(verbatim: WTheme.pct(item.change)).font(.footnote.weight(.semibold))
                        .foregroundStyle(WTheme.textColor(item.change))
                }
            }
        }
    }

    private func load() async {
        loading = true
        async let s = try? WatchAPI.sectors(index: index.id)
        async let p = try? WatchAPI.performance(index: index.id)
        let (secs, per) = await (s, p)
        sectors = secs ?? sectors
        perf = per ?? perf
        loading = false
    }
}
