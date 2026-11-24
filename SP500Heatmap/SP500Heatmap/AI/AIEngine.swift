import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Обёртка над Apple FoundationModels. Приложение собирается под iOS 18.5, поэтому всё —
/// за проверкой версии: на устройствах без модели (или с выключенным Apple Intelligence)
/// `isUsable` = false и работает шаблон.
enum AIEngine {
    static func isUsable(languageCode: String) -> Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return Impl.isUsable(languageCode: languageCode) }
        #endif
        return false
    }

    static func generate(_ facts: AIFacts, languageCode: String) async throws -> AIInsight {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return try await Impl.generate(facts, languageCode: languageCode) }
        #endif
        throw AIEngineError.unavailable
    }
}

enum AIEngineError: Error { case unavailable }

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct GeneratedReason {
    @Guide(description: "One short sentence that cites numbers from the facts.")
    var text: String
    @Guide(description: "Numbers of the headlines this reason relies on; empty if it uses only numbers.")
    var headlineNumbers: [Int]
}

@available(iOS 26.0, *)
@Generable
enum GeneratedSentiment { case up, down, mixed }

@available(iOS 26.0, *)
@Generable
enum GeneratedConfidence { case low, medium, high }

@available(iOS 26.0, *)
@Generable
struct GeneratedInsight {
    @Guide(description: "One short neutral sentence, at most 20 words, describing the move. No advice, no predictions.")
    var headline: String
    @Guide(description: "Two to four reasons based only on the given facts.", .count(2...4))
    var reasons: [GeneratedReason]
    @Guide(description: "Direction of the move: up, down, or mixed.")
    var sentiment: GeneratedSentiment
    @Guide(description: "How well the headlines explain the move: low if they do not.")
    var confidence: GeneratedConfidence
}

@available(iOS 26.0, *)
private enum Impl {
    static func supports(_ model: SystemLanguageModel, _ code: String) -> Bool {
        let lang = Locale.Language(identifier: code)
        return model.supportedLanguages.contains { $0.languageCode == lang.languageCode &&
            (lang.script == nil || $0.script == nil || $0.script == lang.script) }
    }

    static func isUsable(languageCode: String) -> Bool {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return false }
        return supports(model, languageCode)
    }

    static func generate(_ facts: AIFacts, languageCode: String) async throws -> AIInsight {
        let session = LanguageModelSession(instructions: AIPromptBuilder.instructions(languageCode: languageCode))
        let response = try await session.respond(to: AIPromptBuilder.prompt(facts),
                                                 generating: GeneratedInsight.self,
                                                 options: GenerationOptions(temperature: 0.2))
        let g = response.content
        let cited = g.reasons.flatMap(\.headlineNumbers)
        var sources: [AIHeadline] = []
        for n in cited where n >= 1 && n <= facts.headlines.count {
            let h = facts.headlines[n - 1]
            if !sources.contains(h) { sources.append(h) }
        }
        let sentiment: AISentiment = { switch g.sentiment { case .up: .up; case .down: .down; case .mixed: .mixed } }()
        let confidence: AIConfidence = { switch g.confidence { case .low: .low; case .medium: .medium; case .high: .high } }()
        return AIInsight(headline: g.headline, reasons: g.reasons.map(\.text), sentiment: sentiment,
                         confidence: confidence, sources: sources, usedModel: true, language: languageCode)
    }
}
#endif
