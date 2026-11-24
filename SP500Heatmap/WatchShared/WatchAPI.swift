import Foundation

// Сеть часов: прямой URLSession на тот же сервер, что у iPhone-приложения.
// BASE_URL берётся из Info.plist (Debug и Release у часов — продакшен: часы не видят localhost Mac).

enum WatchConfig {
    static let baseURL: String = {
        (Bundle.main.object(forInfoDictionaryKey: "BASE_URL") as? String) ?? "https://217-160-93-254.sslip.io/sp500"
    }()
}

struct WIndex: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let country: String?
    let currency: String?
    let capUSD: Double?
    let changes: [String: Double?]?

    func change(_ period: String) -> Double? {
        guard let v = changes?[period] else { return nil }
        return v
    }
    var flag: String { countryFlag(country) }

    static func == (a: WIndex, b: WIndex) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct WRegion: Decodable, Identifiable {
    let id: String
    let indices: [WIndex]
}

struct WOverview: Decodable {
    let asOf: String?
    let regions: [WRegion]
    var allIndices: [WIndex] { regions.flatMap(\.indices) }
}

struct WCompany: Identifiable, Hashable {
    let ticker: String
    let name: String
    let marketCap: Double
    var id: String { ticker }
}

struct WSector: Identifiable {
    let id: String
    let name: String
    let companies: [WCompany]
    var cap: Double { companies.reduce(0) { $0 + $1.marketCap } }
}

private struct HSector: Decodable {
    struct Sub: Decodable {
        struct Co: Decodable { let ticker: String; let name: String; let marketCap: Double? }
        let companies: [Co]
    }
    let id: String
    let name: String
    let subsectors: [Sub]
}

enum WatchAPI {
    static func get(_ path: String, timeout: TimeInterval = 20) async throws -> Data {
        guard let url = URL(string: WatchConfig.baseURL + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func query(_ index: String) -> String {
        index == "sp500" ? "" : "?index=\(index.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? index)"
    }

    static func overview() async throws -> WOverview {
        try JSONDecoder().decode(WOverview.self, from: try await get("/api/v1/world-overview", timeout: 15))
    }

    /// Изменения всех бумаг индекса по периодам: тикер → период → %.
    static func performance(index: String) async throws -> [String: [String: Double?]] {
        try JSONDecoder().decode([String: [String: Double?]].self,
                                 from: try await get("/api/v1/performance" + query(index), timeout: 30))
    }

    static func sectors(index: String) async throws -> [WSector] {
        let raw = try JSONDecoder().decode([HSector].self,
                                           from: try await get("/api/v1/market-hierarchy" + query(index), timeout: 30))
        return raw.map { s in
            WSector(id: s.id, name: s.name, companies: s.subsectors.flatMap(\.companies).map {
                WCompany(ticker: $0.ticker, name: $0.name, marketCap: $0.marketCap ?? 0)
            })
        }
    }

    struct Close: Decodable { let date: String; let close: Double }

    /// Дневные закрытия (~14 месяцев).
    static func closes(ticker: String) async throws -> [Double] {
        let encoded = ticker.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ticker
        let rows = try JSONDecoder().decode([Close].self, from: try await get("/api/v1/history/\(encoded)", timeout: 20))
        return rows.map(\.close)
    }
}

/// Мелкий кэш обзора на диске: complication и приложение показывают данные, когда сети нет.
enum WatchCache {
    private static var defaults: UserDefaults { UserDefaults(suiteName: AppGroup.id) ?? .standard }
    static func saveOverview(_ data: Data) { defaults.set(data, forKey: "watchOverview") }
    static func loadOverview() -> WOverview? {
        guard let data = defaults.data(forKey: "watchOverview") else { return nil }
        return try? JSONDecoder().decode(WOverview.self, from: data)
    }

    /// Свежий обзор; при ошибке — последний сохранённый.
    static func overview() async -> WOverview? {
        if let data = try? await WatchAPI.get("/api/v1/world-overview", timeout: 15),
           let fresh = try? JSONDecoder().decode(WOverview.self, from: data),
           fresh.regions.contains(where: { !$0.indices.isEmpty }) {
            saveOverview(data)
            return fresh
        }
        return loadOverview()
    }
}
