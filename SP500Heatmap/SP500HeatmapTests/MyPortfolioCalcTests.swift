import Testing
import Foundation
@testable import SP500Heatmap

/// Тесты личного портфеля: FIFO, прибыль, дивиденды, курсы валют, CSV, график, хранение.
struct MyPortfolioCalcTests {
    typealias Tx = MyPortfolio.Transaction

    private func tx(_ type: PfTxType, _ day: String, _ q: Double, _ p: Double, fee: Double = 0,
                    ticker: String = "AAA", cur: String = "USD") -> Tx {
        Tx(ticker: ticker, indexId: "sp500", type: type, date: PfDay.date(day)!, quantity: q, price: p, currency: cur, fee: fee)
    }

    private func compute(_ txns: [Tx], base: PfBase = .USD, fx: PfFX = PfFX(), last: Double? = nil,
                         prev: Double? = nil, cur: String = "USD", divYield: Double? = nil) -> PfResult {
        var quotes: [String: PfQuote] = [:]
        if let last { quotes["AAA"] = PfQuote(last: last, prev: prev, currency: cur, day: nil) }
        let meta = ["AAA": PfMeta(name: "Aaa", sector: "Tech", country: "US", quoteCurrency: cur, divYield: divYield)]
        return PfCalc.compute(transactions: txns, base: base, fx: fx, quotes: quotes, meta: meta)
    }

    @Test func fifoRealizedAndRemainingCost() {
        let r = compute([tx(.buy, "2025-01-01", 10, 100), tx(.buy, "2025-02-01", 10, 120), tx(.sell, "2025-03-01", 15, 130)],
                        last: 140)
        #expect(abs(r.summary.realized - 350) < 1e-9)          // 10*(130-100) + 5*(130-120)
        let h = r.holdings[0]
        #expect(h.quantity == 5)
        #expect(abs(h.avgCost - 120) < 1e-9)                    // остались 5 штук из второй партии
        #expect(abs(h.costBase - 600) < 1e-9)
        #expect(abs((h.value ?? 0) - 700) < 1e-9)
        #expect(abs(r.summary.unrealized - 100) < 1e-9)
        #expect(abs(r.summary.totalPL - 450) < 1e-9)
        #expect(abs(r.summary.invested - 2200) < 1e-9)
        #expect(abs(r.summary.totalPLPct - 450 / 2200 * 100) < 1e-9)
    }

    @Test func feesEnterCostAndProceeds() {
        let r = compute([tx(.buy, "2025-01-01", 10, 100, fee: 10), tx(.sell, "2025-02-01", 5, 110, fee: 5)], last: 110)
        // расход на 5 штук = 505, выручка = 545
        #expect(abs(r.summary.realized - 40) < 1e-9)
        #expect(abs(r.holdings[0].costBase - 505) < 1e-9)
    }

    @Test func sellingMoreThanHeldIsClamped() {
        let r = compute([tx(.buy, "2025-01-01", 4, 10), tx(.sell, "2025-02-01", 10, 20)], last: 20)
        #expect(r.holdings.isEmpty)
        #expect(abs(r.summary.realized - 40) < 1e-9)            // только 4 проданные штуки: 4*(20-10)
    }

    @Test func sameDayBuyIsProcessedBeforeSell() {
        let r = compute([tx(.sell, "2025-01-05", 5, 12), tx(.buy, "2025-01-05", 5, 10)], last: 12)
        #expect(abs(r.summary.realized - 10) < 1e-9)
    }

    @Test func dividendSumsAndExpectedYield() {
        let r = compute([tx(.buy, "2025-01-01", 10, 100), tx(.dividend, "2025-03-01", 10, 0.5),
                         tx(.dividend, "2025-06-01", 10, 0.5, fee: 0.5)], last: 100, divYield: 2)
        #expect(abs(r.summary.dividends - 9.5) < 1e-9)          // 5 + (5 - 0.5)
        #expect(abs(r.summary.expectedAnnualDividends - 20) < 1e-9)   // 1000 * 2 %
        #expect(abs(r.summary.totalPL - 9.5) < 1e-9)
    }

    @Test func fxLookupAndConvert() {
        let fx = PfFX(series: ["EUR": [.init(d: "2025-01-01", r: 1.10), .init(d: "2025-02-01", r: 1.20)]])
        #expect(fx.usdPerUnit("USD", on: "2020-01-01") == 1)
        #expect(fx.usdPerUnit("EUR", on: "2025-01-15") == 1.10)
        #expect(fx.usdPerUnit("EUR", on: "2025-02-01") == 1.20)
        #expect(fx.usdPerUnit("EUR", on: "2024-06-01") == 1.10)  // до начала ряда — первая точка
        #expect(fx.usdPerUnit("GBP", on: "2025-01-15") == nil)
        #expect(abs(fx.convert(110, from: "USD", to: "EUR", on: "2025-01-15")! - 100) < 1e-9)
        #expect(abs(fx.convert(100, from: "EUR", to: "USD", on: "2025-02-10")! - 120) < 1e-9)
        #expect(fx.convert(5, from: "EUR", to: "EUR", on: "2025-02-10") == 5)
        #expect(fx.convert(5, from: "GBP", to: "EUR", on: "2025-02-10") == nil)
    }

