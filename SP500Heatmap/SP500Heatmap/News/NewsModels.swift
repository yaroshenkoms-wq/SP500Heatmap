import Foundation

// Новости: модель, загрузка (GET /api/v1/news) и запасные пути, если сервер ещё без этого адреса.
// Ничего здесь не зависит от интерфейса и модели ИИ — всё проверяется тестами.

struct NewsArticle: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let publisher: String?
    let url: String
    let published: String?
    let tickers: [String]
    let lang: String?

    init(id: String? = nil, title: String, publisher: String?, url: String, published: String?,
         tickers: [String] = [], lang: String? = nil) {
        self.id = id ?? url
        self.title = title; self.publisher = publisher; self.url = url
        self.published = published; self.tickers = tickers; self.lang = lang
    }

    enum CodingKeys: String, CodingKey { case id, title, publisher, url, published, tickers, lang }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let url = try c.decode(String.self, forKey: .url)
        self.url = url
        title = try c.decode(String.self, forKey: .title)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? url
        publisher = try? c.decodeIfPresent(String.self, forKey: .publisher)
        published = try? c.decodeIfPresent(String.self, forKey: .published)
        tickers = ((try? c.decodeIfPresent([String].self, forKey: .tickers)) ?? nil) ?? []
        lang = try? c.decodeIfPresent(String.self, forKey: .lang)
    }

    var date: Date? { NewsFormat.parse(published) }
    var link: URL? {
        guard let u = URL(string: url), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return nil }
        return u
    }
    var asHeadline: AIHeadline { AIHeadline(title: title, publisher: publisher, url: url, ticker: tickers.first) }
}

/// Что показывать: весь рынок, выбранный индекс или список бумаг.
enum NewsScope: Hashable {
    case market
    case index(String)
    case tickers([String])

    var queryItems: [URLQueryItem] {
        switch self {
        case .market: return [URLQueryItem(name: "scope", value: "market")]
        case .index(let id): return [URLQueryItem(name: "scope", value: "index"), URLQueryItem(name: "indexId", value: id)]
        case .tickers(let t): return [URLQueryItem(name: "scope", value: "tickers"),
                                      URLQueryItem(name: "tickers", value: t.joined(separator: ","))]
        }
    }

    var cacheKey: String {
        switch self {
        case .market: return "market"
        case .index(let id): return "index:\(id)"
        case .tickers(let t): return "tickers:\(t.joined(separator: ","))"
        }
    }
}

/// Фильтр по языку источника.
enum NewsLanguageFilter: String, CaseIterable, Identifiable {
    case all, mine
    var id: String { rawValue }
}

enum NewsFormat {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func iso(_ date: Date) -> String { plain.string(from: date) }

    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return plain.date(from: raw) ?? withFraction.date(from: raw)
    }

    /// «5 мин. назад» на языке интерфейса; пустая строка, если даты нет.
    static func relative(_ date: Date?, now: Date = Date(), locale: Locale = AppLanguage.locale) -> String {
        guard let date else { return "" }
        let f = RelativeDateTimeFormatter()
        f.locale = locale
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: now)
    }

    /// Строка «издатель · время» под заголовком.
    static func meta(_ a: NewsArticle, now: Date = Date(), locale: Locale = AppLanguage.locale) -> String {
        var parts: [String] = []
        if let p = a.publisher, !p.isEmpty { parts.append(p) }
        let r = relative(a.date, now: now, locale: locale)
        if !r.isEmpty { parts.append(r) }
        return parts.joined(separator: " · ")
    }
}

