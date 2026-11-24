import Foundation
import UserNotifications

/// Одно оповещение по бумаге: цена, дневное движение, напоминание о отчётности или дивидендах.
struct StockAlert: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case priceAbove, priceBelow, dailyMove, earnings, exDividend }

    let id: String
    let kind: Kind
    let ticker: String
    let name: String
    let indexId: String
    /// Уровень цены или порог в процентах (для напоминаний не нужен).
    var value: Double?
    /// День события yyyy-MM-dd (только для напоминаний).
    var eventDay: String?
    /// Когда сработает локальное уведомление (только для напоминаний).
    var fireDate: Date?
    /// День данных, за который дневное движение уже было отправлено.
    var lastFiredDay: String?
    let createdAt: Date

    var isReminder: Bool { kind == .earnings || kind == .exDividend }
}

extension Notification.Name {
    static let stockAlertsChanged = Notification.Name("stockAlertsChanged")
}

/// Хранилище оповещений в App Group (JSON). Работает и из фоновой задачи.
enum AlertStore {
    private static let key = "stockAlerts"

    static func load() -> [StockAlert] {
        guard let data = AppGroup.defaults.data(forKey: key),
              let items = try? JSONDecoder().decode([StockAlert].self, from: data) else { return [] }
        // Прошедшие напоминания не показываем.
        let now = Date()
        return items.filter { !($0.isReminder && ($0.fireDate ?? .distantFuture) < now) }
    }

    static func save(_ items: [StockAlert]) {
        if let data = try? JSONEncoder().encode(items) {
            AppGroup.defaults.set(data, forKey: key)
        }
        NotificationCenter.default.post(name: .stockAlertsChanged, object: nil)
    }

    static var hasPriceAlerts: Bool { load().contains { !$0.isReminder } }

    static func add(_ alert: StockAlert) {
        var items = load()
        // Одно напоминание каждого вида на бумагу.
        if alert.isReminder { items.removeAll { $0.ticker == alert.ticker && $0.kind == alert.kind } }
        items.append(alert)
        save(items)
        if alert.isReminder { Task { await ReminderScheduler.schedule(alert) } }
        AlertManager.scheduleRefresh()
    }

    static func remove(id: String) {
        var items = load()
        guard let alert = items.first(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        save(items)
        if alert.isReminder { ReminderScheduler.cancel(alert) }
        AlertManager.scheduleRefresh()
    }

    static func reminder(ticker: String, kind: StockAlert.Kind) -> StockAlert? {
        load().first { $0.ticker == ticker && $0.kind == kind }
    }

    static func update(_ alert: StockAlert) {
        var items = load()
        guard let i = items.firstIndex(where: { $0.id == alert.id }) else { return }
        items[i] = alert
        save(items)
    }
}

/// Напоминания «за день до»: точное локальное уведомление на 09:00, не зависит от фона.
enum ReminderScheduler {
    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// 09:00 по местному времени за день до события; nil, если этот момент уже прошёл или дата не читается.
    static func fireDate(forEventDay iso: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard let utc = parser.date(from: String(iso.prefix(10))) else { return nil }
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = utcCal.dateComponents([.year, .month, .day], from: utc)
        var comps = DateComponents()
        comps.year = parts.year; comps.month = parts.month; comps.day = parts.day
        guard let eventLocal = calendar.date(from: comps),
              let before = calendar.date(byAdding: .day, value: -1, to: eventLocal),
              let fire = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: before),
              fire > now else { return nil }
        return fire
    }

    static func identifier(_ alert: StockAlert) -> String { "reminder-\(alert.id)" }

