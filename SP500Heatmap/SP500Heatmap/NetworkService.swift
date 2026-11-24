import Foundation

class NetworkService: ObservableObject {
    static let shared = NetworkService()
    
    private let baseURL: String
    
    init() {
        self.baseURL = Config.baseURL
    }
    
    // Builds an API URL; `index` is added only for non-S&P indices (nil = legacy request).
    private func apiURL(_ path: String, index: String?) throws -> URL {
        guard var components = URLComponents(string: "\(baseURL)\(path)") else {
            throw NetworkError.invalidURL
        }
        if let index {
            components.queryItems = [URLQueryItem(name: "index", value: index)]
        }
        guard let url = components.url else { throw NetworkError.invalidURL }
        return url
    }

    private func fetchData(_ url: URL, timeout: TimeInterval = 60) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NetworkError.noData
        }
        return data
    }

    func fetchIndices() async throws -> [IndexInfo] {
        let data = try await fetchData(try apiURL("/api/v1/indices", index: nil), timeout: 8)
        return try JSONDecoder().decode([IndexInfo].self, from: data)
    }

    func fetchWorldOverview() async throws -> WorldOverview {
        let data = try await fetchData(try apiURL("/api/v1/world-overview", index: nil), timeout: 15)
        return try JSONDecoder().decode(WorldOverview.self, from: data)
    }

    func fetchMarketHierarchy(index: String? = nil) async throws -> [Sector] {
        let data = try await fetchData(try apiURL("/api/v1/market-hierarchy", index: index))
        let sectors = try JSONDecoder().decode([Sector].self, from: data)
        return sectors
    }

    func fetchHistory(ticker: String) async throws -> [DailyClose] {
        // Tickers such as "SAN.MC" or "BRK-B" are safe, but encode anyway for symbols like "^X".
        let encoded = ticker.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ticker
        guard let url = URL(string: "\(baseURL)/api/v1/history/\(encoded)") else {
            throw NetworkError.invalidURL
        }

        let data = try await fetchData(url)
        return try JSONDecoder().decode([DailyClose].self, from: data)
    }

    func fetchMetrics(index: String) async throws -> [String: CompanyMetrics] {
        let data = try await fetchData(try apiURL("/api/v1/metrics", index: index), timeout: 30)
        return try JSONDecoder().decode([String: CompanyMetrics].self, from: data)
    }

    func fetchCompanyInfo(ticker: String) async throws -> CompanyInfo {
        let encoded = ticker.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ticker
        guard let url = URL(string: "\(baseURL)/api/v1/company/\(encoded)") else { throw NetworkError.invalidURL }
        let data = try await fetchData(url, timeout: 30)
        return try JSONDecoder().decode(CompanyInfo.self, from: data)
    }

    func fetchPerformance(index: String? = nil) async throws -> [String: PerformanceMetrics] {
        let data = try await fetchData(try apiURL("/api/v1/performance", index: index))
        return try JSONDecoder().decode([String: PerformanceMetrics].self, from: data)
    }
}

enum NetworkError: Error {
    case invalidURL
    case noData
    case decodingError
}

struct DailyClose: Codable {
    let date: String
    let close: Double
}

struct PerformanceMetrics: Codable {
    let return1M: Double?
    let return6M: Double?
    let returnYTD: Double?
    let return1Y: Double?
    let day1: Double?
    let day3: Double?
    let day7: Double?
    let day30: Double?
    let day180: Double?
    let year1: Double?

    enum CodingKeys: String, CodingKey {
        case return1M, return6M, returnYTD, return1Y
        case day1 = "1d"
        case day3 = "3d"
        case day7 = "7d"
        case day30 = "30d"
        case day180 = "180d"
        case year1 = "1y"
    }

    // Looks up a return by the same period keys PeriodSwitchView uses ("SC" has
    // no historical value - callers should fall back to the live WebSocket price).
    func value(forPeriod period: String) -> Double? {
        switch period {
        case "1d": return day1
        case "3d": return day3
        case "7d": return day7
        case "30d": return day30
        case "180d": return day180
        case "1y": return year1
        default: return nil
        }
    }
}
