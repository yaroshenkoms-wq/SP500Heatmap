import Foundation

// Мост между личным портфелем (Portfolio/) и ИИ-разбором (AI/), подключён при слиянии 24.11.2026.
extension PortfolioInsightHolding {
    init(_ h: PfHolding) {
        self.init(ticker: h.ticker, name: h.name, sector: h.sector ?? "", country: h.country ?? "",
                  weightPct: h.weight, dayChangePct: h.todayPct ?? 0, totalPLPct: h.unrealizedPct ?? 0)
    }
}
