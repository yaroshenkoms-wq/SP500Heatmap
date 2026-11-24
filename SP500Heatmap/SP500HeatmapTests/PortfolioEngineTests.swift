import Testing
import Foundation
@testable import SP500Heatmap

// Reference numbers come from the udak.eu backtest (models/hist/backtest.py, rebalance="annual",
// extended=True), run read-only with Python. Tolerance 5e-5 covers the rounding of data.json.
struct PortfolioEngineTests {
    private let store = PortfolioStore.shared
    private let tol = 5e-5

    private func check(_ key: String, _ cur: PortfolioCurrency, from: String?, months: Int, first: String,
                       cagr: Double, real: Double, vol: Double, dd: Double, worst: Double, best: Double) throws {
        let engine = try #require(store.engine(cur))
        let info = try #require(store.info(key))
        let r = try #require(engine.run(weights: info.weights, from: from))
        let rr = try #require(engine.run(weights: info.weights, from: from, real: true))
        #expect(r.metrics.months == months)
        #expect(r.metrics.from == first)
        #expect(abs(r.metrics.cagr - cagr) < tol)
        #expect(abs(rr.metrics.cagr - real) < tol)
        #expect(abs(r.metrics.volatility - vol) < tol)
        #expect(abs(r.metrics.maxDrawdown - dd) < tol)
        #expect(abs((r.metrics.worstYear ?? 0) - worst) < tol)
        #expect(abs((r.metrics.bestYear ?? 0) - best) < tol)
    }

    @Test func dataIsBundled() {
        #expect(store.isAvailable)
        #expect(store.models.count == 59)
        #expect(store.reference?.key == "spy")
        #expect(store.engine(.usd)?.count == 1203)
    }

    @Test func dalioUSDFullHistory() throws {
        try check("m_dalio", .usd, from: nil, months: 512, first: "1984-02", cagr: 0.089439, real: 0.059327,
                  vol: 0.079267, dd: -0.217230, worst: -0.196247, best: 0.297884)
    }

    @Test func dalioUSDTenYears() throws {
        try check("m_dalio", .usd, from: "2016-10", months: 120, first: "2016-10", cagr: 0.054739, real: 0.020160,
                  vol: 0.087435, dd: -0.217230, worst: -0.196247, best: 0.189231)
    }

    @Test func permanentUSDThirtyYears() throws {
        try check("m_permanent", .usd, from: "1996-10", months: 360, first: "1996-10", cagr: 0.070604, real: 0.043872,
                  vol: 0.068419, dd: -0.157703, worst: -0.122615, best: 0.226267)
    }

    @Test func buffettUSDSince1926() throws {
        try check("m_buffett", .usd, from: nil, months: 1203, first: "1926-07", cagr: 0.098901, real: 0.067074,
                  vol: 0.164275, dd: -0.795118, worst: -0.392785, best: 0.511461)
    }

    @Test func buffettEURFullHistory() throws {
        try check("m_buffett", .eur, from: nil, months: 876, first: "1953-10", cagr: 0.096400, real: 0.067646,
                  vol: 0.153401, dd: -0.550077, worst: -0.324638, best: 0.483660)
    }

    @Test func dalioEURThirtyYears() throws {
        try check("m_dalio", .eur, from: "1996-10", months: 360, first: "1996-10", cagr: 0.080564, real: 0.058306,
                  vol: 0.098017, dd: -0.203015, worst: -0.146511, best: 0.327524)
    }

    @Test func periodsEndAtLastMonthAndNeedFullWindow() throws {
        let engine = try #require(store.engine(.usd))
        let spy = try #require(store.reference)
        let ten = try #require(engine.run(weights: spy.weights, period: .y10))
        #expect(ten.metrics.months == 120)
        #expect(ten.metrics.to == engine.lastMonth)
        // Dalio data starts in 1984, so a 30-year window (from 1996) exists.
        #expect(engine.run(weights: try #require(store.info("m_dalio")).weights, period: .y30) != nil)
        #expect(PortfolioPeriod.y30.months == 360)
    }

    @Test func growthWithContributions() throws {
        let engine = try #require(store.engine(.usd))
        let spy = try #require(store.reference)
        let r = try #require(engine.run(weights: spy.weights, from: "2000-01", to: "2009-12"))
        let g = r.growth(initial: 1000, monthly: 100)
        #expect(g.count == r.returns.count + 1)
        #expect(g[0] == 1000)
        // value = (value + contribution) * (1 + r), month by month
        #expect(abs(g[1] - (1000 + 100) * (1 + r.returns[0])) < 1e-9)
    }

    @Test func erasAreReported() throws {
        let engine = try #require(store.engine(.usd))
        let spy = try #require(store.reference)
        let full = try #require(engine.run(weights: spy.weights, period: .all))
        let eras = engine.eraResults(for: full)
        let crash = try #require(eras["crash-1929-1932"])
        #expect(crash.total < -0.6)
        #expect(crash.maxDrawdown < -0.7)
    }

    @Test func everyLanguageHasModelNames() throws {
        let text = try #require(store.text)
        for key in store.models.map(\.key) {
            let names = try #require(text.models[key]?.name)
            for code in AppLanguage.codes { #expect(!(names[code] ?? "").isEmpty) }
        }
    }
}
