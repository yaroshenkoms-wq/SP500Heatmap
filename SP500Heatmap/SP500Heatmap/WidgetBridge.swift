import Foundation
import WidgetKit

/// Приложение кладёт данные для виджетов в App Group (widget_snapshot.json) и просит их обновиться.
@MainActor
enum WidgetBridge {
    static func publish(overview: WorldOverview) {
        var snapshot = SnapshotIO.read() ?? WidgetSnapshot()
        snapshot.updated = Date()
        snapshot.asOf = overview.asOf
        snapshot.regions = overview.regions.map { region in
            WidgetSnapshot.Region(id: region.id, indices: region.indices.map { index in
                var changes: [String: Double] = [:]
                for (key, value) in index.changes ?? [:] {
                    if let value { changes[key] = value }
                }
                return WidgetSnapshot.Idx(id: index.id, name: index.name, country: index.country,
                                          capUSD: index.capUSD, changes: changes)
            })
        }
        SnapshotIO.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func publish(favorites: [WidgetSnapshot.Fav]) {
        var snapshot = SnapshotIO.read() ?? WidgetSnapshot()
        snapshot.favorites = favorites
        SnapshotIO.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Убирает из снимка бумаги, которых больше нет в избранном (и сразу обновляет виджет).
    static func pruneFavorites(keeping tickers: Set<String>) {
        guard var snapshot = SnapshotIO.read() else { return }
        let kept = snapshot.favorites.filter { tickers.contains($0.ticker) }
        guard kept.count != snapshot.favorites.count else { return }
        snapshot.favorites = kept
        SnapshotIO.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
