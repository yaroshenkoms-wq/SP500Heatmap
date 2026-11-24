import Testing
import Foundation
@testable import SP500Heatmap

struct NewsAITests {
    // MARK: Новости

    private func article(_ title: String, _ url: String, _ date: String?, tickers: [String] = [], lang: String? = nil) -> NewsArticle {
        NewsArticle(title: title, publisher: "Reuters", url: url, published: date, tickers: tickers, lang: lang)
    }

    @Test func newsParsingSkipsBrokenItems() throws {
        let json = """
        {"items":[{"id":"1","title":"A","publisher":"X","url":"https://x.test/1","published":"2026-11-23T10:00:00Z","tickers":["AAPL"],"lang":"en"},
                  {"title":"no url"},
                  {"title":"B","url":"https://x.test/2"}]}
        """
        let items = try #require(NewsService.parse(Data(json.utf8)))
        #expect(items.count == 2)
        #expect(items[0].tickers == ["AAPL"] && items[0].lang == "en")
        #expect(items[1].id == "https://x.test/2" && items[1].tickers.isEmpty)
    }

    @Test func newsRequestURL() throws {
        let u = try #require(NewsService.url(scope: .tickers(["AAPL", "SAN.MC"]), lang: "es", limit: 50)).absoluteString
        #expect(u.contains("scope=tickers") && u.contains("tickers=AAPL,SAN.MC") && u.contains("lang=es") && u.contains("limit=50"))
        let i = try #require(NewsService.url(scope: .index("ibex35"), lang: "en")).absoluteString
        #expect(i.contains("scope=index") && i.contains("indexId=ibex35"))
        #expect(try #require(NewsService.url(scope: .market, lang: "en")).absoluteString.contains("scope=market"))
    }

    @Test func cleanDedupesAndSortsNewestFirst() {
        let items = [article("Old", "https://x.test/old", "2026-11-20T10:00:00Z"),
                     article("Undated", "https://x.test/u", nil),
                     article("New", "https://x.test/new", "2026-11-23T10:00:00Z"),
                     article("new", "https://x.test/other", "2026-11-23T11:00:00Z"),      // тот же заголовок
                     article("Dup", "https://x.test/new", "2026-11-23T09:00:00Z"),        // тот же адрес
                     article("Bad link", "ftp://x.test/f", "2026-11-23T12:00:00Z")]
        let out = NewsLogic.clean(items)
        #expect(out.map(\.title) == ["New", "Old", "Undated"])
    }

    @Test func languageFilter() {
        let items = [article("EN", "https://x.test/1", nil), article("ES", "https://x.test/2", nil, lang: "es"),
                     article("ZH", "https://x.test/3", nil, lang: "zh")]
        #expect(NewsLogic.filter(items, .all, code: "es").count == 3)
        #expect(NewsLogic.filter(items, .mine, code: "es").map(\.title) == ["ES"])
        #expect(NewsLogic.filter(items, .mine, code: "en").map(\.title) == ["EN"])
        #expect(NewsLogic.filter(items, .mine, code: "zh-Hans").map(\.title) == ["ZH"])
        #expect(NewsLogic.hasLocalLanguage(items, code: "es"))
        #expect(!NewsLogic.hasLocalLanguage(items, code: "en"))
    }

