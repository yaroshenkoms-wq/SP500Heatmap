import Testing
@testable import SP500Heatmap

struct IndicatorsTests {
    private func close(_ a: Double?, _ b: Double, tol: Double = 1e-6) -> Bool {
        guard let a else { return false }
        return abs(a - b) < tol
    }

    @Test func smaKnownValues() {
        let r = Indicators.sma([1, 2, 3, 4, 5, 6], period: 3)
        #expect(r[0] == nil && r[1] == nil)
        #expect(close(r[2], 2) && close(r[3], 3) && close(r[5], 5))
    }

    @Test func emaKnownValues() {
        // period 3: seed = SMA(1,2,3) = 2, k = 0.5 -> 3, 4
        let r = Indicators.ema([1, 2, 3, 4, 5], period: 3)
        #expect(r[1] == nil)
        #expect(close(r[2], 2) && close(r[3], 3) && close(r[4], 4))
    }

    @Test func rsiWilderReference() {
        // Classic Wilder / StockCharts example data.
        let prices: [Double] = [44.34, 44.09, 44.15, 43.61, 44.33, 44.83, 45.10, 45.42, 45.84, 46.08,
                                45.89, 46.03, 45.61, 46.28, 46.28, 46.00, 46.03, 46.41, 46.22, 45.64]
        let r = Indicators.rsi(prices, period: 14)
        #expect(r[13] == nil)
        #expect(close(r[14], 70.46, tol: 0.1))
        #expect(close(r[15], 66.25, tol: 0.1))
        #expect(close(r[16], 66.48, tol: 0.1))
    }

    @Test func rsiExtremes() {
        let up = (0..<30).map { Double($0) }
        #expect(close(Indicators.rsi(up, period: 14).last ?? nil, 100))
        let down = (0..<30).map { Double(30 - $0) }
        #expect(close(Indicators.rsi(down, period: 14).last ?? nil, 0))
    }

    @Test func macdStructure() {
        // Straight line 1...60: fast EMA - slow EMA converges to (slow-fast)/2 lag = 7 for slope 1.
        let values = (1...60).map { Double($0) }
        let r = Indicators.macd(values)
        #expect(r[24] == nil)
        #expect(r[25] != nil && r[25]?.signal == nil)
        #expect(r[33]?.signal != nil)
        let last = r[59]!
        #expect(abs(last.macd - 7.0) < 0.2)
        #expect(abs((last.histogram ?? 99)) < 0.5)
        // line = EMA12 - EMA26 at index 30
        let f = Indicators.ema(values, period: 12)[30]!, s = Indicators.ema(values, period: 26)[30]!
        #expect(close(r[30]?.macd, f - s))
    }
}
