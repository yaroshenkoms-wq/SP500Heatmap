import SwiftUI

@MainActor
final class NewsStore: ObservableObject {
    enum State { case loading, loaded, failed }
    @Published private(set) var items: [NewsArticle] = []
    @Published private(set) var state: State = .loading
    @Published private(set) var digest: NewsDigest?
    @Published private(set) var digestLoading = false

    private var cache: [String: (Date, [NewsArticle])] = [:]
    private var digests: [String: NewsDigest] = [:]
    private static let ttl: TimeInterval = 300

    func load(scope: NewsScope, force: Bool = false) async {
        let code = AppLanguage.effectiveCode
        let key = "\(scope.cacheKey)|\(code)"
        if !force, let hit = cache[key], Date().timeIntervalSince(hit.0) < Self.ttl {
            items = hit.1; state = .loaded
            return
        }
        if items.isEmpty { state = .loading }
        let fetched = await NewsService.fetch(scope: scope, lang: code)
        if Task.isCancelled { return }
        if let fetched {
            cache[key] = (Date(), fetched)
            items = fetched
            state = .loaded
        } else if items.isEmpty {
            state = .failed
        }
    }

    func clear() { items = []; digest = nil; state = .loading }

    /// Дайджест по тем заголовкам, что сейчас на экране (с учётом фильтра языка).
    func refreshDigest(for shown: [NewsArticle]) async {
        let code = AppLanguage.effectiveCode
        guard !shown.isEmpty else { digest = nil; digestLoading = false; return }
        let key = NewsDigestBuilder.key(shown, code: code)
        if let d = digests[key], d.usedModel || !AIEngine.isUsable(languageCode: code) { digest = d; digestLoading = false; return }
        digestLoading = true
        let d = await NewsDigestBuilder.make(shown, code: code)
        if Task.isCancelled { return }
        digests[key] = d
        digest = d
        digestLoading = false
    }
}

private enum NewsSegment: Hashable { case market, index, lists }

/// Экран новостей. Без параметров — три сегмента (рынок / индекс / мои списки);
/// с `tickers` — только новости этих бумаг (ссылка «Все новости» на странице компании).
struct NewsView: View {
    var fixedTickers: [String]?
    @StateObject private var store = NewsStore()
    @ObservedObject private var favorites = FavoritesStore.shared
    @EnvironmentObject private var indexStore: IndexStore
    @AppStorage(AppLanguage.storageKey) private var languageChoice = ""
    @AppStorage("newsLanguageFilter") private var filterRaw = NewsLanguageFilter.all.rawValue
    @State private var segment: NewsSegment = .market
    @State private var listId: String = ""     // "" = все списки
    @State private var safariLink: SafariLink?
    @State private var company: CompanyRef?
    @State private var showAssistant = false

    init(tickers: [String]? = nil) { fixedTickers = tickers }

    private var code: String { AppLanguage.effectiveCode }
    private var filter: NewsLanguageFilter { NewsLanguageFilter(rawValue: filterRaw) ?? .all }

    private var listTickers: [String] {
        let items = listId.isEmpty ? favorites.allItems : favorites.items(in: listId)
        var seen = Set<String>(), out: [String] = []
        for i in items where seen.insert(i.ticker).inserted { out.append(i.ticker) }
        return Array(out.prefix(20))
    }

    private var scope: NewsScope {
        if let fixedTickers { return .tickers(fixedTickers) }
        switch segment {
        case .market: return .market
        case .index: return .index(indexStore.selectedId)
        case .lists: return .tickers(listTickers)
        }
    }