    @Test func baseCurrencyUsesRateOfEachDate() {
        // Покупка 10 по 100 USD при курсе 1,25 → 800 EUR; сейчас курс 1,60 и цена 120 → 750 EUR.
        let fx = PfFX(series: ["EUR": [.init(d: "2025-01-01", r: 1.25), .init(d: "2025-06-01", r: 1.60)]])
        let r = compute([tx(.buy, "2025-01-10", 10, 100)], base: .EUR, fx: fx, last: 120)
        #expect(abs(r.holdings[0].costBase - 800) < 1e-9)
        #expect(abs((r.holdings[0].value ?? 0) - 750) < 1e-9)
        #expect(abs(r.summary.unrealized + 50) < 1e-9)
        #expect(!r.summary.missingFX)
        // Без курса суммы не конвертируются, но это отмечено.
        let noFX = compute([tx(.buy, "2025-01-10", 10, 100)], base: .EUR, last: 120)
        #expect(noFX.summary.missingFX)
    }

    @Test func todayChangeAndWeights() {
        let r = compute([tx(.buy, "2025-01-01", 10, 100)], last: 110, prev: 100)
        #expect(abs(r.summary.todayChange - 100) < 1e-9)
        #expect(abs(r.summary.todayPct - 100.0 / 1000 * 100) < 1e-9)
        #expect(abs(r.holdings[0].weight - 100) < 1e-9)
        #expect(abs((r.holdings[0].todayPct ?? 0) - 10) < 1e-9)
    }

    @Test func missingPriceIsCounted() {
        let r = compute([tx(.buy, "2025-01-01", 10, 100)])
        #expect(r.summary.missingPrices == 1)
        #expect(r.summary.value == 0)
    }

    @Test func allocationGroupsByKey() {
        let r = compute([tx(.buy, "2025-01-01", 10, 100)], last: 100)
        let s = PfCalc.allocation(r.holdings) { $0.sector }
        #expect(s.count == 1 && s[0].label == "Tech" && s[0].value == 1000)
    }

    @Test func csvRoundTrip() {
        let a = Tx(ticker: "SAP.DE", indexId: "dax40", type: .buy, date: PfDay.date("2025-01-10")!, quantity: 2.5, price: 210.35, currency: "EUR", fee: 1.25)
        let b = tx(.sell, "2025-03-01", 1, 99.5)
        let c = tx(.dividend, "2025-04-01", 10, 0.25, ticker: "BRK-B")
        let text = PfCSV.export([b, a, c])
        #expect(text.hasPrefix(PfCSV.header))
        let back = PfCSV.parse(text)
        #expect(back.badLines.isEmpty)
        #expect(back.transactions.count == 3)
        let sap = back.transactions.first { $0.ticker == "SAP.DE" }!
        #expect(sap.quantity == 2.5 && sap.price == 210.35 && sap.fee == 1.25 && sap.currency == "EUR" && sap.indexId == "dax40")
        #expect(sap.day == "2025-01-10" && sap.type == .buy)
        #expect(back.transactions.map(\.day) == ["2025-01-10", "2025-03-01", "2025-04-01"])
    }

    @Test func csvParsesPlainSevenColumnsAndReportsBadLines() {
        let text = "date,type,ticker,quantity,price,currency,fee\r\n2025-01-02,buy,aapl,3,150,usd,0\n\nnot-a-date,buy,X,1,1,USD,0\n2025-01-03,sell,AAPL,1,160,USD\n2025-01-04,hold,AAPL,1,1,USD,0\n"
        let r = PfCSV.parse(text)
        #expect(r.transactions.count == 2)
        #expect(r.transactions[0].ticker == "AAPL" && r.transactions[0].currency == "USD")
        #expect(r.transactions[1].fee == 0)
        #expect(r.badLines == [4, 6])
    }

    @Test func transactionJSONRoundTripIsCompact() throws {
        var p = MyPortfolio(name: "Test", baseCurrency: .EUR)
        p.transactions = (0..<1000).map { tx(.buy, "2025-01-01", Double($0 + 1), 12.34) }
        let data = try JSONEncoder().encode([p])
        let back = try JSONDecoder().decode([MyPortfolio].self, from: data)
        #expect(back[0].transactions.count == 1000)
        #expect(back[0].transactions[5].day == "2025-01-01" && back[0].baseCurrency == .EUR)
        #expect(data.count < 200_000)                           // 1000 сделок — далеко от лимита iCloud (1 МБ)
    }

    @Test func mergeKeepsNewerPortfolio() {
        var local = MyPortfolio(name: "A"); local.updated = 100
        var remote = local; remote.name = "B"; remote.updated = 200
        var other = MyPortfolio(name: "C"); other.updated = 50
        let merged = MyPortfolioStore.merge(local: [local], remote: [remote, other])
        #expect(merged.count == 2)
        #expect(merged.first { $0.id == local.id }?.name == "B")
        let older = MyPortfolioStore.merge(local: [remote], remote: [local])
        #expect(older[0].name == "B")
    }

    @Test func performanceChainsDailyReturnsAndIgnoresDeposits() {
        let hist = ["AAA": [DailyClose(date: "2025-01-01", close: 100), DailyClose(date: "2025-01-02", close: 110), DailyClose(date: "2025-01-03", close: 110)]]
        let bench = [DailyClose(date: "2025-01-01", close: 200), DailyClose(date: "2025-01-02", close: 210), DailyClose(date: "2025-01-03", close: 220)]
        let txns = [tx(.buy, "2025-01-01", 10, 100), tx(.buy, "2025-01-02", 10, 110)]
        let pts = PfPerformance.series(transactions: txns, base: .USD, fx: PfFX(), histories: hist,
                                       quoteCurrency: ["AAA": "USD"], benchmark: bench)
        #expect(pts.count == 3)
        #expect(pts[0].portfolio == 100)
        #expect(abs(pts[1].portfolio - 110) < 1e-9)             // докупка не считается доходом
        #expect(abs(pts[2].portfolio - 110) < 1e-9)
        #expect(abs((pts[2].benchmark ?? 0) - 110) < 1e-9)
    }
}