    @Test func relativeTimeAndMeta() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = article("T", "https://x.test/1", NewsFormat.iso(now.addingTimeInterval(-3600)))
        let m = NewsFormat.meta(a, now: now, locale: Locale(identifier: "en"))
        #expect(m.hasPrefix("Reuters · "))
        #expect(m.contains("hr") || m.contains("hour"))
        #expect(NewsFormat.relative(nil) == "")
    }

    @Test func digestTemplateGroupsByTicker() {
        let items = [article("Apple launches phone", "https://x.test/1", nil, tickers: ["AAPL"]),
                     article("Markets rally", "https://x.test/2", nil),
                     article("Apple earnings beat", "https://x.test/3", nil, tickers: ["AAPL"]),
                     article("Tesla recall", "https://x.test/4", nil, tickers: ["TSLA"]),
                     article("Fed holds rates", "https://x.test/5", nil),
                     article("Sixth item is dropped", "https://x.test/6", nil, tickers: ["MSFT"])]
        let d = NewsDigestBuilder.template(items, code: "en")
        #expect(d.summary == "Top 5 headlines")
        #expect(!d.usedModel)
        #expect(d.points == ["AAPL: Apple launches phone · Apple earnings beat",
                             "General market: Markets rally · Fed holds rates",
                             "TSLA: Tesla recall"])
        #expect(!d.points.joined().contains("Sixth"))
    }

    @Test(arguments: AppLanguage.codes)
    func digestTemplateInEveryLanguage(code: String) {
        let items = [article("A", "https://x.test/1", nil, tickers: ["AAPL"]), article("B", "https://x.test/2", nil)]
        let d = NewsDigestBuilder.template(items, code: code)
        #expect(!d.summary.isEmpty && !d.summary.contains("%"))
        #expect(d.points.count == 2)
        if code != "en" { #expect(d.summary != "Top 2 headlines") }
        #expect(!NewsDigestBuilder.template([], code: code).summary.isEmpty)
    }

    @Test func digestPromptAndInstructions() {
        let p = NewsDigestBuilder.prompt([article("Apple launches phone", "https://x.test/1", nil, tickers: ["AAPL"])])
        #expect(p.contains("[1] Apple launches phone (Reuters; AAPL)"))
        let i = NewsDigestBuilder.instructions(languageCode: "es")
        #expect(i.contains("Never give investment advice") && i.contains("Spanish"))
    }

    // MARK: Данные инструментов

    private func history(_ pairs: [(String, Double)]) -> [DailyClose] { pairs.map { DailyClose(date: $0.0, close: $0.1) } }

    @Test func quoteFactsFromHistory() {
        let h = history([("2025-12-30", 100), ("2026-10-20", 110), ("2026-11-20", 120), ("2026-11-23", 126)])
        let q = AIQuoteFacts.make(ticker: "AAPL", name: "Apple", history: h, info: nil, live: nil)
        #expect(q.last == 126 && q.lastDate == "2026-11-23" && !q.live)
        #expect(abs((q.change1d ?? 0) - 5.0) < 1e-9)            // 126 / 120
        #expect(abs((q.change1M ?? 0) - (126.0 / 110 - 1) * 100) < 1e-9)   // 2026-10-24 → последнее закрытие 20.10
        #expect(abs((q.changeYTD ?? 0) - 26.0) < 1e-9)          // от закрытия 2025-12-30
    }

    @Test func quoteFactsPreferLivePrice() {
        let h = history([("2026-11-20", 120), ("2026-11-21", 121)])
        let q = AIQuoteFacts.make(ticker: "X", name: nil, history: h, info: nil, live: (price: 130, changePercent: 7.5))
        #expect(q.last == 130 && q.live && q.change1d == 7.5)
    }

    @Test func quoteTextHasNumbersAndDates() {
        var q = AIQuoteFacts(ticker: "AAPL", name: "Apple Inc.", currency: "USD", last: 190.123, lastDate: "2026-11-23")
        q.change1d = 1.234; q.change1M = -2.5; q.high52w = 200; q.low52w = 150; q.pe = 29.14; q.divYield = 0.5
        let s = AIToolFormat.quote(q)
        #expect(s.contains("AAPL (Apple Inc.): last 190.12 USD (close of 2026-11-23)."))
        #expect(s.contains("today +1.23%") && s.contains("1 month -2.50%"))
        #expect(!s.contains("year to date"))
        #expect(s.contains("52-week range 150.00–200.00") && s.contains("P/E 29.1") && s.contains("Dividend yield 0.50%"))
        #expect(AIToolFormat.quote(AIQuoteFacts(ticker: "ZZZ")) == "No price data available for ZZZ.")
    }

    @Test func numberFormats() {
        #expect(AIToolFormat.pct(1.5) == "+1.50%")
        #expect(AIToolFormat.pct(-0.004) == "-0.00%")
        #expect(AIToolFormat.pct(nil) == "n/a")
        #expect(AIToolFormat.big(2.5e12) == "2.50T" && AIToolFormat.big(340.5e9) == "340.50B" && AIToolFormat.big(12.3e6) == "12.30M")
        #expect(AIToolFormat.big(950) == "950")
        #expect(AIToolFormat.money(1234.5, "EUR") == "1234.50 EUR")
    }

    private func overview() throws -> WorldOverview {
        let json = """
        {"asOf":"2026-11-23","regions":[
          {"id":"americas","indices":[{"id":"sp500","name":"S&P 500","country":"US","capUSD":5e13,"changes":{"1d":-0.8,"7d":1.2,"30d":3.0,"1y":15.5}},
                                      {"id":"nasdaq100","name":"Nasdaq 100","country":"US","capUSD":3e13,"changes":{"1d":-1.1,"7d":null}}]},
          {"id":"europe","indices":[{"id":"ibex35","name":"IBEX 35","country":"ES","capUSD":7e11,"changes":{"1d":0.3,"1y":22.0}}]}]}
        """
        return try JSONDecoder().decode(WorldOverview.self, from: Data(json.utf8))
    }

    @Test func indexTexts() throws {
        let o = try overview()
        let one = AIToolFormat.indexes(o, query: "IBEX 35")
        #expect(one.contains("as of 2026-11-23") && one.contains("IBEX 35 (id ibex35, ES): 1d +0.30%, 1y +22.00%"))
        let sp = AIToolFormat.indexes(o, query: "sp500")
        #expect(sp.contains("1d -0.80%, 7d +1.20%, 30d +3.00%, 1y +15.50%"))
        let all = AIToolFormat.indexes(o, query: "all")
        #expect(all.contains("S&P 500") && all.contains("Nasdaq 100") && all.contains("IBEX 35"))
        #expect(all.range(of: "S&P 500")!.lowerBound < all.range(of: "IBEX 35")!.lowerBound)   // по капитализации
        #expect(AIToolFormat.indexes(o, query: "Nikkei").hasPrefix("No index matches"))
        #expect(Nasdaq(o))
    }
    private func Nasdaq(_ o: WorldOverview) -> Bool {
        AIToolFormat.matchIndexes(o.regions.flatMap(\.indices), query: "nasdaq").first?.id == "nasdaq100"
    }

    @Test func financialsText() throws {
        let json = """
        {"ticker":"AAPL","currency":"USD",
         "annual":[{"period":"2024","revenue":380e9,"netIncome":90e9,"eps":5.9},
                   {"period":"2025","revenue":400e9,"grossProfit":180e9,"operatingIncome":120e9,"netIncome":100e9,"eps":6.5,"freeCashFlow":105e9,"totalDebt":100e9,"cash":60e9}],
         "quarterly":[],"ratios":{"roe":150.0,"debtToEquity":1.8,"peg":2.1},
         "analysts":{"recommendation":"buy","count":40,"targetMean":210.0,"targetHigh":250.0,"targetLow":160.0},"holders":[]}
        """
        let f = try JSONDecoder().decode(Financials.self, from: Data(json.utf8))
        let s = AIToolFormat.financials(f, ticker: "AAPL")
        #expect(s.contains("Fiscal year 2025: revenue 400.00B, net income 100.00B, EPS 6.50, free cash flow 105.00B"))
        #expect(s.contains("gross margin 45.0%") && s.contains("operating margin 30.0%") && s.contains("net margin 25.0%"))
        #expect(s.contains("Previous fiscal year 2024"))
        #expect(s.contains("Revenue growth year over year +5.3%"))
        #expect(s.contains("ROE 150.0%") && s.contains("debt/equity 1.80"))
        #expect(s.contains("consensus buy (40 analysts), mean target price 210.00 (range 160.00–250.00)"))
        let empty = try JSONDecoder().decode(Financials.self, from: Data("{}".utf8))
        #expect(AIToolFormat.financials(empty, ticker: "X") == "No financial statements available for X.")
    }

    @Test func newsText() {
        let items = [article("Apple launches phone", "https://x.test/1", "2026-11-23T10:00:00Z", tickers: ["AAPL"])]
        let s = AIToolFormat.news(items, title: "AAPL")
        #expect(s == "Latest headlines for AAPL:\n1. Apple launches phone (Reuters, 2026-11-23, AAPL)")
        #expect(AIToolFormat.news([], title: "the market") == "No recent headlines found for the market.")
    }

    @Test func screenerTextAndPresets() throws {
        let json = """
        {"total":25,"rows":[{"ticker":"IBE.MC","name":"Iberdrola","index":"ibex35","sector":"Utilities","capUSD":8e10,"change":0.3,"pe":15.2,"divYield":4.8,"pos52w":0.8},
                            {"ticker":"TEF.MC","name":"Telefónica","divYield":7.1}]}
        """
        let r = try JSONDecoder().decode(ScreenerResult.self, from: Data(json.utf8))
        let s = AIToolFormat.screener(r.rows, total: r.total, preset: "dividend", indexId: "ibex35")
        #expect(s.hasPrefix("Screener preset dividend in ibex35: 25 matches, top 2 shown:"))
        #expect(s.contains("1. IBE.MC — Iberdrola: Utilities, today +0.30%, dividend yield 4.80%, P/E 15.2, market cap 80.00B USD, 52-week position 80%"))
        #expect(s.contains("2. TEF.MC — Telefónica: dividend yield 7.10%"))
        #expect(AIToolFormat.normalizePreset("Dividend Yield") == "dividend")
        #expect(AIToolFormat.normalizePreset("top losers") == "losers")
        #expect(AIToolFormat.normalizePreset("52 week highs") == "highs52")
        #expect(AIToolFormat.normalizePreset("gainers") == "gainers")
        #expect(AIToolFormat.screener([], total: 0, preset: "value", indexId: "dax40").contains("no stocks"))
    }

    private func holding(_ t: String, w: Double, today: Double?, change: Double?, pl: Double?) -> PfHolding {
        PfHolding(ticker: t, indexId: "sp500", name: t, quantity: 1, quoteCurrency: "USD", avgCost: 1, costBase: 1, last: 1,
                  value: 1, unrealized: 1, unrealizedPct: pl, todayChange: change, todayPct: today, weight: w,
                  realized: 0, dividends: 0, sector: "Technology", country: "US")
    }

    private var pfResult: PfResult {
        var s = PfSummary()
        s.value = 12_345.67; s.cost = 10_000; s.invested = 10_000; s.unrealized = 2_345.67; s.todayChange = 98.76; s.todayPct = 0.8
        s.dividends = 50
        return PfResult(holdings: [holding("AAPL", w: 60, today: 2, change: 150, pl: 30), holding("XOM", w: 40, today: -1, change: -51.24, pl: 10)],
                        summary: s)
    }

    @Test func portfolioText() {
        let s = AIToolFormat.portfolio(name: "Main", base: "EUR", result: pfResult)
        #expect(s.contains("Portfolio \"Main\" (base currency EUR"))
        #expect(s.contains("Value 12345.67 EUR") && s.contains("unrealized result 2345.67 EUR (+23.5%)"))
        #expect(s.contains("Today +0.80% (98.76 EUR)"))
        #expect(s.contains("AAPL 60.0% of value, today +2.00%, since purchase +30.0%"))
        #expect(s.contains("Helped most today: AAPL (150.00 EUR).") && s.contains("Hurt most today: XOM (-51.24 EUR)."))
        #expect(AIToolFormat.portfolio(name: "E", base: "USD", result: PfResult()).contains("no open positions"))
    }

    @Test func modelPortfolioText() {
        let m = PortfolioMetrics(from: "2016-11", to: "2026-10", months: 120, cagr: 0.081, totalReturn: 1.18, maxDrawdown: -0.2,
                                 ddPeak: "2020-02", ddTrough: "2020-03", volatility: 0.098, worstYear: -0.15, worstYearLabel: "2022",
                                 bestYear: 0.21, bestYearLabel: "2019")
        let s = AIToolFormat.modelPortfolio(key: "allweather", name: "All Weather", risk: "medium",
                                            weights: ["stocks": 0.3, "bonds": 0.55, "zero": 0], period: "last 10 years", metrics: m, currency: "USD")
        #expect(s.contains("Weights: bonds 55%, stocks 30%."))
        #expect(s.contains("annualized return 8.1%") && s.contains("total return +118.0%"))
        #expect(s.contains("maximum drawdown -20.0% (peak 2020-02, trough 2020-03)") && s.contains("volatility 9.8%"))
        #expect(s.contains("Best year 2019 +21.0%") && s.contains("Worst year 2022 -15.0%"))
    }

    @Test func chatInstructionsForbidAdviceAndSetLanguage() {
        let i = AIChatEngine.instructions(languageCode: "ru", today: "2026-11-24")
        #expect(i.contains("Today is 2026-11-24"))
        #expect(i.contains("ONLY with data returned by your tools"))
        #expect(i.contains("Never give investment advice") && i.contains("predictions"))
        #expect(i.contains("Russian"))
        #expect(AIChatEngine.instructions(languageCode: "es", today: "x").contains("Spanish"))
    }

    // MARK: Быстрые ответы (шаблоны без модели)

    private func q(_ t: String, _ d1: Double?, _ m1: Double?, _ ytd: Double?, pe: Double? = nil, y: Double? = nil) -> AIQuoteFacts {
        var f = AIQuoteFacts(ticker: t, last: 100, lastDate: "2026-11-23")
        f.change1d = d1; f.change1M = m1; f.changeYTD = ytd; f.pe = pe; f.divYield = y
        return f
    }

    @Test func compareTemplate() {
        let a = AIQuickTemplates.compare(q("AAPL", 1.0, 5.0, 20, pe: 29, y: 0.5), q("MSFT", -0.5, 3.0, nil, pe: 33), "en")
        #expect(a.lines[0] == "AAPL: +1.00% today, +5.00% over 1 month, +20.00% year to date.")
        #expect(a.lines[1] == "MSFT: -0.50% today, +3.00% over 1 month, — year to date.")
        #expect(a.lines.contains("AAPL — P/E 29.0, dividend yield 0.50%."))
        #expect(a.lines.contains("MSFT — P/E 33.0, dividend yield —."))
        #expect(a.lines.last == "Stronger over 1 month: AAPL (+5.00% vs +3.00%).")
        let none = AIQuickTemplates.compare(AIQuoteFacts(ticker: "A"), AIQuoteFacts(ticker: "B"), "en")
        #expect(none.lines == ["No price data available for A.", "No price data available for B."])
    }

    @Test func dividendsTemplate() throws {
        let json = """
        {"total":3,"rows":[{"ticker":"TEF.MC","name":"Telefónica","pe":12.0,"divYield":7.1},
                           {"ticker":"IBE.MC","name":"Iberdrola","divYield":4.8},{"ticker":"NODIV","name":"No dividend"}]}
        """
        let r = try JSONDecoder().decode(ScreenerResult.self, from: Data(json.utf8))
        let a = AIQuickTemplates.dividends(r.rows, indexName: "IBEX 35", "en")
        #expect(a.lines == ["Highest dividend yields in IBEX 35:",
                            "TEF.MC (Telefónica): dividend yield 7.10%, P/E 12.0",
                            "IBE.MC (Iberdrola): dividend yield 4.80%"])
        #expect(AIQuickTemplates.dividends([], indexName: "X", "en").lines == ["The screener returned no stocks right now."])
    }

    @Test func portfolioTemplate() {
        let a = AIQuickTemplates.portfolio(pfResult, "en")
        #expect(a.lines.first == "Your portfolio is up 0.80% today.")
        #expect(a.lines.contains { $0.contains("Largest position: AAPL") })
        #expect(AIQuickTemplates.portfolio(PfResult(), "en").lines == ["Add transactions in the Portfolio tab first, then I can summarize it."])
    }

    @Test(arguments: AppLanguage.codes)
    func quickAnswersInEveryLanguage(code: String) throws {
        let a = AIQuickTemplates.compare(q("AAPL", 1, 5, 20, pe: 29, y: 0.5), q("MSFT", -1, 3, 10), code)
        let json = #"{"total":1,"rows":[{"ticker":"TEF.MC","name":"Telefónica","pe":12.0,"divYield":7.1}]}"#
        let rows = try JSONDecoder().decode(ScreenerResult.self, from: Data(json.utf8)).rows
        let d = AIQuickTemplates.dividends(rows, indexName: "IBEX 35", code)
        for line in a.lines + d.lines + AIQuickTemplates.noPortfolio(code).lines {
            #expect(!line.isEmpty && !line.contains("%@") && !line.contains("%1$") && !line.contains("%lld"))
        }
        if code != "en" {
            #expect(a.lines[0] != "AAPL: +1.00% today, +5.00% over 1 month, +20.00% year to date.")
            #expect(AIQuickTemplates.noPortfolio(code).lines != AIQuickTemplates.noPortfolio("en").lines)
        }
        for question in AIQuestion.suggested + [.stock("NVDA")] {
            let t = question.text(code)
            #expect(!t.isEmpty && !t.contains("%@") && !t.contains("%1$"))
            if code != "en", question == .marketToday { #expect(t != question.text("en")) }
        }
    }

    @Test func suggestedQuestionsMatchSpec() {
        let en = AIQuestion.suggested.map { $0.text("en") }
        #expect(en == ["Why is the market down today?", "Compare AAPL and MSFT", "Best dividend stocks in IBEX 35", "How is my portfolio doing?"])
        #expect(AIQuestion.stock("NVDA").text("en") == "Why is NVDA moving today?")
    }
}
