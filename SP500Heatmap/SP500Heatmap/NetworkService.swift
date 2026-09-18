import Foundation

class NetworkService: ObservableObject {
    static let shared = NetworkService()
    
    private let baseURL: String
    
    init() {
        self.baseURL = Config.baseURL
    }
    
    func fetchMarketHierarchy() async throws -> [Sector] {
        guard let url = URL(string: "\(baseURL)/api/v1/market-hierarchy") else {
            throw NetworkError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        let sectors = try JSONDecoder().decode([Sector].self, from: data)
        return sectors
    }

    func fetchHistory(ticker: String) async throws -> [DailyClose] {
        guard let url = URL(string: "\(baseURL)/api/v1/history/\(ticker)") else {
            throw NetworkError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([DailyClose].self, from: data)
    }

    func fetchPerformance() async throws -> [String: PerformanceMetrics] {
        guard let url = URL(string: "\(baseURL)/api/v1/performance") else {
            throw NetworkError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)
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
