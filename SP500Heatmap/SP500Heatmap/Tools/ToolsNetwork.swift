import Foundation

// MARK: /api/v1/financials/{ticker}

struct FinancialPeriod: Decodable, Identifiable {
    let period: String
    let revenue: Double?
    let grossProfit: Double?
    let operatingIncome: Double?
    let netIncome: Double?
    let eps: Double?
    let freeCashFlow: Double?
    let totalDebt: Double?
    let cash: Double?
    let sharesOutstanding: Double?
    var id: String { period }
}

struct FinancialRatios: Decodable {
    let grossMargin: Double?
    let operatingMargin: Double?
    let netMargin: Double?
    let roe: Double?
    let roa: Double?
    let debtToEquity: Double?
    let currentRatio: Double?
    let evToEbitda: Double?
    let peg: Double?
    let priceToFcf: Double?
}

struct AnalystInfo: Decodable {
    let recommendation: String?
    let count: Int?
    let targetMean: Double?
    let targetHigh: Double?
    let targetLow: Double?
    let currentPrice: Double?
}

struct FinancialHolder: Decodable, Identifiable {
    let name: String
    let weightPct: Double?
    let changeQ: String?
    let reportDate: String?
    var id: String { name }
}

struct Financials: Decodable {
    let ticker: String?
    let currency: String?
    let annual: [FinancialPeriod]
    let quarterly: [FinancialPeriod]
    let ratios: FinancialRatios?
    let analysts: AnalystInfo?
    let holders: [FinancialHolder]

    enum CodingKeys: String, CodingKey { case ticker, currency, annual, quarterly, ratios, analysts, holders }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ticker = try? c.decodeIfPresent(String.self, forKey: .ticker)
        currency = try? c.decodeIfPresent(String.self, forKey: .currency)
        annual = ((try? c.decodeIfPresent([FinancialPeriod].self, forKey: .annual)) ?? nil)?.sorted { $0.period < $1.period } ?? []
        quarterly = ((try? c.decodeIfPresent([FinancialPeriod].self, forKey: .quarterly)) ?? nil)?.sorted { $0.period < $1.period } ?? []
        ratios = (try? c.decodeIfPresent(FinancialRatios.self, forKey: .ratios)) ?? nil
        analysts = (try? c.decodeIfPresent(AnalystInfo.self, forKey: .analysts)) ?? nil
        holders = ((try? c.decodeIfPresent([FinancialHolder].self, forKey: .holders)) ?? nil) ?? []
    }

    var isEmpty: Bool {
        annual.isEmpty && quarterly.isEmpty && ratios == nil && analysts == nil && holders.isEmpty
    }
}

// MARK: /api/v1/calendar

struct CalendarEvent: Decodable, Identifiable {
    struct Detail: Decodable {
        let epsEstimate: Double?
        let dividendRate: Double?
    }
    let date: String
    let type: String
    let ticker: String
    let name: String?
    let index: String?
    let detail: Detail?
    var id: String { "\(date)|\(type)|\(ticker)" }
}

private struct CalendarResponse: Decodable { let events: [CalendarEvent] }

// MARK: /api/v1/screener

struct ScreenerRow: Decodable, Identifiable {
    let ticker: String
    let name: String?
    let index: String?
    let sector: String?
    let capUSD: Double?
    let change: Double?
    let pe: Double?
    let ps: Double?
    let pb: Double?
    let divYield: Double?
    let beta: Double?
    let revGrowth: Double?
    let pos52w: Double?
    let relVolume: Double?
    var id: String { ticker + "|" + (index ?? "") }
}

struct ScreenerResult: Decodable {
    let total: Int
    let rows: [ScreenerRow]
}

extension NetworkService {
    func fetchFinancials(ticker: String) async throws -> Financials {
        let encoded = ticker.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ticker
        guard let url = URL(string: "\(Config.baseURL)/api/v1/financials/\(encoded)") else { throw NetworkError.invalidURL }
        return try JSONDecoder().decode(Financials.self, from: try await fetchData(url, timeout: 30))
    }

    func fetchCalendar(from: String, to: String, index: String, tickers: [String]) async throws -> [CalendarEvent] {
        guard var comps = URLComponents(string: "\(Config.baseURL)/api/v1/calendar") else { throw NetworkError.invalidURL }
        var items = [URLQueryItem(name: "from", value: from), URLQueryItem(name: "to", value: to),
                     URLQueryItem(name: "index", value: index)]
        if !tickers.isEmpty { items.append(URLQueryItem(name: "tickers", value: tickers.joined(separator: ","))) }
        comps.queryItems = items
        guard let url = comps.url else { throw NetworkError.invalidURL }
        let data = try await fetchData(url, timeout: 30)
        return try JSONDecoder().decode(CalendarResponse.self, from: data).events
    }

    func fetchScreener(_ query: [URLQueryItem]) async throws -> ScreenerResult {
        guard var comps = URLComponents(string: "\(Config.baseURL)/api/v1/screener") else { throw NetworkError.invalidURL }
        comps.queryItems = query
        guard let url = comps.url else { throw NetworkError.invalidURL }
        return try JSONDecoder().decode(ScreenerResult.self, from: try await fetchData(url, timeout: 30))
    }
}
