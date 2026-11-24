import Testing
import Foundation
@testable import SP500Heatmap

struct AITests {
    private let stock = AIFacts(
        kind: .stock, subject: "NVDA", name: "NVIDIA", changePct: 3.21,
        benchmark: AINamedChange(name: "S&P 500", change: 0.8),
        sector: AINamedChange(name: "Technology", change: 1.9),
        headlines: [AIHeadline(title: "NVIDIA unveils new chip", publisher: "Reuters", url: "https://x.test/1", ticker: "NVDA"),
                    AIHeadline(title: "Analysts discuss data-center demand", publisher: "WSJ", url: "https://x.test/2", ticker: "NVDA")])

    private var market: AIFacts {
        var f = AIFacts(kind: .market, subject: "market")
        f.indices = [AINamedChange(name: "S&P 500", change: 0.5), AINamedChange(name: "DAX", change: 0.2)]
        f.gainers = [AINamedChange(name: "AAPL", change: 4.0)]
        f.losers = [AINamedChange(name: "XOM", change: -3.0)]
        f.sectors = [AINamedChange(name: "Energy", change: -1.0), AINamedChange(name: "Technology", change: 1.5)]
        f.headlines = [AIHeadline(title: "Stocks rise", publisher: nil, url: nil, ticker: nil)]
        return f
    }

    private let holdings = [
        PortfolioInsightHolding(ticker: "AAPL", name: "Apple", sector: "Technology", country: "US", weightPct: 60, dayChangePct: 2, totalPLPct: 30),
        PortfolioInsightHolding(ticker: "XOM", name: "Exxon", sector: "Energy", country: "US", weightPct: 40, dayChangePct: -1, totalPLPct: 10),
    ]

    // MARK: Промпт

    @Test func promptContainsOnlyGivenFacts() {
        let p = AIPromptBuilder.prompt(stock)
        #expect(p.contains("NVDA today: +3.21%"))
        #expect(p.contains("Index S&P 500 today: +0.80%"))
        #expect(p.contains("Sector Technology today: +1.90%"))
        #expect(p.contains("[1] NVIDIA unveils new chip (Reuters)"))
        #expect(p.contains("[2] Analysts discuss data-center demand (WSJ)"))
    }

    @Test func promptWithoutHeadlinesSaysSo() {
        var f = stock; f.headlines = []
        #expect(AIPromptBuilder.prompt(f).contains("Headlines: none available."))
    }

    @Test func instructionsForbidAdviceAndSetLanguage() {
        let i = AIPromptBuilder.instructions(languageCode: "es")
        #expect(i.contains("Never give investment advice"))
        #expect(i.contains("predictions"))
        #expect(i.contains("Spanish"))
        #expect(AIPromptBuilder.instructions(languageCode: "ru").contains("Russian"))
    }

    @Test func marketAndPortfolioPrompts() {
        let m = AIPromptBuilder.prompt(market)
        #expect(m.contains("Top gainers: AAPL +4.00%"))
        #expect(m.contains("Top losers: XOM -3.00%"))
        var pf = AIFacts(kind: .portfolio, subject: "portfolio")
        pf.portfolio = AIPortfolioSummary.make(holdings)
        let p = AIPromptBuilder.prompt(pf)
        #expect(p.contains("Portfolio today: +0.80%"))
        #expect(p.contains("Largest position: AAPL, 60.0% of portfolio"))
    }

    // MARK: Портфолио

    @Test func portfolioSummaryMath() throws {
        let s = try #require(AIPortfolioSummary.make(holdings))
        #expect(abs(s.dayChangePct - 0.8) < 1e-9)       // 0.6*2 + 0.4*(-1)
        #expect(abs(s.totalPLPct - 22) < 1e-9)          // 0.6*30 + 0.4*10
        #expect(s.bestContributor?.name == "AAPL")
        #expect(s.worstContributor?.name == "XOM")
        #expect(s.topSector?.name == "Technology")
        #expect(s.topCountry?.name == "US")
        #expect(AIPortfolioSummary.make([]) == nil)
    }

    // MARK: Шаблон на всех языках

    @Test(arguments: AppLanguage.codes)
    func templateWorksInEveryLanguage(code: String) {
        for facts in [stock, market, { var f = AIFacts(kind: .portfolio, subject: "p"); f.portfolio = AIPortfolioSummary.make(holdings); return f }()] {
            let r = AITemplate.make(facts, language: code)
            #expect(!r.headline.isEmpty)
            #expect(!r.reasons.isEmpty)
            #expect(!r.usedModel)
            let all = ([r.headline] + r.reasons).joined(separator: "\n")
            #expect(!all.contains("%@") && !all.contains("%1$@"), "unresolved placeholder in \(code)")
            if code != "en" {
                // Перевод есть: заголовок не совпадает с английским.
                #expect(r.headline != AITemplate.make(facts, language: "en").headline, "\(code) not translated")
            }
        }
    }

    @Test func stockTemplateContent() {
        let r = AITemplate.make(stock, language: "en")
        #expect(r.headline == "NVDA is up 3.21% today.")
        #expect(r.sentiment == .up)
        #expect(r.reasons.contains { $0.contains("Ahead of S&P 500") })
        #expect(r.reasons.contains { $0.contains("Sector Technology") })
        #expect(r.reasons.contains { $0.contains("NVIDIA unveils new chip") })
        #expect(r.sources.count == 2)
    }

    @Test func marketTemplateContent() {
        let r = AITemplate.make(market, language: "en")
        #expect(r.headline == "Markets are mostly higher today.")
        #expect(r.reasons.contains { $0.contains("Top gainer: AAPL") })
        #expect(r.reasons.contains { $0.contains("Strongest sector: Technology") })
    }

    @Test func noDataGivesEmptyMessage() {
        let r = AITemplate.make(AIFacts(kind: .stock, subject: "X"), language: "en")
        #expect(r.headline == "Not enough data for a summary.")
        #expect(r.reasons.isEmpty)
    }

    // MARK: Кэш и разбор брифа

    @Test func cacheKeyIsPerDayAndLanguage() {
        let a = AICache.key(kind: .stock, subject: "AAPL", language: "en")
        #expect(a != AICache.key(kind: .stock, subject: "AAPL", language: "es"))
        #expect(a != AICache.key(kind: .stock, subject: "MSFT", language: "en"))
        #expect(a.hasPrefix(AICache.day()))
    }

    @Test func briefParsingToleratesShapes() throws {
        let json = """
        {"date":"2026-11-24","indices":[{"id":"sp500","change1d":0.5}],
         "topGainers":[{"ticker":"AAPL","name":"Apple","change":4.0}],
         "topLosers":[{"symbol":"XOM","changePct":-3}],
         "sectors":[{"name":"Energy","change":-1.0}],
         "headlines":[{"title":"Stocks rise","publisher":"AP","url":"https://x.test","ticker":"AAPL"}]}
        """
        let b = try #require(AIService.parseBrief(Data(json.utf8)))
        #expect(b.indices.first?.change1d == 0.5)
        #expect(b.topGainers.first == AINamedChange(name: "AAPL", change: 4.0))
        #expect(b.topLosers.first == AINamedChange(name: "XOM", change: -3))
        #expect(b.headlines.count == 1)
    }
}
