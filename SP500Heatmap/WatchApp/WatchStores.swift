import Foundation
import SwiftUI
import WatchConnectivity

/// Мировые рынки: обзор индексов (с запасом на диске).
@MainActor
final class WatchWorldStore: ObservableObject {
    static let shared = WatchWorldStore()
    @Published private(set) var overview: WOverview? = WatchCache.loadOverview()
    @Published private(set) var loading = false

    var regions: [WRegion] {
        (overview?.regions ?? []).filter { !$0.indices.isEmpty }
            .sorted { $0.indices.reduce(0) { $0 + ($1.capUSD ?? 0) } > $1.indices.reduce(0) { $0 + ($1.capUSD ?? 0) } }
    }

    func currency(forIndex id: String) -> String? {
        overview?.allIndices.first { $0.id == id }?.currency
    }

    func load() async {
        loading = true
        defer { loading = false }
        if let fresh = await WatchCache.overview() { overview = fresh }
    }
}

// MARK: Списки избранного

struct WList: Identifiable, Hashable {
    struct Item: Identifiable, Hashable {
        let ticker: String
        let name: String
        let indexId: String
        var id: String { ticker }
    }
    let id: String
    let name: String
    let items: [Item]
}

/// Списки избранного. Источники:
/// 1) iCloud KVS (ключ "favoritesV2", тот же идентификатор хранилища, что у iPhone-приложения) — основной;
/// 2) WatchConnectivity: iPhone присылает списки в applicationContext — запасной, если iCloud ещё не дошёл.
@MainActor
final class WatchListsStore: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchListsStore()

    // Формат хранения как у FavoritesStore в iPhone-приложении.
    private struct ListMeta: Codable { var n: String; var o: Double; var s: String?; var t: Double; var r: Bool? }
    private struct Entry: Codable { var n: String; var i: String; var t: Double; var r: Bool?; var p: Double?; var m: String? }
    private struct State: Codable { var l: [String: ListMeta] = [:]; var e: [String: Entry] = [:] }

    @Published private(set) var lists: [WList] = []
    @Published private(set) var source: String = ""   // "icloud" | "phone" | ""

    private var kvsLists: [WList] = []
    private var phoneLists: [WList] = []
    private let cloud = NSUbiquitousKeyValueStore.default
    private static let phoneKey = "watchPhoneLists"

    override private init() {
        super.init()
        phoneLists = Self.decodePhone(UserDefaults.standard.data(forKey: Self.phoneKey))
        readCloud()
        NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                               object: cloud, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.readCloud() }
        }
        cloud.synchronize()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func refresh() { cloud.synchronize(); readCloud() }

    private func readCloud() {
        if let data = cloud.data(forKey: "favoritesV2"),
           let state = try? JSONDecoder().decode(State.self, from: data) {
            let live = state.l.filter { $0.value.r != true }
                .sorted { $0.value.o == $1.value.o ? $0.key < $1.key : $0.value.o < $1.value.o }
            kvsLists = live.map { id, meta in
                let prefix = id + "|"
                let items = state.e.compactMap { k, v -> (String, Entry)? in
                    guard v.r != true, k.hasPrefix(prefix) else { return nil }
                    return (String(k.dropFirst(prefix.count)), v)
                }
                .sorted { a, b in
                    let pa = a.1.p ?? a.1.t, pb = b.1.p ?? b.1.t
                    return pa == pb ? a.0 < b.0 : pa < pb
                }
                .map { WList.Item(ticker: $0.0, name: $0.1.n, indexId: $0.1.i) }
                let name = meta.n.isEmpty ? String(localized: "Favorites") : meta.n
                return WList(id: id, name: name, items: items)
            }
        }
        merge()
    }

    private func merge() {
        if kvsLists.contains(where: { !$0.items.isEmpty }) {
            lists = kvsLists; source = "icloud"
        } else if phoneLists.contains(where: { !$0.items.isEmpty }) {
            lists = phoneLists; source = "phone"
        } else {
            lists = kvsLists.isEmpty ? phoneLists : kvsLists
            source = ""
        }
    }

    // MARK: WatchConnectivity

    /// Контекст: ["lists": [["id","name","items":[["t","n","i"]]]]] (см. WatchSync.swift на iPhone).
    private nonisolated static func decodePhone(_ data: Data?) -> [WList] {
        guard let data, let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return raw.compactMap { d in
            guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
            let items = (d["items"] as? [[String: String]] ?? []).compactMap { i -> WList.Item? in
                guard let t = i["t"] else { return nil }
                return WList.Item(ticker: t, name: i["n"] ?? t, indexId: i["i"] ?? "sp500")
            }
            return WList(id: id, name: name, items: items)
        }
    }

    private func applyContext(_ context: [String: Any]) {
        guard let data = context["lists"] as? Data else { return }
        UserDefaults.standard.set(data, forKey: Self.phoneKey)
        phoneLists = Self.decodePhone(data)
        merge()
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        Task { @MainActor in self.applyContext(context) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.applyContext(applicationContext) }
    }
}