    static func schedule(_ alert: StockAlert) async {
        guard let fire = alert.fireDate else { return }
        let content = UNMutableNotificationContent()
        let day = alert.eventDay.flatMap { parser.date(from: String($0.prefix(10))) }?
            .formatted(.dateTime.day().month(.abbreviated).locale(AppLanguage.locale)) ?? ""
        switch alert.kind {
        case .earnings:
            content.title = AppLanguage.string("Earnings tomorrow")
            content.body = String(format: AppLanguage.string("%@ reports earnings on %@"), alert.name, day)
        default:
            content.title = AppLanguage.string("Ex-dividend tomorrow")
            content.body = String(format: AppLanguage.string("%@ goes ex-dividend on %@"), alert.name, day)
        }
        content.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: identifier(alert), content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func cancel(_ alert: StockAlert) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier(alert)])
    }

    /// Если сервер сменил дату события, переносим напоминание.
    static func sync(ticker: String, kind: StockAlert.Kind, eventDay: String?) async {
        guard var existing = AlertStore.reminder(ticker: ticker, kind: kind),
              let eventDay, existing.eventDay != String(eventDay.prefix(10)) else { return }
        cancel(existing)
        existing.eventDay = String(eventDay.prefix(10))
        existing.fireDate = fireDate(forEventDay: eventDay)
        if existing.fireDate == nil {
            AlertStore.remove(id: existing.id)
        } else {
            AlertStore.update(existing)
            await schedule(existing)
        }
    }
}

/// Проверка ценовых оповещений в фоне (вместе с обновлением индексов).
enum PriceAlertChecker {
    static func run() async -> Bool {
        var items = AlertStore.load().filter { !$0.isReminder }
        guard !items.isEmpty else { return true }
        var ok = true
        var changed = false
        var performance: [String: [String: PerformanceMetrics]] = [:]
        var prices: [String: Double] = [:]
        let day = todayKey()

        for alert in items {
            switch alert.kind {
            case .priceAbove, .priceBelow:
                guard let level = alert.value else { continue }
                if prices[alert.ticker] == nil { prices[alert.ticker] = await lastPrice(alert.ticker) }
                guard let price = prices[alert.ticker] else { ok = false; continue }
                let hit = alert.kind == .priceAbove ? price >= level : price <= level
                guard hit else { continue }
                let key = alert.kind == .priceAbove ? "%@ is at or above %@" : "%@ is at or below %@"
                let body = String(format: AppLanguage.string(key), alert.name,
                                  formatDecimal(level, fractionDigits: level >= 100 ? 0 : 2))
                await post(id: "price-\(alert.id)", title: AppLanguage.string("Price alert"), body: body)
                items.removeAll { $0.id == alert.id }
                changed = true
            case .dailyMove:
                guard let threshold = alert.value, alert.lastFiredDay != day else { continue }
                if performance[alert.indexId] == nil {
                    performance[alert.indexId] = try? await NetworkService.shared
                        .fetchPerformance(index: alert.indexId == "sp500" ? nil : alert.indexId)
                }
                guard let move = performance[alert.indexId]?[alert.ticker]?.day1 else { continue }
                guard abs(move) >= threshold else { continue }
                let body = String(format: AppLanguage.string("%@: %@ in the latest session"),
                                  alert.name, sharedPercent(move, locale: AppLanguage.locale))
                await post(id: "move-\(alert.id)-\(day)", title: AppLanguage.string("Price alert"), body: body)
                if let i = items.firstIndex(where: { $0.id == alert.id }) {
                    items[i].lastFiredDay = day
                    changed = true
                }
            default: break
            }
        }
        if changed {
            // Сохраняем вместе с напоминаниями, которых проверка не касается.
            let reminders = AlertStore.load().filter { $0.isReminder }
            AlertStore.save(items + reminders)
        }
        return ok
    }

    private static func todayKey() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    private static func lastPrice(_ ticker: String) async -> Double? {
        if let series = try? await NetworkService.shared.fetchOHLC(ticker: ticker, range: "1m"), let c = series.bars.last?.c {
            return c
        }
        return (try? await NetworkService.shared.fetchHistory(ticker: ticker))?.last?.close
    }

    private static func post(id: String, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        try? await UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
