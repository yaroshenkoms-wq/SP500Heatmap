import ActivityKit
import Foundation

/// Live Activity «Рыночная сессия»: процент индекса и три самых заметных движения.
/// Формат ContentState совпадает с JSON сервера:
/// {"indexId","name","changePct","value"?,"movers":[{"ticker","changePct"}],"asOf"}.
/// Декодирование терпимое: нет поля — берём значение по умолчанию.
struct IndexActivityAttributes: ActivityAttributes {
    struct Mover: Codable, Hashable {
        var ticker: String
        var changePct: Double

        init(ticker: String, changePct: Double) {
            self.ticker = ticker
            self.changePct = changePct
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ticker = (try? c.decode(String.self, forKey: .ticker)) ?? ""
            changePct = TolerantNumber.decode(c, .changePct) ?? 0
        }
        enum CodingKeys: String, CodingKey { case ticker, changePct }
    }

    struct ContentState: Codable, Hashable {
        var indexId: String
        var name: String
        var changePct: Double
        var value: Double?
        var movers: [Mover]
        var asOf: String

        init(indexId: String, name: String, changePct: Double, value: Double? = nil,
             movers: [Mover] = [], asOf: String = "") {
            self.indexId = indexId
            self.name = name
            self.changePct = changePct
            self.value = value
            self.movers = movers
            self.asOf = asOf
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            indexId = (try? c.decode(String.self, forKey: .indexId)) ?? "sp500"
            name = (try? c.decode(String.self, forKey: .name)) ?? ""
            changePct = TolerantNumber.decode(c, .changePct) ?? 0
            value = TolerantNumber.decode(c, .value)
            movers = (try? c.decode([Mover].self, forKey: .movers)) ?? []
            if let s = try? c.decode(String.self, forKey: .asOf) {
                asOf = s
            } else if let n = TolerantNumber.decode(c, .asOf) {
                asOf = String(Int(n))
            } else {
                asOf = ""
            }
        }
        enum CodingKeys: String, CodingKey { case indexId, name, changePct, value, movers, asOf }
    }

    // Постоянная часть (нужна, когда сервер запускает активность по push-to-start токену).
    var indexId: String
    var name: String

    init(indexId: String, name: String) {
        self.indexId = indexId
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        indexId = (try? c.decode(String.self, forKey: .indexId)) ?? "sp500"
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
    }
    enum CodingKeys: String, CodingKey { case indexId, name }
}

/// Число, которое сервер мог прислать числом или строкой.
enum TolerantNumber {
    static func decode<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Double? {
        if let d = try? c.decode(Double.self, forKey: key) { return d }
        if let s = try? c.decode(String.self, forKey: key) { return Double(s) }
        return nil
    }
}