enum NewsLogic {
    /// Убирает повторы по адресу и по одинаковому заголовку, новые сверху, без даты — в конец.
    static func clean(_ items: [NewsArticle], limit: Int = 60) -> [NewsArticle] {
        var seenURL = Set<String>(), seenTitle = Set<String>()
        var out: [NewsArticle] = []
        for a in items where a.link != nil {
            let t = a.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seenURL.insert(a.url).inserted, seenTitle.insert(t).inserted else { continue }
            out.append(a)
        }
        let sorted = out.enumerated().sorted { a, b in
            switch (a.element.date, b.element.date) {
            case let (x?, y?): return x == y ? a.offset < b.offset : x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
        return Array(sorted.prefix(limit))
    }

    /// Язык статьи; без пометки считаем английским (так отдают Yahoo и Finnhub).
    static func language(_ a: NewsArticle) -> String {
        let l = (a.lang ?? "en").lowercased()
        return l.hasPrefix("zh") ? "zh-Hans" : String(l.prefix(2))
    }

    static func filter(_ items: [NewsArticle], _ f: NewsLanguageFilter, code: String) -> [NewsArticle] {
        guard f == .mine else { return items }
        let want = code == "zh-Hans" ? "zh-Hans" : String(code.prefix(2))
        return items.filter { language($0) == want }
    }

    /// Есть ли среди новостей хотя бы одна не на английском — тогда показываем выбор языка.
    static func hasLocalLanguage(_ items: [NewsArticle], code: String) -> Bool {
        !filter(items, .mine, code: code).isEmpty && code != "en"
    }
}

// MARK: Загрузка

private struct NewsResponse: Decodable {
    let items: [NewsArticle]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        // Элементы декодируем по одному: одна «битая» запись не должна ронять весь список.
        var list: [NewsArticle] = []
        if var arr = try? c.nestedUnkeyedContainer(forKey: .items) {
            while !arr.isAtEnd {
                if let a = try? arr.decode(NewsArticle.self) { list.append(a) } else { _ = try? arr.decode(Skip.self) }
            }
        }
        items = list
    }
    enum Keys: String, CodingKey { case items }
    private struct Skip: Decodable {}
}

enum NewsService {
    static func url(scope: NewsScope, lang: String, limit: Int = 50) -> URL? {
        guard var comps = URLComponents(string: "\(Config.baseURL)/api/v1/news") else { return nil }
        comps.queryItems = scope.queryItems + [URLQueryItem(name: "lang", value: lang),
                                               URLQueryItem(name: "limit", value: String(limit))]
        return comps.url
    }

    static func parse(_ data: Data) -> [NewsArticle]? {
        (try? JSONDecoder().decode(NewsResponse.self, from: data))?.items
    }

    /// nil — ничего получить не удалось (сеть); пустой список — новостей нет.
    static func fetch(scope: NewsScope, lang: String) async -> [NewsArticle]? {
        if let url = url(scope: scope, lang: lang),
           let data = try? await NetworkService.shared.fetchData(url, timeout: 20),
           let items = parse(data) {
            return NewsLogic.clean(items)
        }
        return await fallback(scope: scope)
    }

    /// Сервер без /news: списки бумаг — из /company, рынок и индекс — из заголовков сводки.
    private static func fallback(scope: NewsScope) async -> [NewsArticle]? {
        switch scope {
        case .tickers(let list):
            let tickers = Array(list.prefix(10))
            guard !tickers.isEmpty else { return [] }
            var all: [NewsArticle] = []
            var anySuccess = false
            await withTaskGroup(of: (String, CompanyInfo?).self) { g in
                for t in tickers { g.addTask { (t, try? await NetworkService.shared.fetchCompanyInfo(ticker: t)) } }
                for await (t, info) in g {
                    guard let info else { continue }
                    anySuccess = true
                    all += info.news.map { NewsArticle(title: $0.title, publisher: $0.publisher, url: $0.url,
                                                       published: $0.published, tickers: [t]) }
                }
            }
            return anySuccess ? NewsLogic.clean(all) : nil
        case .market, .index:
            guard let brief = await AIService.fetchBrief() else { return nil }
            return NewsLogic.clean(brief.headlines.compactMap { h in
                h.url.map { NewsArticle(title: h.title, publisher: h.publisher, url: $0, published: nil,
                                        tickers: h.ticker.map { [$0] } ?? []) }
            })
        }
    }
}
