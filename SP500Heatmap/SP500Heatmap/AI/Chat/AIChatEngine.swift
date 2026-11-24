import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Чат на устройстве: сессия FoundationModels с инструментами. Приложение собирается под iOS 18.5,
/// поэтому всё за проверкой версии; без модели `isUsable` = false и работает режим быстрых ответов.
enum AIChatEngine {
    static func isUsable(languageCode: String) -> Bool { AIEngine.isUsable(languageCode: languageCode) }

    /// Правила для модели. Отдельная чистая функция — проверяется тестом.
    static func instructions(languageCode: String, today: String) -> String {
        """
        You are the assistant inside a stock heatmap app. Today is \(today).
        Rules:
        - Answer ONLY with data returned by your tools. Before stating any price, change, ratio, headline, \
        ranking or portfolio number, call the right tool. If no tool provides the data, say you do not have it.
        - Cite the numbers and dates exactly as the tools return them. Never recalculate, round differently or invent values.
        - Never give investment advice, recommendations, price targets or predictions. Never say or imply that \
        someone should buy, sell or hold. If asked for advice or a forecast, say you can only describe data, \
        and give the relevant facts instead.
        - For questions such as "why is the market down", call getIndex and getNews and describe what the data \
        shows. If the headlines do not explain the move, say so.
        - Use getPortfolio only for questions about the user's own portfolio, getModelPortfolio for named model portfolios.
        - Keep answers short: 2 to 6 sentences or a short list. The app adds a disclaimer, do not repeat it.
        - Write the answer in \(AIPromptBuilder.languageName(languageCode)). Keep tickers, company names and numbers unchanged.
        """
    }

    static var today: String { AIToolFormat.string(Date()) }

    /// Подсказка, когда модели нет: что именно не так (для заметки в окне чата).
    static func unavailableReason() -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .unavailable = SystemLanguageModel.default.availability { return "model" }
            return nil
        }
        #endif
        return "os"
    }
}

enum AIChatError: Error { case unavailable, failed, refused }

/// Одна беседа. Хранит сессию модели (контекст разговора) и сбрасывает её при смене языка.
@MainActor
final class AIChatSessionBox {
    private var session: Any?
    private var code = ""

    func reset() { session = nil }

    /// Отправляет вопрос; `onUpdate` получает накопленный текст ответа по мере генерации.
    func send(_ prompt: String, code: String, onUpdate: @escaping (String) -> Void) async throws {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if self.code != code { session = nil; self.code = code }
            do {
                try await run(prompt, code: code, onUpdate: onUpdate)
            } catch let e as LanguageModelSession.GenerationError {
                switch e {
                case .exceededContextWindowSize:
                    session = nil          // длинная беседа: начинаем заново, вопрос повторяем один раз
                    try await run(prompt, code: code, onUpdate: onUpdate)
                case .guardrailViolation, .refusal: throw AIChatError.refused
                default: throw AIChatError.failed
                }
            }
            return
        }
        #endif
        throw AIChatError.unavailable
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func run(_ prompt: String, code: String, onUpdate: @escaping (String) -> Void) async throws {
        let s: LanguageModelSession
        if let existing = session as? LanguageModelSession { s = existing } else {
            s = LanguageModelSession(tools: AIChatTools.all,
                                     instructions: AIChatEngine.instructions(languageCode: code, today: AIChatEngine.today))
            session = s
        }
        let stream = s.streamResponse(to: prompt, options: GenerationOptions(temperature: 0.2))
        for try await snapshot in stream { onUpdate(snapshot.content) }
    }
    #endif
}