    private var shown: [NewsArticle] { NewsLogic.filter(store.items, filter, code: code) }
    private var taskKey: String { "\(scope.cacheKey)|\(languageChoice)" }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if fixedTickers == nil { segments }
                controls
                if segment == .lists && fixedTickers == nil && listTickers.isEmpty {
                    note("Add stocks to a watchlist to see their news here.")
                } else {
                    switch store.state {
                    case .loading where store.items.isEmpty:
                        ProgressView().tint(Theme.gold).frame(maxWidth: .infinity).padding(.vertical, 40)
                    case .failed:
                        failedBox
                    default:
                        if !shown.isEmpty { NewsDigestCard(digest: store.digest, loading: store.digestLoading) }
                        if shown.isEmpty { note(filter == .mine ? "No news in your language right now." : "No news available.") }
                        else { list }
                    }
                }
                Text("Headlines come from public sources. AI-generated summaries may be inaccurate. Not investment advice.")
                    .font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await store.load(scope: scope, force: true); await store.refreshDigest(for: shown) }
        .themeScreen()
        .navigationTitle(Text("News"))
        .navigationBarTitleDisplayMode(.inline)
        .themeNavBar()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAssistant = true } label: { Image(systemName: "sparkles") }
                    .accessibilityLabel(Text("Ask AI"))
            }
        }
        .sheet(isPresented: $showAssistant) { AIAssistantView(initialTab: .chat) }
        .sheet(item: $safariLink) { SafariView(url: $0.url).ignoresSafeArea() }
        .companyDestination($company)
        .task(id: taskKey) { await store.load(scope: scope) }
        .task(id: "\(store.items.first?.id ?? "")|\(store.items.count)|\(filterRaw)|\(languageChoice)") { await store.refreshDigest(for: shown) }
    }

    // MARK: части экрана

    private var segments: some View {
        HStack(spacing: 6) {
            segButton("Market", .market)
            segButton(verbatim: indexStore.current.name, .index)
            segButton("My lists", .lists)
        }
    }

    private func segButton(_ title: LocalizedStringKey, _ s: NewsSegment) -> some View {
        Button { segment = s; store.clear() } label: {
            Text(title).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity).themeChip(selected: segment == s)
        }.buttonStyle(.plain)
    }

    private func segButton(verbatim title: String, _ s: NewsSegment) -> some View {
        Button { segment = s; store.clear() } label: {
            Text(verbatim: title).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity).themeChip(selected: segment == s)
        }.buttonStyle(.plain)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Menu {
                Picker(selection: $filterRaw) {
                    Text("All languages").tag(NewsLanguageFilter.all.rawValue)
                    Text(verbatim: AppLanguage.nativeName(code)).tag(NewsLanguageFilter.mine.rawValue)
                } label: { Text("Language") }
            } label: {
                Label(filter == .all ? AppLanguage.string("All languages") : AppLanguage.nativeName(code), systemImage: "globe")
                    .font(Theme.ui(.caption, weight: .medium))
                    .padding(.horizontal, 10).frame(minHeight: 30).outlinedControl()
            }
            if segment == .lists && fixedTickers == nil && favorites.lists.count > 1 {
                Menu {
                    Picker(selection: $listId) {
                        Text("All lists").tag("")
                        ForEach(favorites.lists) { Text(verbatim: $0.name).tag($0.id) }
                    } label: { Text("My lists") }
                } label: {
                    Label(listId.isEmpty ? AppLanguage.string("All lists") : (favorites.list(listId)?.name ?? ""), systemImage: "star")
                        .font(Theme.ui(.caption, weight: .medium))
                        .padding(.horizontal, 10).frame(minHeight: 30).outlinedControl()
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, a in
                if i > 0 { Divider().overlay(Theme.line) }
                row(a)
            }
        }
        .padding(.horizontal, 12)
        .panelCard()
    }

    private func row(_ a: NewsArticle) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                if let u = a.link { safariLink = SafariLink(url: u) }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: a.title)
                        .font(Theme.ui(.subheadline, weight: .medium)).foregroundColor(Theme.text)
                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: NewsFormat.meta(a))
                        .font(Theme.ui(.caption)).foregroundColor(Theme.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !a.tickers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(a.tickers.prefix(6), id: \.self) { t in
                            Button { openCompany(t) } label: {
                                Text(verbatim: t).themeChip(selected: false).foregroundColor(Theme.gold)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 9)
    }

    private func openCompany(_ t: String) {
        let entry = PfMarketData.shared.entry(t)
        let ref = CompanyRef(ticker: t, name: entry?.n ?? t, index: entry?.i)
        prepareCompany(ref, store: indexStore)
        company = ref
    }

    private func note(_ key: LocalizedStringKey) -> some View {
        Text(key).font(Theme.ui(.subheadline)).foregroundColor(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12).panelCard()
    }

    private var failedBox: some View {
        VStack(spacing: 8) {
            Text("Couldn't load data.").font(Theme.ui(.subheadline)).foregroundColor(Theme.muted)
            Button("Retry") { Task { await store.load(scope: scope, force: true) } }.buttonStyle(OutlinedButtonStyle())
        }
        .frame(maxWidth: .infinity).padding(16).panelCard()
    }
}

/// Карточка «ИИ-дайджест».
struct NewsDigestCard: View {
    let digest: NewsDigest?
    let loading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundColor(Theme.gold)
                Text("AI digest").font(Theme.ui(.subheadline, weight: .semibold)).foregroundColor(Theme.gold2)
                Spacer(minLength: 0)
            }
            if let d = digest {
                Text(verbatim: d.summary).font(Theme.ui(.subheadline, weight: .medium)).foregroundColor(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(d.points.enumerated()), id: \.offset) { _, p in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "•").foregroundColor(Theme.gold)
                        Text(verbatim: p).font(Theme.ui(.footnote)).foregroundColor(Theme.text.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(d.usedModel ? "On-device AI" : "Automatic summary")
                    .font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
            } else if loading {
                HStack(spacing: 8) {
                    ProgressView().tint(Theme.gold)
                    Text("Analyzing…").font(Theme.ui(.footnote)).foregroundColor(Theme.muted)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
    }
}
