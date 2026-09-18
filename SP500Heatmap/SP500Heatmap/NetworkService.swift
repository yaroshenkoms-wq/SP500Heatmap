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
}
