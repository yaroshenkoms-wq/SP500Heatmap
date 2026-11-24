import Foundation
#if canImport(FoundationModels)
import FoundationModels

/// Инструменты, которыми модель берёт данные. Каждый возвращает готовый текст из AIToolData.
@available(iOS 26.0, *)
enum AIChatTools {
    static var all: [any Tool] {
        [QuoteTool(), IndexTool(), FinancialsTool(), NewsTool(), ScreenTool(), PortfolioTool(), ModelPortfolioTool()]
    }
}

@available(iOS 26.0, *)
struct QuoteTool: Tool {
    let name = "getQuote"
    let description = "Latest price, change today, over 1 month and year to date, 52-week range, P/E and dividend yield of one stock or crypto."
    @Generable struct Arguments {
        @Guide(description: "Ticker symbol such as AAPL, SAN.MC or BTC-USD, or a company name")
        var ticker: String
    }
    func call(arguments: Arguments) async throws -> String { await AIToolData.quote(arguments.ticker) }
}

@available(iOS 26.0, *)
struct IndexTool: Tool {
    let name = "getIndex"
    let description = "Price changes (1 day, 7 days, 30 days, 1 year) of a stock index such as S&P 500, IBEX 35, DAX, or of the main world indices."
    @Generable struct Arguments {
        @Guide(description: "Index name or id, e.g. sp500, ibex35, DAX. Use 'all' for the main world indices.")
        var indexId: String
    }
    func call(arguments: Arguments) async throws -> String { await AIToolData.index(arguments.indexId) }
}

@available(iOS 26.0, *)
struct FinancialsTool: Tool {
    let name = "getFinancials"
    let description = "Summary of a company's financial statements: revenue, net income, EPS, margins, debt, ratios and analyst consensus."
    @Generable struct Arguments {
        @Guide(description: "Ticker symbol or company name")
        var ticker: String
    }
    func call(arguments: Arguments) async throws -> String { await AIToolData.financials(arguments.ticker) }
}

@available(iOS 26.0, *)
struct NewsTool: Tool {
    let name = "getNews"
    let description = "Latest news headlines with publisher and date, for one company or for the whole market."
    @Generable struct Arguments {
        @Guide(description: "Ticker symbol or company name; use 'market' for general market news")
        var subject: String
    }
    func call(arguments: Arguments) async throws -> String { await AIToolData.news(arguments.subject) }
}

@available(iOS 26.0, *)
struct ScreenTool: Tool {
    let name = "screen"
    let description = "Top stocks from the screener: gainers, losers, most active, dividend, value (low P/E), 52-week highs or lows."
    @Generable struct Arguments {
        @Guide(description: "Screener preset", .anyOf(["gainers", "losers", "active", "dividend", "value", "highs52", "lows52"]))
        var preset: String
        @Guide(description: "Index name or id, e.g. ibex35 or sp500; 'all' for every index")
        var indexId: String
    }
    func call(arguments: Arguments) async throws -> String {
        await AIToolData.screen(preset: arguments.preset, indexId: arguments.indexId)
    }
}

@available(iOS 26.0, *)
struct PortfolioTool: Tool {
    let name = "getPortfolio"
    let description = "The user's own portfolio in the app: value, result today and since purchase, largest positions."
    @Generable struct Arguments {
        @Guide(description: "Always 'mine'")
        var which: String
    }
    func call(arguments: Arguments) async throws -> String { await AIToolData.portfolio() }
}

@available(iOS 26.0, *)
struct ModelPortfolioTool: Tool {
    let name = "getModelPortfolio"
    let description = "Historical metrics of a model portfolio (e.g. all weather, 60/40, permanent portfolio): weights, annualized return, maximum drawdown, volatility, best and worst year."
    @Generable struct Arguments {
        @Guide(description: "Model portfolio key or name")
        var key: String
    }
    func call(arguments: Arguments) async throws -> String { await AIToolData.modelPortfolio(arguments.key) }
}
#endif
