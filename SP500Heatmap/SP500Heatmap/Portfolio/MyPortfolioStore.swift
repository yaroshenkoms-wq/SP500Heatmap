import SwiftUI

/// Личные портфели. Хранение: JSON-файл `my_portfolios.json` в контейнере App Group (основная копия)
/// и зеркало в iCloud KVS (ключ "myPortfoliosV1", лимит 1 МБ). Слияние — по времени правки каждого портфеля:
/// побеждает более поздняя; удалённый портфель остаётся «могилой» (без сделок) 90 дней.
/// Если данные не влезают в 900 КБ — в iCloud не пишем, остаются только на устройстве (`cloudSkipped`).
@MainActor
final class MyPortfolioStore: ObservableObject {
    static let shared = MyPortfolioStore()

    private static let kvsKey = "myPortfoliosV1"
    private static let selectedKey = "myPortfolioSelected"
    private static let kvsLimit = 900_000
    private static let tombstoneAge: Double = 90 * 86400

    @Published private(set) var all: [MyPortfolio] = []
    @Published private(set) var cloudSkipped = false
    @Published var selectedId: UUID? {
        didSet { UserDefaults.standard.set(selectedId?.uuidString, forKey: Self.selectedKey) }
    }

    private var cloud: NSUbiquitousKeyValueStore { .default }
    private let fileURL: URL
    private let useCloud: Bool

    var portfolios: [MyPortfolio] { all.filter { !$0.deleted } }

    var selected: MyPortfolio? {
        portfolios.first { $0.id == selectedId } ?? portfolios.first
    }

    /// `fileURL` и `useCloud` нужны тестам; приложение пользуется `shared`.
    init(fileURL: URL? = nil, useCloud: Bool = true) {
        self.useCloud = useCloud
        let dir = AppGroup.containerURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = fileURL ?? dir.appendingPathComponent("my_portfolios.json")
        if let data = try? Data(contentsOf: self.fileURL), let saved = try? JSONDecoder().decode([MyPortfolio].self, from: data) {
            all = saved
        }
        selectedId = UserDefaults.standard.string(forKey: Self.selectedKey).flatMap(UUID.init)
        if useCloud {
            mergeCloud()
            NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: cloud, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.mergeCloud(); self?.persist() }
            }
            cloud.synchronize()
        }
    }

    // MARK: правки

    @discardableResult
    func create(name: String, base: PfBase) -> MyPortfolio {
        let p = MyPortfolio(name: name.trimmingCharacters(in: .whitespacesAndNewlines), baseCurrency: base)
        all.append(p)
        selectedId = p.id
        persist()
        return p
    }

    func update(_ portfolio: MyPortfolio) {
        guard let i = all.firstIndex(where: { $0.id == portfolio.id }) else { return }
        var p = portfolio
        p.updated = Date().timeIntervalSince1970
        all[i] = p
        persist()
    }

    func delete(_ id: UUID) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].deleted = true
        all[i].transactions = []
        all[i].updated = Date().timeIntervalSince1970
        if selectedId == id { selectedId = portfolios.first?.id }
        persist()
    }

    func upsert(_ txn: MyPortfolio.Transaction, in portfolioId: UUID) {
        guard var p = all.first(where: { $0.id == portfolioId }) else { return }
        if let i = p.transactions.firstIndex(where: { $0.id == txn.id }) { p.transactions[i] = txn } else { p.transactions.append(txn) }
        update(p)
    }

    func deleteTransactions(_ ids: Set<UUID>, in portfolioId: UUID) {
        guard var p = all.first(where: { $0.id == portfolioId }) else { return }
        p.transactions.removeAll { ids.contains($0.id) }
        update(p)
    }

    func add(_ txns: [MyPortfolio.Transaction], to portfolioId: UUID) {
        guard var p = all.first(where: { $0.id == portfolioId }) else { return }
        p.transactions.append(contentsOf: txns)
        update(p)
    }

    // MARK: внутреннее

    private func mergeCloud() {
        guard useCloud, let data = cloud.data(forKey: Self.kvsKey),
              let remote = try? JSONDecoder().decode([MyPortfolio].self, from: data) else { return }
        all = Self.merge(local: all, remote: remote)
    }

    /// Слияние двух копий: по каждому id побеждает более поздняя правка.
    nonisolated static func merge(local: [MyPortfolio], remote: [MyPortfolio]) -> [MyPortfolio] {
        var result = local
        for r in remote {
            if let i = result.firstIndex(where: { $0.id == r.id }) {
                if r.updated > result[i].updated { result[i] = r }
            } else {
                result.append(r)
            }
        }
        return result
    }

    private func persist() {
        let cutoff = Date().timeIntervalSince1970 - Self.tombstoneAge
        all = all.filter { !$0.deleted || $0.updated > cutoff }
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(all) {
            try? data.write(to: fileURL, options: .atomic)
            if useCloud {
                if data.count <= Self.kvsLimit {
                    cloud.set(data, forKey: Self.kvsKey)
                    cloud.synchronize()
                    cloudSkipped = false
                } else {
                    cloudSkipped = true
                }
            }
        }
    }
}
