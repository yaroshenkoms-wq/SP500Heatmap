import Foundation

class PerformanceStore: ObservableObject {
    static let shared = PerformanceStore()

    @Published var metrics: [String: PerformanceMetrics] = [:]

    private init() {}

    private var loadedIndex: String?

    // Loads performance for an index (nil = S&P 500). Clears old numbers first so
    // tiles never show another index's values, and ignores late replies.
    func reload(index: String?) async {
        await MainActor.run {
            self.loadedIndex = index ?? "sp500"
            self.metrics = [:]
        }
        let requested = index ?? "sp500"
        guard let fetched = try? await NetworkService.shared.fetchPerformance(index: index) else { return }
        await MainActor.run {
            if self.loadedIndex == requested { self.metrics = fetched }
        }
    }

    // Resolves a ticker's % change for a given PeriodSwitchView period. "SC" has no
    // historical value here - callers should use the live WebSocket price for it.
    func changePercent(for ticker: String, period: String) -> Double? {
        guard period != "SC" else { return nil }
        return metrics[ticker]?.value(forPeriod: period)
    }
}
