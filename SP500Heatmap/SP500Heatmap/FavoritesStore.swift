import SwiftUI
import WidgetKit

struct FavoriteItem: Identifiable, Hashable {
    let ticker: String
    let name: String
    let indexId: String
    var note: String = ""
    var id: String { ticker }
}

/// Порядок бумаг внутри списка.
enum FavSort: String, CaseIterable, Identifiable {
    case manual, change, name, cap
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .manual: return "Manual order"
        case .change: return "% change"
        case .name: return "Name"
        case .cap: return "Market cap"
        }
    }
}

struct FavoriteList: Identifiable, Hashable {
    static let defaultId = "default"
    let id: String
    let rawName: String
    let sort: FavSort
    /// Первый список по умолчанию называется «Избранное» на языке приложения.
    var name: String { rawName.isEmpty ? AppLanguage.string("Favorites") : rawName }
}

/// Списки избранного. Хранение: ключ "favoritesV2" (компактный JSON) в App Group и в iCloud KVS
/// (NSUbiquitousKeyValueStore, лимит 1 МБ). Слияние с другим устройством — по времени последней
/// правки каждой записи и каждого списка: побеждает более поздняя, удаление не «воскресает».
/// Старый формат (ключи "favoritesState" и "favorites") при первом запуске переносится в список
/// по умолчанию; ключ "favorites" (тикеры списка по умолчанию) по-прежнему пишется для совместимости.
@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    private struct ListMeta: Codable {
        var n: String          // имя ("" — стандартное)
        var o: Double          // порядок
        var s: String?         // сортировка
        var t: Double          // время правки
        var r: Bool?           // удалён
    }
    private struct Entry: Codable {
        var n: String          // имя компании
        var i: String          // индекс
        var t: Double          // время правки
        var r: Bool?           // удалена из списка
        var p: Double?         // место при ручной сортировке
        var m: String?         // заметка
    }
    private struct State: Codable {
        var l: [String: ListMeta] = [:]
        var e: [String: Entry] = [:]   // ключ "<id списка>|<тикер>"
    }
    private struct LegacyEntry: Codable {
        var name: String
        var indexId: String
        var ts: Double
        var removed: Bool
    }

    private static let listKey = "favorites"
    private static let legacyStateKey = "favoritesState"
    private static let stateKey = "favoritesV2"
    private static let tombstoneAge: Double = 90 * 86400

    @Published private var state = State()

    private var local: UserDefaults { AppGroup.defaults }
    private var cloud: NSUbiquitousKeyValueStore { .default }

    private init() {
        if let data = local.data(forKey: Self.stateKey), let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        }
        importLegacy()
        mergeCloud()
        ensureDefault()
        persist()
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.externalChange() }
        }
        cloud.synchronize()
    }

    // MARK: чтение

    var lists: [FavoriteList] {
        state.l.filter { $0.value.r != true }
            .sorted { $0.value.o == $1.value.o ? $0.key < $1.key : $0.value.o < $1.value.o }
            .map { FavoriteList(id: $0.key, rawName: $0.value.n, sort: FavSort(rawValue: $0.value.s ?? "") ?? .manual) }
    }

    func list(_ id: String) -> FavoriteList? { lists.first { $0.id == id } }

    private func key(_ listId: String, _ ticker: String) -> String { listId + "|" + ticker }

    private func liveEntries(in listId: String) -> [(ticker: String, entry: Entry)] {
        let prefix = listId + "|"
        return state.e.compactMap { k, v in
            guard v.r != true, k.hasPrefix(prefix) else { return nil }
            return (String(k.dropFirst(prefix.count)), v)
        }
    }

    /// Бумаги списка в ручном порядке (сортировки по доходности, имени и капитализации делает экран).
    func items(in listId: String) -> [FavoriteItem] {
        liveEntries(in: listId)
            .sorted { a, b in
                let pa = a.entry.p ?? a.entry.t, pb = b.entry.p ?? b.entry.t
                return pa == pb ? a.ticker < b.ticker : pa < pb
            }
            .map { FavoriteItem(ticker: $0.ticker, name: $0.entry.n, indexId: $0.entry.i, note: $0.entry.m ?? "") }
    }

    /// Все бумаги из всех списков без повторов (для котировок и виджета).
    var allItems: [FavoriteItem] {
        var seen = Set<String>()
        var result: [FavoriteItem] = []
        for list in lists {
            for item in items(in: list.id) where seen.insert(item.ticker).inserted { result.append(item) }
        }
        return result
    }

    func contains(_ ticker: String) -> Bool { !listIds(containing: ticker).isEmpty }

    func contains(_ ticker: String, in listId: String) -> Bool {
        state.e[key(listId, ticker)].map { $0.r != true } ?? false
    }

    func listIds(containing ticker: String) -> [String] {
        lists.map(\.id).filter { contains(ticker, in: $0) }
    }

    // MARK: правки

    private var now: Double { Date().timeIntervalSince1970 }

    func setMembership(ticker: String, name: String, indexId: String, list listId: String, on: Bool) {
        let k = key(listId, ticker)
        if on {
            guard !contains(ticker, in: listId) else { return }
            let nextPos = (liveEntries(in: listId).compactMap { $0.entry.p ?? $0.entry.t }.max() ?? 0) + 1
            state.e[k] = Entry(n: name, i: indexId, t: now, r: nil, p: max(nextPos, now), m: state.e[k]?.m)
        } else {
            guard state.e[k] != nil else { return }
            state.e[k]?.r = true
            state.e[k]?.t = now
        }
        persist()
    }

    /// Старый вызов: звезда в списке по умолчанию.
    func toggle(ticker: String, name: String, indexId: String) {
        setMembership(ticker: ticker, name: name, indexId: indexId, list: FavoriteList.defaultId,
                      on: !contains(ticker, in: FavoriteList.defaultId))
    }

    /// Убрать бумагу из всех списков.
    func removeEverywhere(ticker: String) {
        for id in listIds(containing: ticker) {
            state.e[key(id, ticker)]?.r = true
            state.e[key(id, ticker)]?.t = now
        }
        persist()
    }

    @discardableResult
    func createList(name: String) -> String {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let order = (state.l.values.map(\.o).max() ?? 0) + 1
        state.l[id] = ListMeta(n: name.trimmingCharacters(in: .whitespacesAndNewlines), o: order, s: nil, t: now, r: nil)
        persist()
        return id
    }

    func renameList(_ id: String, to name: String) {
        guard state.l[id] != nil else { return }
        state.l[id]?.n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        state.l[id]?.t = now
        persist()
    }

    /// Список по умолчанию удалить нельзя — только очистить.
    func deleteList(_ id: String) {
        guard id != FavoriteList.defaultId, state.l[id] != nil else { return }
        state.l[id]?.r = true
        state.l[id]?.t = now
        for entry in liveEntries(in: id) {
            state.e[key(id, entry.ticker)]?.r = true
            state.e[key(id, entry.ticker)]?.t = now
        }
        persist()
    }

    func moveLists(from: IndexSet, to: Int) {
        var order = lists.map(\.id)
        order.move(fromOffsets: from, toOffset: to)
        for (i, id) in order.enumerated() where state.l[id]?.o != Double(i) {
            state.l[id]?.o = Double(i)
            state.l[id]?.t = now
        }
        persist()
    }

    func setSort(_ id: String, _ sort: FavSort) {
        guard state.l[id] != nil else { return }
        state.l[id]?.s = sort == .manual ? nil : sort.rawValue
        state.l[id]?.t = now
        persist()
    }

    /// Перетаскивание в ручном порядке (в списке показаны бумаги в порядке `shown`).
    func moveItems(in listId: String, shown: [FavoriteItem], from: IndexSet, to: Int) {
        var order = shown.map(\.ticker)
        order.move(fromOffsets: from, toOffset: to)
        for (i, ticker) in order.enumerated() where state.e[key(listId, ticker)]?.p != Double(i) {
            state.e[key(listId, ticker)]?.p = Double(i)
            state.e[key(listId, ticker)]?.t = now
        }
        persist()
    }

    func setNote(_ ticker: String, in listId: String, note: String) {
        let k = key(listId, ticker)
        guard state.e[k] != nil else { return }
        let clean = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140))
        state.e[k]?.m = clean.isEmpty ? nil : clean
        state.e[k]?.t = now
        persist()
    }

    // MARK: внутреннее

    private func ensureDefault() {
        if state.l[FavoriteList.defaultId] == nil || state.l[FavoriteList.defaultId]?.r == true {
            state.l[FavoriteList.defaultId] = ListMeta(n: "", o: -1, s: nil, t: 0, r: nil)
        }
    }

    /// Перенос из старого формата: один список избранного → список по умолчанию (слияние по времени).
    private func importLegacy() {
        func decode(_ data: Data?) -> [String: LegacyEntry] {
            guard let data, let v = try? JSONDecoder().decode([String: LegacyEntry].self, from: data) else { return [:] }
            return v
        }
        guard local.bool(forKey: "favoritesMigratedV2") == false else { return }
        var legacy = decode(local.data(forKey: Self.legacyStateKey))
        for (t, e) in decode(cloud.data(forKey: Self.legacyStateKey)) where e.ts > (legacy[t]?.ts ?? 0) { legacy[t] = e }
        for (ticker, e) in legacy {
            let k = key(FavoriteList.defaultId, ticker)
            if e.ts > (state.e[k]?.t ?? 0) {
                state.e[k] = Entry(n: e.name, i: e.indexId, t: e.ts, r: e.removed ? true : nil, p: e.ts, m: state.e[k]?.m)
            }
        }
        local.set(true, forKey: "favoritesMigratedV2")
    }

    private func externalChange() {
        mergeCloud()
        ensureDefault()
        persist()
    }

    private func mergeCloud() {
        guard let data = cloud.data(forKey: Self.stateKey),
              let remote = try? JSONDecoder().decode(State.self, from: data) else { return }
        for (id, meta) in remote.l where meta.t > (state.l[id]?.t ?? -1) { state.l[id] = meta }
        for (k, entry) in remote.e where entry.t > (state.e[k]?.t ?? 0) { state.e[k] = entry }
    }

    private func persist() {
        // Старые «могилы» удаления не храним вечно: место в iCloud ограничено.
        let cutoff = now - Self.tombstoneAge
        state.e = state.e.filter { $0.value.r != true || $0.value.t > cutoff }
        state.l = state.l.filter { $0.value.r != true || $0.value.t > cutoff }
        let data = try? JSONEncoder().encode(state)
        let defaults = items(in: FavoriteList.defaultId).map(\.ticker)
        local.set(data, forKey: Self.stateKey)
        local.set(defaults, forKey: Self.listKey)
        cloud.set(data, forKey: Self.stateKey)
        cloud.set(defaults, forKey: Self.listKey)
        cloud.synchronize()
        // Убранный из списков тикер пропадает из виджета сразу; виджет узнаёт и составы списков.
        WidgetBridge.publish(lists: lists.map { list in
            WidgetSnapshot.FavList(id: list.id, name: list.name, sort: list.sort.rawValue,
                                   tickers: items(in: list.id).map(\.ticker))
        })
    }
}

