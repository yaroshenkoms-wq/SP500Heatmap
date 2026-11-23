import Foundation
import SwiftUI

// One stock index as described by GET /api/v1/indices.
struct IndexInfo: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let region: String?
    let country: String?
    let currency: String?
    let live: Bool
    let count: Int?
    let historyThrough: String?

    static let sp500 = IndexInfo(id: "sp500", name: "S&P 500", region: "americas", country: "US",
                                 currency: "USD", live: true, count: nil, historyThrough: nil)

    // Country flag emoji built from the ISO country code ("ES" -> flag of Spain).
    var flag: String {
        var code = (country ?? "").uppercased()
        if code == "UK" { code = "GB" }
        guard code.count == 2 else { return "🌐" }
        let base: UInt32 = 0x1F1E6 - 65
        var result = ""
        for scalar in code.unicodeScalars {
            guard let flagScalar = UnicodeScalar(base + scalar.value) else { return "🌐" }
            result.unicodeScalars.append(flagScalar)
        }
        return result
    }
}

// Holds the list of indices and the chosen one. If the server has no /indices
// endpoint (old production server) the store falls back to S&P 500 only and
// `pickerAvailable` stays false, so the picker is hidden.
@MainActor
final class IndexStore: ObservableObject {
    static let shared = IndexStore()

    private static let defaultsKey = "selectedIndexId"

    @Published private(set) var indices: [IndexInfo] = [.sp500]
    @Published private(set) var pickerAvailable = false
    @Published private(set) var didLoad = false
    @Published var selectedId: String {
        didSet { UserDefaults.standard.set(selectedId, forKey: Self.defaultsKey) }
    }

    private init() {
        selectedId = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? "sp500"
    }

    var current: IndexInfo {
        indices.first { $0.id == selectedId } ?? .sp500
    }

    // Query value for API calls: nil for S&P 500 keeps requests identical to old app versions.
    var apiIndexId: String? {
        selectedId == "sp500" ? nil : selectedId
    }

    var isLive: Bool { current.live }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        do {
            let fetched = try await NetworkService.shared.fetchIndices()
            guard !fetched.isEmpty else { throw NetworkError.noData }
            indices = fetched
            pickerAvailable = fetched.count > 1
            if !fetched.contains(where: { $0.id == selectedId }) {
                selectedId = fetched.first { $0.id == "sp500" }?.id ?? fetched[0].id
            }
        } catch is CancellationError {
            return
        } catch {
            indices = [.sp500]
            pickerAvailable = false
            selectedId = "sp500"
        }
        didLoad = true
    }

    // "SC" (live session change) only exists for live indices; otherwise "1d".
    func effectivePeriod(_ period: String) -> String {
        (period == "SC" && !isLive) ? "1d" : period
    }

    func formatPrice(_ value: Double) -> String {
        let code = current.currency ?? "USD"
        if code == "USD" { return "$" + formatDecimal(value) }
        return value.formatted(.currency(code: code).locale(AppLanguage.locale))
    }

    // Region sections in display order.
    static let regionOrder = ["americas", "europe", "asia_pacific"]
}

// Reads "yyyy-MM-dd" and shows it in the user's locale.
func localizedShortDate(_ iso: String?) -> String? {
    guard let iso else { return nil }
    let parser = DateFormatter()
    parser.dateFormat = "yyyy-MM-dd"
    parser.timeZone = TimeZone(identifier: "UTC")
    parser.locale = Locale(identifier: "en_US_POSIX")
    guard let date = parser.date(from: iso) else { return nil }
    return date.formatted(.dateTime.day().month(.abbreviated).year().locale(AppLanguage.locale))
}
