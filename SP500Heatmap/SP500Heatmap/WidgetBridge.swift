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

    /// Составы списков избранного; бумаги, которых нет ни в одном списке, пропадают из снимка (виджет обновляется сразу).
    static func publish(lists: [WidgetSnapshot.FavList]) {
        var snapshot = SnapshotIO.read() ?? WidgetSnapshot()
        let keep = Set(lists.flatMap(\.tickers))
        snapshot.favorites = snapshot.favorites.filter { keep.contains($0.ticker) }
        snapshot.favLists = lists
        SnapshotIO.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
