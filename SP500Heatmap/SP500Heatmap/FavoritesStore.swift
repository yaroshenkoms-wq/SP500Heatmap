import SwiftUI
import WidgetKit

struct FavoriteItem: Identifiable, Hashable {
    let ticker: String
    let name: String
    let indexId: String
    var id: String { ticker }
}

/// Избранные бумаги. Хранение по контракту: ключ "favorites" (массив тикеров) в App Group
/// и в iCloud (NSUbiquitousKeyValueStore). Для слияния с другим устройством рядом лежит
/// "favoritesState": по каждому тикеру индекс, имя, время и признак удаления; побеждает
/// более поздняя запись, поэтому удаление на одном устройстве не «воскресает» с другого.
@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    private struct Entry: Codable {
        var name: String
        var indexId: String
        var ts: Double
        var removed: Bool
    }

    private static let listKey = "favorites"
    private static let stateKey = "favoritesState"

    private var state: [String: Entry] = [:]
    @Published private(set) var items: [FavoriteItem] = []

    private var local: UserDefaults { AppGroup.defaults }
    private var cloud: NSUbiquitousKeyValueStore { .default }

    private init() {
        state = Self.decode(local.data(forKey: Self.stateKey))
        mergeCloud()
        rebuild()
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.externalChange() }
        }
        cloud.synchronize()
    }

    func contains(_ ticker: String) -> Bool { items.contains { $0.ticker == ticker } }

    func toggle(ticker: String, name: String, indexId: String) {
        let now = Date().timeIntervalSince1970
        if contains(ticker) {
            state[ticker]?.removed = true
            state[ticker]?.ts = now
        } else {
            state[ticker] = Entry(name: name, indexId: indexId, ts: now, removed: false)
        }
        persist()
    }

    // MARK: внутреннее

    private static func decode(_ data: Data?) -> [String: Entry] {
        guard let data, let value = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return value
    }

    private func externalChange() {
        mergeCloud()
        persist()
    }

    private func mergeCloud() {
        let remote = Self.decode(cloud.data(forKey: Self.stateKey))
        for (ticker, entry) in remote where entry.ts > (state[ticker]?.ts ?? 0) {
            state[ticker] = entry
        }
    }

    private func rebuild() {
        items = state
            .filter { !$0.value.removed }
            .sorted { $0.value.ts < $1.value.ts }
            .map { FavoriteItem(ticker: $0.key, name: $0.value.name, indexId: $0.value.indexId) }
    }

    private func persist() {
        rebuild()
        let data = try? JSONEncoder().encode(state)
        let tickers = items.map(\.ticker)
        local.set(data, forKey: Self.stateKey)
        local.set(tickers, forKey: Self.listKey)
        cloud.set(data, forKey: Self.stateKey)
        cloud.set(tickers, forKey: Self.listKey)
        cloud.synchronize()
        // Убранный из избранного тикер пропадает из виджета сразу.
        WidgetBridge.pruneFavorites(keeping: Set(tickers))
    }
}

/// Звезда «в избранное / убрать».
struct FavoriteStarButton: View {
    let ticker: String
    let name: String
    @ObservedObject private var store = FavoritesStore.shared
    @EnvironmentObject private var indexStore: IndexStore

    var body: some View {
        let on = store.contains(ticker)
        Button {
            store.toggle(ticker: ticker, name: name, indexId: indexStore.selectedId)
        } label: {
            Image(systemName: on ? "star.fill" : "star")
                .font(.subheadline)
                .foregroundColor(Theme.gold)
                .frame(width: 34, height: 34)
                .outlinedControl()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(on ? "Remove from favorites" : "Add to favorites")))
    }
}

extension View {
    /// Долгое нажатие на плитке или строке: добавить / убрать из избранного.
    func favoriteContextMenu(ticker: String, name: String, indexId: String) -> some View {
        contextMenu {
            let on = FavoritesStore.shared.contains(ticker)
            Button {
                FavoritesStore.shared.toggle(ticker: ticker, name: name, indexId: indexId)
            } label: {
                Label(LocalizedStringKey(on ? "Remove from favorites" : "Add to favorites"), systemImage: on ? "star.slash" : "star")
            }
        }
    }
}
