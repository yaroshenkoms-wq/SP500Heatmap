import ActivityKit
import Combine
import Foundation

/// Live Activity «Market session» для выбранного индекса.
/// Без push: активность обновляется локально, пока приложение открыто (цены приходят по WebSocket).
/// С push (сервер настроен): сервер обновляет её сам, в том числе при закрытом приложении;
/// push-to-start токен позволяет серверу запускать её без участия человека (iOS 17.2+).
@MainActor
final class LiveActivityManager: ObservableObject {
    static let shared = LiveActivityManager()
    static let autoStartKey = "liveActivityAutoStart"
    static let autoIndexKey = "liveActivityIndexId"

    @Published private(set) var isRunning = false
    @Published private(set) var indexId: String?

    private var activity: Activity<IndexActivityAttributes>?
    private var companies: [Company] = []
    private var indexName = ""
    private var priceCancellable: AnyCancellable?
    private var observing = false
    private var startToken: String?
    private var lastUpdateToken: String?

    private init() {}

    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    // MARK: Запуск и остановка

    /// Кнопка «Follow live» на карте индекса.
    func start(indexId: String, name: String, companies: [Company]) async {
        guard areActivitiesEnabled else { return }
        if activity != nil { await stop() }
        self.indexId = indexId
        self.indexName = name
        self.companies = companies
        let state = makeState() ?? .init(indexId: indexId, name: name, changePct: 0)
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(20 * 60))
        let pushOK = PushManager.serverActiveCached
        do {
            activity = try Activity.request(attributes: IndexActivityAttributes(indexId: indexId, name: name),
                                            content: content, pushType: pushOK ? .token : nil)
        } catch {
            print("Live Activity start failed: \(error.localizedDescription)")
            self.indexId = nil
            return
        }
        isRunning = true
        observeActivity()
        priceCancellable = WebSocketManager.shared.$priceUpdates
            .throttle(for: .seconds(20), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in Task { await self?.pushLocalUpdate() } }
    }

    func stop() async {
        priceCancellable = nil
        let current = activity
        activity = nil
        isRunning = false
        indexId = nil
        if let current {
            await current.end(nil, dismissalPolicy: .immediate)
            if let token = lastUpdateToken {
                await PushAPI.send("DELETE", "/api/v1/push/liveactivity/\(token)", body: nil)
            }
        }
        lastUpdateToken = nil
    }

    /// Подхватываем активность, которую запустил сервер или прошлый запуск приложения.
    func attachExisting() {
        guard activity == nil, let existing = Activity<IndexActivityAttributes>.activities.first else { return }
        activity = existing
        indexId = existing.attributes.indexId
        indexName = existing.attributes.name
        isRunning = true
        observeActivity()
    }

    // MARK: Токены для push

    /// Вызывается при запуске: следим за push-to-start токеном (автозапуск в начале сессии США).
    func startObservingTokens() {
        guard !observing else { return }
        observing = true
        attachExisting()
        Task {
            for await data in Activity<IndexActivityAttributes>.pushToStartTokenUpdates {
                let token = data.map { String(format: "%02x", $0) }.joined()
                await MainActor.run { self.startToken = token }
                await self.syncAutoStart()
            }
        }
        Task {
            // Активность, запущенная сервером, появляется здесь: берём её токен обновлений.
            for await new in Activity<IndexActivityAttributes>.activityUpdates {
                await MainActor.run {
                    if self.activity == nil { self.activity = new; self.isRunning = true; self.indexId = new.attributes.indexId }
                    self.observeActivity(new)
                }
            }
        }
    }

    /// Включили или выключили автозапуск, либо сменился токен.
    func syncAutoStart() async {
        guard let token = startToken, PushManager.serverActiveCached else { return }
        let id = UserDefaults.standard.string(forKey: Self.autoIndexKey) ?? "sp500"
        if UserDefaults.standard.bool(forKey: Self.autoStartKey) {
            await PushAPI.send("POST", "/api/v1/push/liveactivity",
                               body: extra(["token": token, "kind": "start", "indexId": id, "tickers": topTickers()]))
        } else {
            await PushAPI.send("DELETE", "/api/v1/push/liveactivity/\(token)", body: nil)
        }
    }

    private func observeActivity(_ target: Activity<IndexActivityAttributes>? = nil) {
        guard let target = target ?? activity else { return }
        let id = target.id
        Task {
            for await data in target.pushTokenUpdates {
                let token = data.map { String(format: "%02x", $0) }.joined()
                await MainActor.run { self.lastUpdateToken = token }
                await PushAPI.send("POST", "/api/v1/push/liveactivity",
                                   body: self.extra(["token": token, "kind": "update",
                                                     "indexId": target.attributes.indexId, "tickers": self.topTickers()]))
            }
        }
        Task {
            for await state in target.activityStateUpdates where state == .ended || state == .dismissed {
                await MainActor.run {
                    if self.activity?.id == id {
                        self.activity = nil; self.isRunning = false; self.indexId = nil
                        self.priceCancellable = nil
                    }
                }
            }
        }
    }

    // MARK: Локальные обновления

    /// Сервер выбирает среду и язык по токену устройства; env и lang шлём тоже.
    private func extra(_ body: [String: Any]) -> [String: Any] {
        var b = body
        if let t = PushManager.shared.token { b["deviceToken"] = t }
        #if DEBUG
        b["env"] = "sandbox"
        #else
        b["env"] = "production"
        #endif
        b["lang"] = AppLanguage.effectiveCode
        return b
    }

    private func topTickers() -> [String] {
        companies.sorted { $0.marketCap > $1.marketCap }.prefix(10).map(\.ticker)
    }

    private func pushLocalUpdate() async {
        guard let activity, let state = makeState() else { return }
        await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(20 * 60)))
    }

    /// Процент индекса (взвешенный так же, как на карте) и три самых заметных движения по живым ценам.
    private func makeState() -> IndexActivityAttributes.ContentState? {
        guard let indexId else { return nil }
        let prices = WebSocketManager.shared.priceUpdates
        var weighted = 0.0, weights = 0.0
        var moves: [(ticker: String, change: Double, cap: Double)] = []
        for company in companies {
            guard let change = prices[company.ticker]?.changePercent else { continue }
            let w = startWeight(company.marketCap, change)
            weighted += change * w
            weights += w
            moves.append((company.ticker, change, company.marketCap))
        }
        guard weights > 0 else { return nil }
        // Движения среди крупнейших компаний: берём верхнюю половину по капитализации.
        let big = moves.sorted { $0.cap > $1.cap }.prefix(max(20, moves.count / 5))
        let top = big.sorted { abs($0.change) > abs($1.change) }.prefix(3)
            .map { IndexActivityAttributes.Mover(ticker: $0.ticker, changePct: $0.change) }
        return .init(indexId: indexId, name: indexName, changePct: weighted / weights, value: nil,
                     movers: Array(top), asOf: ISO8601DateFormatter().string(from: Date()))
    }
}
