import WidgetKit
import SwiftUI
import AppIntents

// MARK: Выбор индекса

struct WatchIndexEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Index"
    static var defaultQuery = WatchIndexQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct WatchIndexQuery: EntityQuery {
    private func all() async -> [WatchIndexEntity] {
        let list = await WatchCache.overview()?.allIndices.map { WatchIndexEntity(id: $0.id, name: $0.name) } ?? []
        return list.isEmpty ? [WatchIndexEntity(id: "sp500", name: "S&P 500")] : list
    }
    func entities(for identifiers: [String]) async throws -> [WatchIndexEntity] {
        await all().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [WatchIndexEntity] { await all() }
    func defaultResult() async -> WatchIndexEntity? { WatchIndexEntity(id: "sp500", name: "S&P 500") }
}

struct SelectWatchIndexIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose index"
    @Parameter(title: "Index") var index: WatchIndexEntity?
}

// MARK: Данные

struct IndexEntry: TimelineEntry {
    let date: Date
    let id: String
    let name: String
    let change: Double?
    let mover: (ticker: String, change: Double)?
}

struct IndexProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> IndexEntry {
        IndexEntry(date: .now, id: "sp500", name: "S&P 500", change: 0.8, mover: ("NVDA", 3.1))
    }

    func snapshot(for configuration: SelectWatchIndexIntent, in context: Context) async -> IndexEntry {
        context.isPreview ? placeholder(in: context) : await entry(for: configuration, family: context.family)
    }

    func timeline(for configuration: SelectWatchIndexIntent, in context: Context) async -> Timeline<IndexEntry> {
        let entry = await entry(for: configuration, family: context.family)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60)))
    }

    func recommendations() -> [AppIntentRecommendation<SelectWatchIndexIntent>] {
        []
    }

    private func entry(for configuration: SelectWatchIndexIntent, family: WidgetFamily) async -> IndexEntry {
        let id = configuration.index?.id ?? "sp500"
        let overview = await WatchCache.overview()
        let index = overview?.allIndices.first { $0.id == id }
        var mover: (String, Double)?
        if family == .accessoryRectangular, let perf = try? await WatchAPI.performance(index: id) {
            let all = perf.compactMap { t, v in (v["1d"] ?? nil).map { (t, $0) } }
            mover = all.max { abs($0.1) < abs($1.1) }
        }
        return IndexEntry(date: .now, id: id, name: index?.name ?? configuration.index?.name ?? "S&P 500",
                          change: index?.change("1d"), mover: mover)
    }
}

// MARK: Виды

struct IndexComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: IndexEntry

    private var gaugeValue: Double {
        guard let c = entry.change else { return 0.5 }
        return 0.5 + 0.5 * max(-1, min(1, c / SharedHeat.cap))
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: gaugeValue) {
                Text(verbatim: "1d")
            } currentValueLabel: {
                Text(verbatim: WTheme.pct(entry.change)).minimumScaleFactor(0.5)
            }
            .gaugeStyle(.accessoryCircular)
            .tint(Gradient(colors: [SharedHeat.color(for: -SharedHeat.cap), WTheme.gold, SharedHeat.color(for: SharedHeat.cap)]))
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: entry.name).font(.caption2).foregroundStyle(WTheme.gold).widgetAccentable().lineLimit(1)
                Text(verbatim: WTheme.pct(entry.change)).font(.headline)
                if let mover = entry.mover {
                    Text(verbatim: "\(mover.ticker) \(WTheme.pct(mover.change))").font(.caption2).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            Text(verbatim: "\(entry.name) \(WTheme.pct(entry.change))")
        case .accessoryCorner:
            Text(verbatim: WTheme.pct(entry.change))
                .widgetCurvesContent()
                .widgetLabel { Text(verbatim: entry.name) }
        default:
            Text(verbatim: WTheme.pct(entry.change))
        }
    }
}

struct IndexComplication: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "WatchIndexComplication", intent: SelectWatchIndexIntent.self,
                               provider: IndexProvider()) { entry in
            IndexComplicationView(entry: entry)
                .containerBackground(WTheme.bg, for: .widget)
        }
        .configurationDisplayName("Index change")
        .description("Today's change of an index.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

@main
struct SP500WatchWidgetsBundle: WidgetBundle {
    var body: some Widget { IndexComplication() }
}
