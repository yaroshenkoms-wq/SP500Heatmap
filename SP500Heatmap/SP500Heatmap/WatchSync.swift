import Foundation
import Combine
import WatchConnectivity

/// Запасной путь синхронизации с Apple Watch: списки избранного уходят на часы через WatchConnectivity
/// (applicationContext), на случай если iCloud KVS ещё не дошёл. Основной путь — общий iCloud KVS.
@MainActor
final class WatchSync: NSObject, WCSessionDelegate {
    static let shared = WatchSync()
    private var bag = Set<AnyCancellable>()
    private var started = false

    func start() {
        guard !started, WCSession.isSupported() else { return }
        started = true
        WCSession.default.delegate = self
        WCSession.default.activate()
        FavoritesStore.shared.objectWillChange
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.push() }
            .store(in: &bag)
    }

    private func push() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let store = FavoritesStore.shared
        let lists: [[String: Any]] = store.lists.map { list in
            ["id": list.id, "name": list.name,
             "items": store.items(in: list.id).map { ["t": $0.ticker, "n": $0.name, "i": $0.indexId] }]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: lists) else { return }
        try? session.updateApplicationContext(["lists": data])
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.push() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.push() }
    }
}
