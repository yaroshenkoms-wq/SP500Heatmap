import SwiftUI

/// All filters of one screen; Codable so named screens can be saved in the App Group.
struct ScreenerFilters: Codable, Equatable {
    var preset: String?
    var index: String = "all"
    var sector: String = ""
    var cap: String = "any"        // any | mega | large | mid | small
    var peMin: Double?
    var peMax: Double?
    var psMax: Double?
    var pbMax: Double?
    var divMin: Double?
    var betaMax: Double?
    var revGrowthMin: Double?
    var period: String = "1d"
    var chgMin: Double?
    var chgMax: Double?
    var pos52Min: Double?
    var pos52Max: Double?
    var relVolMin: Double?
    var sort: String = "capUSD"
    var ascending = false

    static let presets = ["gainers", "losers", "active", "dividend", "value", "highs52", "lows52"]
    static let periods = ["1d", "3d", "7d", "30d", "180d", "1y", "3y", "5y", "10y"]
    static let sectors = ["Technology", "Healthcare", "Financial Services", "Consumer Cyclical", "Communication Services",
                          "Industrials", "Consumer Defensive", "Energy", "Utilities", "Real Estate", "Basic Materials"]
    static let sortFields = ["capUSD", "change", "pe", "ps", "pb", "divYield", "beta", "revGrowth", "pos52w", "relVolume", "ticker"]

    static func defaultSort(for preset: String) -> (String, Bool) {
        switch preset {
        case "gainers": return ("change", false)
        case "losers": return ("change", true)
        case "active": return ("relVolume", false)
        case "dividend": return ("divYield", false)
        case "value": return ("pe", true)
        case "highs52": return ("pos52w", false)
        case "lows52": return ("pos52w", true)
        default: return ("capUSD", false)
        }
    }

    /// Number of filters the user set on top of the preset (for the badge on the filter button).
    var activeCount: Int {
        var n = 0
        if index != "all" { n += 1 }
        if !sector.isEmpty { n += 1 }
        if cap != "any" { n += 1 }
        for v in [peMin, peMax, psMax, pbMax, divMin, betaMax, revGrowthMin, chgMin, chgMax, pos52Min, pos52Max, relVolMin] where v != nil { n += 1 }
        return n
    }

    func query() -> [URLQueryItem] {
        var q: [URLQueryItem] = [URLQueryItem(name: "index", value: index)]
        func add(_ k: String, _ v: Double?) { if let v { q.append(URLQueryItem(name: k, value: String(v))) } }
        if !sector.isEmpty { q.append(URLQueryItem(name: "sector", value: sector)) }
        switch cap {
        case "mega": add("minCap", 200e9)
        case "large": add("minCap", 10e9); add("maxCap", 200e9)
        case "mid": add("minCap", 2e9); add("maxCap", 10e9)
        case "small": add("maxCap", 2e9)
        default: break
        }
        add("peMin", peMin); add("peMax", peMax); add("psMax", psMax); add("pbMax", pbMax)
        add("divMin", divMin); add("betaMax", betaMax); add("revGrowthMin", revGrowthMin)
        q.append(URLQueryItem(name: "period", value: period))
        add("chgMin", chgMin); add("chgMax", chgMax)
        add("pos52Min", pos52Min); add("pos52Max", pos52Max); add("relVolMin", relVolMin)
        q.append(URLQueryItem(name: "sort", value: sort))
        q.append(URLQueryItem(name: "order", value: ascending ? "asc" : "desc"))
        q.append(URLQueryItem(name: "limit", value: "100"))
        if let preset { q.append(URLQueryItem(name: "preset", value: preset)) }
        return q
    }
}

struct SavedScreen: Codable, Identifiable {
    var id = UUID()
    var name: String
    var filters: ScreenerFilters
}

/// Saved named screens, stored in the App Group.
@MainActor
final class SavedScreensStore: ObservableObject {
    static let shared = SavedScreensStore()
    private let key = "savedScreens"
    @Published private(set) var screens: [SavedScreen] = []

    private init() {
        if let data = AppGroup.defaults.data(forKey: key),
           let list = try? JSONDecoder().decode([SavedScreen].self, from: data) { screens = list }
    }

    func save(name: String, filters: ScreenerFilters) {
        screens.removeAll { $0.name == name }
        screens.append(SavedScreen(name: name, filters: filters))
        persist()
    }

    func delete(_ id: UUID) {
        screens.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(screens) { AppGroup.defaults.set(data, forKey: key) }
    }
}
