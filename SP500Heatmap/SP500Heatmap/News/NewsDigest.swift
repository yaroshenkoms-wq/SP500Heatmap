import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Краткая сводка последних заголовков: «ИИ-дайджест» в начале экрана новостей.
struct NewsDigest: Equatable {
    var summary: String
    var points: [String]
    var usedModel: Bool
    var language: String
}

enum NewsDigestBuilder {
    static let maxHeadlines = 12

    /// Шаблон без модели: пять первых заголовков, сгруппированных по бумаге (порядок — по свежести).
    static func template(_ items: [NewsArticle], code: String) -> NewsDigest {
        let top = Array(items.prefix(5))
        guard !top.isEmpty else {
            return NewsDigest(summary: AIL.s("No news to summarize.", code), points: [], usedModel: false, language: code)
        }
        var order: [String] = []
        var groups: [String: [String]] = [:]
        for a in top {
            let key = a.tickers.first ?? ""
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(a.title)
        }
        let market = AIL.s("General market", code)
        let points = order.map { key in
            AIL.f("%1$@: %2$@", code, key.isEmpty ? market : key, (groups[key] ?? []).joined(separator: " · "))
        }
        return NewsDigest(summary: AIL.f("Top %lld headlines", code, top.count), points: points, usedModel: false, language: code)
    }

    static func instructions(languageCode: String) -> String {
        """
        You are a neutral news digest writer inside a stock heatmap app.
        Rules:
        - Use ONLY the numbered headlines in the user message. Do not use outside knowledge.
        - Never give investment advice, recommendations, price targets or predictions.
        - Do not invent numbers, causes or companies. Do not claim a headline proves something it does not say.
        - Summary: at most two short sentences describing the main themes. Key points: 2 to 4 short sentences, \
        each naming the company or topic it is about.
        - Write every text field in \(AIPromptBuilder.languageName(languageCode)). Keep tickers, company names and numbers unchanged.
        """
    }

    static func prompt(_ items: [NewsArticle]) -> String {
        var out = ["Task: summarize the main themes of these recent headlines.", "Headlines:"]
        for (i, a) in items.prefix(maxHeadlines).enumerated() {
            var line = "[\(i + 1)] \(a.title)"
            var extra: [String] = []
            if let p = a.publisher, !p.isEmpty { extra.append(p) }
            if !a.tickers.isEmpty { extra.append(a.tickers.prefix(3).joined(separator: ",")) }
            if !extra.isEmpty { line += " (" + extra.joined(separator: "; ") + ")" }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// Ключ кэша: заголовки (первые 12) + язык.
    static func key(_ items: [NewsArticle], code: String) -> String {
        var h: UInt64 = 5381
        for a in items.prefix(maxHeadlines) { for b in a.url.utf8 { h = (h &* 33) &+ UInt64(b) } }
        return "\(code)|\(String(h, radix: 16))"
    }

    /// Модель, если она есть и знает язык; иначе шаблон.
    static func make(_ items: [NewsArticle], code: String) async -> NewsDigest {
        guard !items.isEmpty else { return template(items, code: code) }
        if AIEngine.isUsable(languageCode: code), let d = await modelDigest(items, code: code) { return d }
        return template(items, code: code)
    }

    private static func modelDigest(_ items: [NewsArticle], code: String) async -> NewsDigest? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return try? await Impl.generate(items, code: code)
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
private struct GeneratedDigest {
    @Guide(description: "At most two short neutral sentences about the main themes. No advice, no predictions.")
    var summary: String
    @Guide(description: "Two to four short sentences, each about one company or topic from the headlines.", .count(2...4))
    var points: [String]
}

@available(iOS 26.0, *)
private enum Impl {
    static func generate(_ items: [NewsArticle], code: String) async throws -> NewsDigest? {
        let session = LanguageModelSession(instructions: NewsDigestBuilder.instructions(languageCode: code))
        let r = try await session.respond(to: NewsDigestBuilder.prompt(items), generating: GeneratedDigest.self,
                                          options: GenerationOptions(temperature: 0.2))
        guard !r.content.summary.isEmpty else { return nil }
        return NewsDigest(summary: r.content.summary, points: r.content.points, usedModel: true, language: code)
    }
}
#endif
