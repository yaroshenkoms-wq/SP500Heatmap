import Foundation

/// Готовый вопрос чата. Те же вопросы работают как «быстрые ответы» без модели:
/// ответ собирается шаблоном из тех же данных, что получают инструменты.
enum AIQuestion: Hashable, Identifiable {
    case marketToday
    case compare(String, String)
    case dividends(indexId: String)
    case portfolio
    case stock(String)

    var id: String {
        switch self {
        case .marketToday: return "market"
        case .compare(let a, let b): return "compare:\(a):\(b)"
        case .dividends(let i): return "dividends:\(i)"
        case .portfolio: return "portfolio"
        case .stock(let t): return "stock:\(t)"
        }
    }

    static let suggested: [AIQuestion] = [.marketToday, .compare("AAPL", "MSFT"), .dividends(indexId: "ibex35"), .portfolio]

    /// Текст вопроса на языке `code`.
    func text(_ code: String, indexName: (String) -> String = { $0 == "ibex35" ? "IBEX 35" : $0 }) -> String {
        switch self {
        case .marketToday: return AIL.s("Why is the market down today?", code)
        case .compare(let a, let b): return AIL.f("Compare %1$@ and %2$@", code, a, b)
        case .dividends(let i): return AIL.f("Best dividend stocks in %@", code, indexName(i))
        case .portfolio: return AIL.s("How is my portfolio doing?", code)
        case .stock(let t): return AIL.f("Why is %@ moving today?", code, t)
        }
    }
}

struct AIQuickAnswer: Equatable {
    var lines: [String]
    var sources: [AIHeadline] = []
}

enum AIQuickTemplates {
    private static func change(_ v: Double?, _ code: String) -> String {
        v.map { AIL.pct($0, code, signed: true) } ?? "—"
    }

    private static func plain(_ v: Double?, _ code: String, digits: Int = 1) -> String {
        v.map { $0.formatted(.number.precision(.fractionLength(digits)).locale(AIL.locale(code))) } ?? "—"
    }

    static func quoteLine(_ q: AIQuoteFacts, _ code: String) -> String {
        guard q.last != nil else { return AIL.f("No price data available for %@.", code, q.ticker) }
        return AIL.f("%1$@: %2$@ today, %3$@ over 1 month, %4$@ year to date.", code, q.ticker,
                     change(q.change1d, code), change(q.change1M, code), change(q.changeYTD, code))
    }

    static func compare(_ a: AIQuoteFacts, _ b: AIQuoteFacts, _ code: String) -> AIQuickAnswer {
        var lines = [quoteLine(a, code), quoteLine(b, code)]
        for q in [a, b] where q.last != nil && (q.pe != nil || (q.divYield ?? 0) > 0) {
            let y = (q.divYield ?? 0) > 0 ? AIL.pct(q.divYield!, code) : "—"
            lines.append(AIL.f("%1$@ — P/E %2$@, dividend yield %3$@.", code, q.ticker, plain(q.pe, code), y))
        }
        if let x = a.change1M, let y = b.change1M {
            let (w, l) = x >= y ? (a, b) : (b, a)
            lines.append(AIL.f("Stronger over 1 month: %1$@ (%2$@ vs %3$@).", code, w.ticker,
                               change(w.change1M, code), change(l.change1M, code)))
        }
        return AIQuickAnswer(lines: lines)
    }

    static func dividends(_ rows: [ScreenerRow], indexName: String, _ code: String, limit: Int = 8) -> AIQuickAnswer {
        let top = rows.filter { ($0.divYield ?? 0) > 0 }.prefix(limit)
        guard !top.isEmpty else { return AIQuickAnswer(lines: [AIL.s("The screener returned no stocks right now.", code)]) }
        var lines = [AIL.f("Highest dividend yields in %@:", code, indexName)]
        for r in top {
            let name = r.name ?? r.ticker
            let y = AIL.pct(r.divYield ?? 0, code)
            if let pe = r.pe {
                lines.append(AIL.f("%1$@ (%2$@): dividend yield %3$@, P/E %4$@", code, r.ticker, name, y, plain(pe, code)))
            } else {
                lines.append(AIL.f("%1$@ (%2$@): dividend yield %3$@", code, r.ticker, name, y))
            }
        }
        return AIQuickAnswer(lines: lines)
    }

    /// Рынок, бумага и личный портфель — те же шаблоны, что у карточек ИИ.
    static func fromInsight(_ i: AIInsight) -> AIQuickAnswer {
        AIQuickAnswer(lines: [i.headline] + i.reasons, sources: i.sources)
    }

    static func noPortfolio(_ code: String) -> AIQuickAnswer {
        AIQuickAnswer(lines: [AIL.s("Add transactions in the Portfolio tab first, then I can summarize it.", code)])
    }

    static func portfolio(_ result: PfResult, _ code: String) -> AIQuickAnswer {
        let holdings = result.holdings.map(PortfolioInsightHolding.init)
        var facts = AIFacts(kind: .portfolio, subject: "portfolio")
        facts.portfolio = AIPortfolioSummary.make(holdings)
        guard facts.hasContent else { return noPortfolio(code) }
        return fromInsight(AITemplate.make(facts, language: code))
    }
}

/// Быстрые ответы: загрузка данных + шаблон. Работает на любом устройстве.
enum AIQuickAnswers {
    static func answer(_ q: AIQuestion, code: String) async -> AIQuickAnswer {
        switch q {
        case .marketToday:
            let facts = await AIService.marketFacts()
            return AIQuickTemplates.fromInsight(AITemplate.make(facts, language: code))
        case .compare(let a, let b):
            async let qa = AIToolData.quoteFacts(a)
            async let qb = AIToolData.quoteFacts(b)
            return AIQuickTemplates.compare(await qa, await qb, code)
        case .dividends(let id):
            var f = ScreenerFilters()
            f.preset = "dividend"; f.index = id
            (f.sort, f.ascending) = ScreenerFilters.defaultSort(for: "dividend")
            let rows = (try? await NetworkService.shared.fetchScreener(f.query()))?.rows ?? []
            let name = await MainActor.run { IndexStore.shared.indices.first { $0.id == id }?.name } ?? (id == "ibex35" ? "IBEX 35" : id)
            return AIQuickTemplates.dividends(rows, indexName: name, code)
        case .portfolio:
            guard let r = await AIToolData.portfolioResult() else { return AIQuickTemplates.noPortfolio(code) }
            return AIQuickTemplates.portfolio(r.result, code)
        case .stock(let t):
            let facts = await AIService.stockFacts(ticker: t)
            return AIQuickTemplates.fromInsight(AITemplate.make(facts, language: code))
        }
    }
}
