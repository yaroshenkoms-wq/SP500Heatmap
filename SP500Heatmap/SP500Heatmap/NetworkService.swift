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

    // Своя сессия: запрос не висит дольше 45 с целиком (timeoutInterval считает только паузы),
    // и не ждёт сеть молча — при её отсутствии сразу ошибка, экран показывает «Повторить».
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 45
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    // Одна повторная попытка через секунду: сервер или сеть могли подвиснуть на мгновение.
    func fetchData(_ url: URL, timeout: TimeInterval = 30) async throws -> Data {
        do {
            return try await fetchOnce(url, timeout: timeout)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled { throw error }
            try await Task.sleep(for: .seconds(1))
            return try await fetchOnce(url, timeout: timeout)
        }
    }

    private func fetchOnce(_ url: URL, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await Self.session.data(for: request)
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

    /// Weekly closes for long ranges ("3y", "5y", "10y"); throws on an old server without ?range=.
    func fetchHistory(ticker: String, range: String) async throws -> [DailyClose] {
        let encoded = ticker.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ticker
        guard let url = URL(string: "\(baseURL)/api/v1/history/\(encoded)?range=\(range)") else {
            throw NetworkError.invalidURL
        }
        let data = try await fetchData(url, timeout: 30)
        return try JSONDecoder().decode([DailyClose].self, from: data)
    }

    /// Свечи для профессионального графика; бросает ошибку, если на сервере нет /ohlc.
    func fetchOHLC(ticker: String, range: String) async throws -> OHLCSeries {
        let encoded = ticker.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ticker
        guard let url = URL(string: "\(baseURL)/api/v1/ohlc/\(encoded)?range=\(range)") else {
            throw NetworkError.invalidURL
        }
        let data = try await fetchData(url, timeout: 30)
        return try JSONDecoder().decode(OHLCSeries.self, from: data)
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
    let year3: Double?
    let year5: Double?
    let year10: Double?

    enum CodingKeys: String, CodingKey {
        case return1M, return6M, returnYTD, return1Y
        case day1 = "1d"
        case day3 = "3d"
        case day7 = "7d"
        case day30 = "30d"
        case day180 = "180d"
        case year1 = "1y"
        case year3 = "3y"
        case year5 = "5y"
        case year10 = "10y"
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
        case "3y": return year3
        case "5y": return year5
        case "10y": return year10
        default: return nil
        }
    }
}

struct OHLCBar: Codable {
    let t: String
    let o: Double
    let h: Double
    let l: Double
    let c: Double
    let v: Double?
}

struct OHLCSeries: Codable {
    let ticker: String?
    let currency: String?
    let interval: String?
    let bars: [OHLCBar]
}