/// Пункты меню «в какие списки добавить»: галочка у списков, где бумага уже есть.
struct FavoriteListMenuItems: View {
    let ticker: String
    let name: String
    let indexId: String
    var onNewList: (() -> Void)? = nil
    @ObservedObject private var store = FavoritesStore.shared

    var body: some View {
        ForEach(store.lists) { list in
            let on = store.contains(ticker, in: list.id)
            Button {
                store.setMembership(ticker: ticker, name: name, indexId: indexId, list: list.id, on: !on)
            } label: {
                Label {
                    Text(verbatim: list.name)
                } icon: {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                }
            }
        }
        if let onNewList {
            Divider()
            Button(action: onNewList) { Label("New list…", systemImage: "plus") }
        }
    }
}

/// Звезда «добавить в список». Если список один — нажатие просто добавляет/убирает, меню — по долгому нажатию.
struct FavoriteStarButton: View {
    let ticker: String
    let name: String
    @ObservedObject private var store = FavoritesStore.shared
    @EnvironmentObject private var indexStore: IndexStore
    @State private var showNew = false
    @State private var newName = ""

    var body: some View {
        let on = store.contains(ticker)
        let label = Image(systemName: on ? "star.fill" : "star")
            .font(.subheadline)
            .foregroundColor(Theme.gold)
            .frame(width: 34, height: 34)
            .outlinedControl()
        Group {
            if store.lists.count == 1 {
                Menu {
                    FavoriteListMenuItems(ticker: ticker, name: name, indexId: indexStore.selectedId,
                                          onNewList: { showNew = true })
                } label: { label } primaryAction: {
                    store.toggle(ticker: ticker, name: name, indexId: indexStore.selectedId)
                }
            } else {
                Menu {
                    FavoriteListMenuItems(ticker: ticker, name: name, indexId: indexStore.selectedId,
                                          onNewList: { showNew = true })
                } label: { label }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Add to list"))
        .alert("New list", isPresented: $showNew) {
            TextField("List name", text: $newName)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Create") {
                let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let id = store.createList(name: trimmed)
                    store.setMembership(ticker: ticker, name: name, indexId: indexStore.selectedId, list: id, on: true)
                }
                newName = ""
            }
        }
    }
}

extension View {
    /// Долгое нажатие на плитке или строке: добавить в списки / убрать.
    func favoriteContextMenu(ticker: String, name: String, indexId: String) -> some View {
        contextMenu {
            FavoriteListMenuItems(ticker: ticker, name: name, indexId: indexId)
        }
    }
}
