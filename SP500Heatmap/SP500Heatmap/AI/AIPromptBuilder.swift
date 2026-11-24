import Foundation

/// Собирает инструкции и промпт для модели. Только факты, которые мы передали:
/// числа и заголовки. Никаких советов и прогнозов.
enum AIPromptBuilder {
    static func languageName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
    }

    static func instructions(languageCode: String) -> String {
        """
        You are a neutral market-data summarizer inside a stock heatmap app.
        Rules:
        - Use ONLY the facts in the user message (numbers and numbered headlines). Do not use outside knowledge.
        - Never give investment advice, recommendations, price targets or predictions. Never say or imply \
        that someone should buy, sell or hold. Do not speculate about the future.
        - Do not invent numbers, causes or companies. If the headlines do not explain the move, say that \
        the reason is not clear from the available headlines.
        - Every reason must cite the numbers it uses and, when it relies on a headline, the headline number in headlineNumbers.
        - Headline: one short sentence (at most 20 words). Give 2 to 4 reasons, each one short sentence.
        - Write every text field in \(languageName(languageCode)). Keep tickers, company names and numbers unchanged.
        """
    }

    static func pct(_ v: Double) -> String { String(format: "%+.2f%%", v) }

    static func line(_ c: AINamedChange) -> String { "\(c.name) \(pct(c.change))" }

    static func prompt(_ f: AIFacts) -> String {
        var out: [String] = []
        switch f.kind {
        case .stock:
            out.append("Task: explain, using only the facts below, why \(f.subject)\(f.name.isEmpty ? "" : " (\(f.name))") moved today.")
            if let c = f.changePct { out.append("\(f.subject) today: \(pct(c))") }
            if let b = f.benchmark { out.append("Index \(b.name) today: \(pct(b.change))") }
            if let s = f.sector { out.append("Sector \(s.name) today: \(pct(s.change))") }
        case .market:
            out.append("Task: summarize today's market using only the facts below.")
            if !f.indices.isEmpty { out.append("Indices today: " + f.indices.map(line).joined(separator: "; ")) }
            if !f.gainers.isEmpty { out.append("Top gainers: " + f.gainers.map(line).joined(separator: "; ")) }
            if !f.losers.isEmpty { out.append("Top losers: " + f.losers.map(line).joined(separator: "; ")) }
            if !f.sectors.isEmpty { out.append("Sectors today: " + f.sectors.map(line).joined(separator: "; ")) }
        case .portfolio:
            out.append("Task: review today's result of a personal portfolio using only the facts below.")
            if let p = f.portfolio {
                out.append("Positions: \(p.count)")
                out.append("Portfolio today: \(pct(p.dayChangePct)); since purchase: \(pct(p.totalPLPct))")
                if let l = p.largest { out.append("Largest position: \(l.name), \(String(format: "%.1f", l.change))% of portfolio\(p.largestDay.map { ", today \(pct($0))" } ?? "")") }
                if let b = p.bestContributor { out.append("Best contributor today: \(b.name), \(String(format: "%+.2f", b.change)) percentage points") }
                if let w = p.worstContributor { out.append("Worst contributor today: \(w.name), \(String(format: "%+.2f", w.change)) percentage points") }
                if let s = p.topSector { out.append("Largest sector: \(s.name), \(String(format: "%.1f", s.change))%") }
                if let c = p.topCountry { out.append("Largest country: \(c.name), \(String(format: "%.1f", c.change))%") }
            }
        }
        if f.headlines.isEmpty {
            out.append("Headlines: none available.")
        } else {
            out.append("Headlines:")
            for (i, h) in f.headlines.enumerated() {
                out.append("[\(i + 1)] \(h.title)" + (h.publisher.map { " (\($0))" } ?? ""))
            }
        }
        return out.joined(separator: "\n")
    }
}
