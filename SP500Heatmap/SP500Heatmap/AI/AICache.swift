import Foundation

/// Кэш обзоров в App Group: один результат на объект, день и язык. Старые дни удаляются.
enum AICache {
    private static let storeKey = "ai.insights.v1"

    static func day(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func key(kind: AIFacts.Kind, subject: String, language: String, date: Date = Date()) -> String {
        "\(day(date))|\(kind.rawValue)|\(subject)|\(language)"
    }

    private static func load() -> [String: Data] {
        AppGroup.defaults.dictionary(forKey: storeKey) as? [String: Data] ?? [:]
    }

    static func get(_ key: String) -> AIInsight? {
        guard let data = load()[key] else { return nil }
        return try? JSONDecoder().decode(AIInsight.self, from: data)
    }

    static func set(_ insight: AIInsight, for key: String) {
        let today = day()
        var all = load().filter { $0.key.hasPrefix(today + "|") }
        if let data = try? JSONEncoder().encode(insight) { all[key] = data }
        // Не растём бесконечно: держим не больше 60 записей за день.
        if all.count > 60, let drop = all.keys.sorted().first { all[drop] = nil }
        AppGroup.defaults.set(all, forKey: storeKey)
    }
}
