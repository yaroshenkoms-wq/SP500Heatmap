import Combine
import CryptoKit
import Foundation
import UIKit
import UserNotifications

/// Делегат приложения: токен APNs и нажатия на уведомления.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in PushManager.shared.didRegister(token: token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Нет разрешения или нет сети — остаётся локальный режим.
        print("Remote notification registration failed: \(error.localizedDescription)")
    }

    // Уведомление пришло, пока приложение открыто: показываем баннер.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    // Нажали на уведомление: открываем компанию или индекс.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        await MainActor.run { DeepLinkRouter.shared.handle(userInfo: info) }
    }
}

/// Ссылка из уведомления. ContentView ловит `url` и открывает нужный экран.
@MainActor
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()
    @Published var url: URL?

    /// Ключи полезной нагрузки читаем терпимо: url / deeplink, иначе ticker, иначе indexId.
    func handle(userInfo: [AnyHashable: Any]) {
        func text(_ keys: [String]) -> String? {
            for key in keys {
                if let v = userInfo[key] as? String, !v.isEmpty { return v }
                if let aps = userInfo["data"] as? [String: Any], let v = aps[key] as? String, !v.isEmpty { return v }
            }
            return nil
        }
        if let raw = text(["url", "deeplink", "deepLink"]), let u = URL(string: raw), u.scheme == "sp500heatmap" {
            url = u
        } else if text(["type"]) == "index_move", let id = text(["ticker", "indexId"]),
                  let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            url = URL(string: "sp500heatmap://index/\(encoded)")
        } else if let ticker = text(["ticker", "symbol"]),
                  let encoded = ticker.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            url = URL(string: "sp500heatmap://company/\(encoded)")
        } else if let index = text(["indexId", "index_id", "index"]),
                  let encoded = index.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            url = URL(string: "sp500heatmap://index/\(encoded)")
        }
    }
}

/// Состояние push для экрана настроек.
enum PushStatus { case checking, active, localMode }

/// Push-уведомления: регистрация токена на сервере, синхронизация правил, проверка, включён ли push на сервере.
/// Если регистрация токена не прошла, работают локальные оповещения.
@MainActor
final class PushManager: ObservableObject {
    static let shared = PushManager()

    static let newsKey = "alertNewsEnabled"
    nonisolated private static let tokenKey = "pushDeviceToken"
    nonisolated private static let registeredKey = "pushRegisteredToken"
    nonisolated private static let activeKey = "pushServerActive"
    nonisolated private static let activeDateKey = "pushServerActiveDate"
    nonisolated private static let rulesHashKey = "pushRulesHash"

    @Published private(set) var status: PushStatus = .checking

    private var started = false
    private var cancellables = Set<AnyCancellable>()
    private var syncTask: Task<Void, Never>?
    private var lastLanguage = ""
    private let defaults = UserDefaults.standard

    private var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    private init() {}

    /// Токен устройства (hex), если iOS его уже выдала.
    var token: String? { defaults.string(forKey: Self.tokenKey) }

    /// Сервер ведёт push для этого устройства: тогда локальные дубли не нужны.
    /// Читается и из фоновой задачи, поэтому не привязано к главному потоку.
    nonisolated static var serverActiveCached: Bool {
        let d = UserDefaults.standard
        guard d.bool(forKey: activeKey), d.string(forKey: registeredKey) != nil else { return false }
        // Если статус давно не проверяли, возвращаемся к локальному режиму.
        let date = d.object(forKey: activeDateKey) as? Date ?? .distantPast
        return Date().timeIntervalSince(date) < 3 * 24 * 3600
    }

    // MARK: Запуск

