import Foundation

// Личный портфель пользователя (не путать с Portfolios/ — там модельные портфели Udak).
// Названия типов начинаются с "Pf"/"My", чтобы не пересекаться с PortfolioStore/PortfolioEngine из Portfolios/.

enum PfTxType: String, Codable, CaseIterable, Identifiable {
    case buy, sell, dividend
    var id: String { rawValue }
}

enum PfBase: String, Codable, CaseIterable, Identifiable {
    case EUR, USD
    var id: String { rawValue }
}

/// Даты сделок — календарные дни "yyyy-MM-dd" в UTC (без часовых поясов, чтобы день не «съезжал»).
enum PfDay {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    static func string(_ date: Date) -> String { formatter.string(from: date) }
    static func date(_ day: String) -> Date? { formatter.date(from: day) }
    static var today: String { string(Date()) }
}

struct MyPortfolio: Codable, Identifiable, Equatable {
    struct Transaction: Codable, Identifiable, Equatable {
        var id: UUID = UUID()
        var ticker: String
        var indexId: String
        var type: PfTxType
        var date: Date
        /// Для дивиденда — число акций; price — дивиденд на акцию.
        var quantity: Double
        var price: Double
        var currency: String
        var fee: Double = 0

        var day: String { PfDay.string(date) }
        /// Сумма сделки в её валюте: покупка — расход с комиссией, продажа и дивиденд — приход за вычетом комиссии.
        var gross: Double { quantity * price }

        // Короткие ключи: лимит iCloud KVS всего 1 МБ.
        enum CodingKeys: String, CodingKey {
            case id = "i", ticker = "k", indexId = "x", type = "y", date = "d"
            case quantity = "q", price = "p", currency = "c", fee = "f"
        }

        init(id: UUID = UUID(), ticker: String, indexId: String, type: PfTxType, date: Date,
             quantity: Double, price: Double, currency: String, fee: Double = 0) {
            self.id = id; self.ticker = ticker; self.indexId = indexId; self.type = type; self.date = date
            self.quantity = quantity; self.price = price; self.currency = currency; self.fee = fee
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            ticker = try c.decode(String.self, forKey: .ticker)
            indexId = try c.decodeIfPresent(String.self, forKey: .indexId) ?? ""
            type = try c.decode(PfTxType.self, forKey: .type)
            let day = try c.decode(String.self, forKey: .date)
            guard let parsed = PfDay.date(day) else {
                throw DecodingError.dataCorruptedError(forKey: .date, in: c, debugDescription: "bad date")
            }
            date = parsed
            quantity = try c.decode(Double.self, forKey: .quantity)
            price = try c.decode(Double.self, forKey: .price)
            currency = try c.decode(String.self, forKey: .currency)
            fee = try c.decodeIfPresent(Double.self, forKey: .fee) ?? 0
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(ticker, forKey: .ticker)
            if !indexId.isEmpty { try c.encode(indexId, forKey: .indexId) }
            try c.encode(type, forKey: .type)
            try c.encode(day, forKey: .date)
            try c.encode(quantity, forKey: .quantity)
            try c.encode(price, forKey: .price)
            try c.encode(currency, forKey: .currency)
            if fee != 0 { try c.encode(fee, forKey: .fee) }
        }
    }

    var id: UUID = UUID()
    var name: String
    var baseCurrency: PfBase = .EUR
    var transactions: [Transaction] = []
    /// Индекс для сравнения на графике (id индекса сервера).
    var benchmark: String = "sp500"
    /// Время правки (для слияния с iCloud: побеждает более поздняя правка) и признак удаления.
    var updated: Double = Date().timeIntervalSince1970
    var deleted: Bool = false

    enum CodingKeys: String, CodingKey {
        case id = "i", name = "n", baseCurrency = "b", transactions = "x", benchmark = "m", updated = "u", deleted = "d"
    }

    init(id: UUID = UUID(), name: String, baseCurrency: PfBase = .EUR, transactions: [Transaction] = [],
         benchmark: String = "sp500") {
        self.id = id; self.name = name; self.baseCurrency = baseCurrency
        self.transactions = transactions; self.benchmark = benchmark
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        baseCurrency = try c.decodeIfPresent(PfBase.self, forKey: .baseCurrency) ?? .EUR
        transactions = try c.decodeIfPresent([Transaction].self, forKey: .transactions) ?? []
        benchmark = try c.decodeIfPresent(String.self, forKey: .benchmark) ?? "sp500"
        updated = try c.decodeIfPresent(Double.self, forKey: .updated) ?? 0
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(baseCurrency, forKey: .baseCurrency)
        try c.encode(transactions, forKey: .transactions)
        try c.encode(benchmark, forKey: .benchmark)
        try c.encode(updated, forKey: .updated)
        if deleted { try c.encode(true, forKey: .deleted) }
    }

    var tickers: [String] { Array(Set(transactions.map(\.ticker))).sorted() }
    var firstDay: String? { transactions.map(\.day).min() }
}
