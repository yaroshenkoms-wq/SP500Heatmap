import BackgroundTasks
import Foundation
import UserNotifications

/// Локальные уведомления без push-сервера. Раз в какое-то время iOS будит приложение
/// (BGAppRefreshTask), оно скачивает world-overview, сравнивает с порогом и, если нужно,
/// показывает уведомление. Когда именно iOS разбудит приложение, решает система, поэтому
/// уведомления могут приходить с задержкой, а иногда не приходить вовсе.
enum AlertManager {
    static let taskId = "com.maximyaroshenko.SP500Heatmap2.refresh"

    static let moveKey = "alertMoveEnabled"
    static let thresholdKey = "alertThreshold"
    static let indicesKey = "alertIndices"
    static let summaryKey = "alertSummaryEnabled"
    private static let sentKey = "alertSentKeys"

    static let defaultIndices = ["sp500", "ibex35", "eurostoxx50"]
    static let defaultThreshold = 2.0

    private static var defaults: UserDefaults { .standard }

    static var moveEnabled: Bool { defaults.bool(forKey: moveKey) }
    static var summaryEnabled: Bool { defaults.bool(forKey: summaryKey) }
    static var threshold: Double {
        let value = defaults.double(forKey: thresholdKey)
        return value > 0 ? value : defaultThreshold
    }
    static var selectedIndices: [String] {
        guard let csv = defaults.string(forKey: indicesKey) else { return defaultIndices }
        return csv.split(separator: ",").map(String.init)
    }

    // MARK: Фоновая задача

    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            handle(task)
        }
    }

    static func scheduleRefresh() {
        guard moveEnabled || summaryEnabled || AlertStore.hasPriceAlerts else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskId)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: taskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        scheduleRefresh()
        let work = Task {
            let ok = await check()
            task.setTaskCompleted(success: ok)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// Разрешение спрашиваем только когда человек включает переключатель.
    static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        default:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }

    // MARK: Проверка

    @discardableResult
    static func check() async -> Bool {
        let priceOK = await PriceAlertChecker.run()
        guard moveEnabled || summaryEnabled else { return priceOK }
        guard let overview = try? await NetworkService.shared.fetchWorldOverview() else { return false }
        await MainActor.run { WidgetBridge.publish(overview: overview) }
        let indices = overview.regions.flatMap { $0.indices }
        let selected = selectedIndices
        var sent = Set(defaults.stringArray(forKey: sentKey) ?? [])
        let dataDay = overview.asOf ?? ""
        // Ключи старше одного дня данных не нужны.
        sent = sent.filter { $0.hasSuffix("|" + dataDay) }

        if moveEnabled {
            for index in indices where selected.contains(index.id) {
                guard let change = index.change(for: "1d"), abs(change) >= threshold else { continue }
                let key = "\(index.id)|\(dataDay)"
                guard !sent.contains(key) else { continue }
                sent.insert(key)
                let body = String(format: AppLanguage.string("%@: %@ in the latest session"),
                                  index.name, sharedPercent(change, locale: AppLanguage.locale))
                await post(id: key, title: AppLanguage.string("Index alert"), body: body)
            }
        }

        if summaryEnabled, let nyDay = usCloseDayIfReady(), nyDay == dataDay {
            let key = "summary|\(nyDay)"
            if !sent.contains(key) {
                let parts = selected.compactMap { id -> String? in
                    guard let index = indices.first(where: { $0.id == id }),
                          let change = index.change(for: "1d") else { return nil }
                    return "\(index.name) \(sharedPercent(change, locale: AppLanguage.locale))"
                }
                if !parts.isEmpty {
                    sent.insert(key)
                    await post(id: key, title: AppLanguage.string("Market summary"),
                               body: parts.joined(separator: " · "))
                }
            }
        }
        defaults.set(Array(sent), forKey: sentKey)
        return true
    }

    /// Дата в Нью-Йорке (yyyy-MM-dd), если биржа США уже закрылась (после 16:30 по Нью-Йорку).
    private static func usCloseDayIfReady() -> String? {
        var calendar = Calendar(identifier: .gregorian)
        guard let zone = TimeZone(identifier: "America/New_York") else { return nil }
        calendar.timeZone = zone
        let now = Date()
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        guard let hour = parts.hour, let minute = parts.minute,
              hour > 16 || (hour == 16 && minute >= 30) else { return nil }
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func post(id: String, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