    func start() {
        guard !started else { return }
        started = true
        lastLanguage = AppLanguage.effectiveCode
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .merge(with: NotificationCenter.default.publisher(for: .stockAlertsChanged))
            .debounce(for: .seconds(1.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &cancellables)
        Task { await refresh() }
    }

    /// При запуске и возврате в приложение: статус сервера, токен, правила.
    func refresh() async {
        await updateServerStatus()
        await registerForRemoteIfAuthorized()
        if token != nil { await registerOnServer() }
    }

    /// Вызывается, когда человек включил уведомления (после разрешения).
    func permissionGranted() {
        Task { await registerForRemoteIfAuthorized() }
    }

    private func settingsChanged() {
        let language = AppLanguage.effectiveCode
        if language != lastLanguage {
            lastLanguage = language
            Task { await registerOnServer() }   // язык и часовой пояс обновляем при регистрации
        } else {
            scheduleRulesSync()
        }
    }

    // MARK: Регистрация

    private func registerForRemoteIfAuthorized() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        default: break
        }
    }

    func didRegister(token: String) {
        defaults.set(token, forKey: Self.tokenKey)
        Task { await registerOnServer() }
    }

    private func registerOnServer() async {
        guard let token else { return }
        let body: [String: Any] = ["token": token, "platform": "ios", "env": environment,
                                   "lang": AppLanguage.effectiveCode, "tz": TimeZone.current.identifier]
        let ok = await PushAPI.send("POST", "/api/v1/push/register", body: body)
        defaults.set(ok, forKey: Self.activeKey)
        defaults.set(Date(), forKey: Self.activeDateKey)
        if !ok { status = .localMode }
        if ok {
            defaults.set(token, forKey: Self.registeredKey)
            defaults.removeObject(forKey: Self.rulesHashKey)   // сервер мог потерять правила — отправим заново
            status = .active
            await syncRules()
        }
    }

    // MARK: Статус

    /// Отдельного эндпоинта статуса нет: push считается включённым, когда регистрация токена вернула 200.
    func updateServerStatus() async {
        status = Self.serverActiveCached ? .active : .localMode
    }

    /// Для фоновой задачи: есть ли зарегистрированный токен на сервере.
    nonisolated static func checkServerActive() async -> Bool { serverActiveCached }

    // MARK: Правила

    private func scheduleRulesSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.syncRules()
        }
    }

    /// Все правила оповещений одним списком. Напоминания о отчётности и дивидендах остаются локальными.
    func currentRules() -> [[String: Any]] {
        var rules: [[String: Any]] = []
        for alert in AlertStore.load() where !alert.isReminder {
            var rule: [String: Any] = ["id": "stock-\(alert.id)", "ticker": alert.ticker, "indexId": alert.indexId]
            switch alert.kind {
            case .priceAbove: rule["type"] = "price_above"
            case .priceBelow: rule["type"] = "price_below"
            case .dailyMove: rule["type"] = "day_move"
            default: continue
            }
            if let value = alert.value { rule["value"] = value }
            rules.append(rule)
        }
        if AlertManager.moveEnabled {
            for id in AlertManager.selectedIndices.sorted() {
                rules.append(["id": "index-\(id)", "type": "index_move", "indexId": id, "value": AlertManager.threshold])
            }
        }
        if AlertManager.summaryEnabled {
            rules.append(["id": "summary", "type": "daily_summary"])
        }
        if defaults.bool(forKey: Self.newsKey) {
            for item in FavoritesStore.shared.allItems.prefix(40) {
                rules.append(["id": "news-\(item.ticker)", "type": "news", "ticker": item.ticker, "indexId": item.indexId])
            }
        }
        return rules
    }

    func syncRules() async {
        guard let token, defaults.string(forKey: Self.registeredKey) == token else { return }
        let rules = currentRules()
        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]) else { return }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard defaults.string(forKey: Self.rulesHashKey) != hash else { return }
        let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? token
        if await PushAPI.send("PUT", "/api/v1/push/rules/\(encoded)", body: ["rules": rules]) {
            defaults.set(hash, forKey: Self.rulesHashKey)
        }
    }

    // MARK: Проверочное уведомление (локальное)

    func sendTestNotification() async {
        let content = UNMutableNotificationContent()
        content.title = AppLanguage.string("Test notification")
        content.body = AppLanguage.string("This is how your alerts will look.")
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        try? await UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: "test-\(UUID().uuidString)", content: content, trigger: trigger))
    }
}

/// Запросы к серверу push. Любая ошибка (в том числе 404 на старом сервере) — просто «нет».
enum PushAPI {
    private static var base: String { Config.baseURL }

    @discardableResult
    static func send(_ method: String, _ path: String, body: [String: Any]?) async -> Bool {
        guard let url = URL(string: base + path) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let code = (response as? HTTPURLResponse)?.statusCode else { return false }
        return (200..<300).contains(code)
    }
}
