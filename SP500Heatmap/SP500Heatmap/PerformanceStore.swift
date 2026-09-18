import Foundation

class PerformanceStore: ObservableObject {
    static let shared = PerformanceStore()

    @Published var metrics: [String: PerformanceMetrics] = [:]

    private init() {}

    func loadIfNeeded() {
        guard metrics.isEmpty else { return }
        Task {
            guard let fetched = try? await NetworkService.shared.fetchPerformance() else { return }
            await MainActor.run { self.metrics = fetched }
        }
    }

    // Resolves a ticker's % change for a given PeriodSwitchView period. "SC" has no
    // historical value here - callers should use the live WebSocket price for it.
    func changePercent(for ticker: String, period: String) -> Double? {
        guard period != "SC" else { return nil }
        return metrics[ticker]?.value(forPeriod: period)
    }
}
