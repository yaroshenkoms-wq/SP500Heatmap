import Foundation
import AppIntents
import WidgetKit

/// Данные для виджетов: свежий запрос /api/v1/world-overview, а если сети нет — снимок из App Group.
enum SnapshotLoader {
    private struct ServerOverview: Decodable {
        struct Region: Decodable {
            let id: String
            let indices: [Index]
        }
        struct Index: Decodable {
            let id: String
            let name: String
            let country: String?
            let capUSD: Double?
            let changes: [String: Double?]?
        }
        let asOf: String?
        let regions: [Region]
    }

    static func load() async -> WidgetSnapshot? {
        var snapshot = SnapshotIO.read()
        if let fresh = await fetchOverview() {
            var merged = snapshot ?? WidgetSnapshot()
            merged.updated = Date()
            merged.asOf = fresh.asOf
            merged.regions = fresh.regions.map { region in
                WidgetSnapshot.Region(id: region.id, indices: region.indices.map { index in
                    var changes: [String: Double] = [:]
                    for (key, value) in index.changes ?? [:] {
                        if let value { changes[key] = value }
                    }
                    return WidgetSnapshot.Idx(id: index.id, name: index.name, country: index.country,
                                              capUSD: index.capUSD, changes: changes)
                })
            }
            SnapshotIO.write(merged)
            snapshot = merged
        }
        return snapshot
    }

    private static func fetchOverview() async -> ServerOverview? {
        guard let base = Bundle.main.object(forInfoDictionaryKey: "BASE_URL") as? String,
              let url = URL(string: base + "/api/v1/world-overview") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let overview = try? JSONDecoder().decode(ServerOverview.self, from: data),
              overview.regions.contains(where: { !$0.indices.isEmpty }) else { return nil }
        return overview
    }
}

// MARK: Записи и поставщики данных

struct MarketEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let indexId: String
}

// Виджеты «Мир» и «Избранное» без настроек.
struct NoConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Widget"
}

struct StaticProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MarketEntry {
        MarketEntry(date: Date(), snapshot: nil, indexId: "sp500")
    }

    func snapshot(for configuration: NoConfigIntent, in context: Context) async -> MarketEntry {
        MarketEntry(date: Date(), snapshot: context.isPreview ? SnapshotIO.read() : await SnapshotLoader.load(), indexId: "sp500")
    }

    func timeline(for configuration: NoConfigIntent, in context: Context) async -> Timeline<MarketEntry> {
        let entry = MarketEntry(date: Date(), snapshot: await SnapshotLoader.load(), indexId: "sp500")
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60)))
    }
}

// Экран блокировки: индекс выбирается в настройках виджета (по умолчанию S&P 500).
struct IndexEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Index"
    static var defaultQuery = IndexQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct IndexQuery: EntityQuery {
    private func all() -> [IndexEntity] {
        let indices = SnapshotIO.read()?.allIndices ?? []
        let list = indices.map { IndexEntity(id: $0.id, name: $0.name) }
        return list.isEmpty ? [IndexEntity(id: "sp500", name: "S&P 500")] : list
    }

    func entities(for identifiers: [String]) async throws -> [IndexEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [IndexEntity] { all() }

    func defaultResult() async -> IndexEntity? { IndexEntity(id: "sp500", name: "S&P 500") }
}

struct SelectIndexIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose index"
    static var description = IntentDescription("Pick the index shown on the Lock Screen.")

    @Parameter(title: "Index")
    var index: IndexEntity?
}

struct IndexProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MarketEntry {
        MarketEntry(date: Date(), snapshot: nil, indexId: "sp500")
    }

    func snapshot(for configuration: SelectIndexIntent, in context: Context) async -> MarketEntry {
        MarketEntry(date: Date(), snapshot: context.isPreview ? SnapshotIO.read() : await SnapshotLoader.load(),
                    indexId: configuration.index?.id ?? "sp500")
    }

    func timeline(for configuration: SelectIndexIntent, in context: Context) async -> Timeline<MarketEntry> {
        let entry = MarketEntry(date: Date(), snapshot: await SnapshotLoader.load(),
                                indexId: configuration.index?.id ?? "sp500")
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60)))
    }
}
