import Foundation

private final class AIBundleToken {}

/// Локализация для текстов ИИ на любом из 9 языков (не только на выбранном в приложении),
/// чтобы шаблон можно было проверить в тестах для каждого языка.
enum AIL {
    static func bundle(_ code: String) -> Bundle {
        let main = Bundle(for: AIBundleToken.self)
        guard let path = main.path(forResource: code, ofType: "lproj"), let b = Bundle(path: path) else { return main }
        return b
    }

    static func locale(_ code: String) -> Locale { Locale(identifier: code) }

    static func s(_ key: String, _ code: String) -> String {
        bundle(code).localizedString(forKey: key, value: key, table: nil)
    }

    static func f(_ key: String, _ code: String, _ args: CVarArg...) -> String {
        String(format: s(key, code), locale: locale(code), arguments: args)
    }

    /// 1.234 -> "1,23%" по правилам языка.
    static func pct(_ v: Double, _ code: String, signed: Bool = false) -> String {
        var style = FloatingPointFormatStyle<Double>.Percent.percent.precision(.fractionLength(2)).locale(locale(code))
        if signed { style = style.sign(strategy: .always(includingZero: false)) }
        return (v / 100).formatted(style)
    }

    static func num(_ v: Double, _ code: String) -> String {
        v.formatted(.number.precision(.fractionLength(1)).locale(locale(code)))
    }
}

/// Текст без модели: собирается из тех же чисел и заголовков, на любом из 9 языков.
enum AITemplate {
    static let flat = 0.1   // |изменение| меньше — «почти без изменений»

    static func sentiment(_ change: Double?) -> AISentiment {
        guard let c = change else { return .mixed }
        if c > 0.3 { return .up }
        if c < -0.3 { return .down }
        return .mixed
    }

    private static func moveLine(_ key: (up: String, down: String, flat: String), name: String?, change: Double, _ code: String) -> String {
        let k = abs(change) < flat ? key.flat : (change > 0 ? key.up : key.down)
        let p = AIL.pct(abs(change), code)
        return name.map { AIL.f(k, code, $0, p) } ?? AIL.f(k, code, p)
    }

    private static let dayKeys = (up: "%@ is up %@ today.", down: "%@ is down %@ today.", flat: "%@ is little changed today (%@).")

    static func make(_ f: AIFacts, language code: String) -> AIInsight {
        switch f.kind {
        case .stock: return stock(f, code)
        case .market: return market(f, code)
        case .portfolio: return portfolio(f, code)
        }
    }

    private static func quote(_ h: AIHeadline, _ code: String) -> String { AIL.f("Headline: “%@”", code, h.title) }

    private static func result(_ headline: String, _ reasons: [String], _ s: AISentiment,
                               _ sources: [AIHeadline], _ code: String) -> AIInsight {
        AIInsight(headline: headline, reasons: reasons, sentiment: s, confidence: .low,
                  sources: sources, usedModel: false, language: code)
    }

    private static func stock(_ f: AIFacts, _ code: String) -> AIInsight {
        guard f.hasContent else { return empty(code) }
        var reasons: [String] = []
        var headline: String
        if let c = f.changePct {
            headline = moveLine(dayKeys, name: f.subject, change: c, code)
            if let b = f.benchmark {
                let key = c >= b.change ? "Ahead of %1$@ (%2$@ today)." : "Behind %1$@ (%2$@ today)."
                reasons.append(AIL.f(key, code, b.name, AIL.pct(b.change, code, signed: true)))
            }
            if let s = f.sector {
                reasons.append(AIL.f("Sector %1$@ is %2$@ today.", code, s.name, AIL.pct(s.change, code, signed: true)))
            }
        } else {
            headline = AIL.f("No price change available for %@ yet.", code, f.subject)
        }
        let used = Array(f.headlines.prefix(2))
        reasons += used.map { quote($0, code) }
        if f.headlines.isEmpty && f.changePct != nil {
            reasons.append(AIL.s("No recent headlines explain the move.", code))
        }
        return result(headline, reasons, sentiment(f.changePct), used, code)
    }

    private static func market(_ f: AIFacts, _ code: String) -> AIInsight {
        guard f.hasContent else { return empty(code) }
        let changes = f.indices.map(\.change)
        let ups = changes.filter { $0 > flat }.count, downs = changes.filter { $0 < -flat }.count
        // Большинство решает: при 4 индексах вверх и 1 вниз это «в основном растут», а не «разнонаправленно».
        let s: AISentiment = ups > 0 && ups >= 2 * downs ? .up : (downs > 0 && downs >= 2 * ups ? .down : .mixed)
        let headline: String
        switch s {
        case .up: headline = AIL.s("Markets are mostly higher today.", code)
        case .down: headline = AIL.s("Markets are mostly lower today.", code)
        case .mixed: headline = AIL.s("Markets are mixed today.", code)
        }
        var reasons: [String] = []
        if !f.indices.isEmpty {
            reasons.append(AIL.f("Indices: %@", code, f.indices.prefix(4).map { "\($0.name) \(AIL.pct($0.change, code, signed: true))" }.joined(separator: ", ")))
        }
        if let g = f.gainers.first {
            reasons.append(AIL.f("Top gainer: %1$@ (%2$@).", code, g.name, AIL.pct(g.change, code, signed: true)))
        }
        if let l = f.losers.first {
            reasons.append(AIL.f("Top loser: %1$@ (%2$@).", code, l.name, AIL.pct(l.change, code, signed: true)))
        }
        if let best = f.sectors.max(by: { $0.change < $1.change }) {
            reasons.append(AIL.f("Strongest sector: %1$@ (%2$@).", code, best.name, AIL.pct(best.change, code, signed: true)))
        }
        let used = Array(f.headlines.prefix(2))
        reasons += used.map { quote($0, code) }
        return result(headline, Array(reasons.prefix(6)), s, used, code)
    }

    private static func portfolio(_ f: AIFacts, _ code: String) -> AIInsight {
        guard let p = f.portfolio else { return empty(code) }
        let headline = moveLine((up: "Your portfolio is up %@ today.", down: "Your portfolio is down %@ today.",
                                 flat: "Your portfolio is little changed today (%@)."),
                                name: nil, change: p.dayChangePct, code)
        var reasons: [String] = []
        if let l = p.largest {
            reasons.append(AIL.f("Largest position: %1$@ (%2$@ of the portfolio).", code, l.name, AIL.pct(l.change, code)))
        }
        if let b = p.bestContributor { reasons.append(AIL.f("Helped most today: %1$@ (%2$@).", code, b.name, AIL.pct(b.change, code, signed: true))) }
        if let w = p.worstContributor { reasons.append(AIL.f("Hurt most today: %1$@ (%2$@).", code, w.name, AIL.pct(w.change, code, signed: true))) }
        if let s = p.topSector { reasons.append(AIL.f("Largest sector: %1$@ (%2$@).", code, s.name, AIL.pct(s.change, code))) }
        reasons.append(AIL.f("Result since purchase: %@.", code, AIL.pct(p.totalPLPct, code, signed: true)))
        let used = Array(f.headlines.prefix(2))
        reasons += used.map { quote($0, code) }
        return result(headline, reasons, sentiment(p.dayChangePct), used, code)
    }

    static func empty(_ code: String) -> AIInsight {
        result(AIL.s("Not enough data for a summary.", code), [], .mixed, [], code)
    }
}
