import SwiftUI

// MARK: Общая карточка

@MainActor
private final class AIModel: ObservableObject {
    @Published var insight: AIInsight?
    @Published var loading = true

    func run(kind: AIFacts.Kind, subject: String, language: String,
             facts: @escaping () async -> AIFacts) async {
        loading = true
        let key = AICache.key(kind: kind, subject: subject, language: language)
        // Сначала кэш: показываем сразу, без сети.
        if let cached = AICache.get(key), cached.usedModel || !AIEngine.isUsable(languageCode: language) {
            insight = cached; loading = false; return
        }
        let f = await facts()
        let result = await AIService.insight(for: f, cacheKey: key, languageCode: language)
        if Task.isCancelled { return }
        insight = result
        loading = false
    }
}

private struct AICardContent: View {
    let title: LocalizedStringKey
    let insight: AIInsight?
    let loading: Bool
    var showDetails = true
    @State private var safariLink: SafariLink?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundColor(Theme.gold)
                Text(title).font(Theme.ui(.subheadline, weight: .semibold)).foregroundColor(Theme.gold2)
                Spacer(minLength: 0)
                if let i = insight, i.reasons.count > 0 { sentimentChip(i) }
            }
            if loading && insight == nil {
                HStack(spacing: 8) {
                    ProgressView().tint(Theme.gold)
                    Text("Analyzing…").font(Theme.ui(.footnote)).foregroundColor(Theme.muted)
                }
            } else if let i = insight {
                Text(verbatim: i.headline)
                    .font(Theme.ui(.subheadline, weight: .medium)).foregroundColor(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if showDetails {
                    ForEach(Array(i.reasons.enumerated()), id: \.offset) { _, r in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: "•").foregroundColor(Theme.gold)
                            Text(verbatim: r).font(Theme.ui(.footnote)).foregroundColor(Theme.text.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !i.sources.isEmpty { sourcesList(i.sources) }
                    footer(i)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
        .sheet(item: $safariLink) { SafariView(url: $0.url).ignoresSafeArea() }
    }

    private func sentimentChip(_ i: AIInsight) -> some View {
        let (key, color): (LocalizedStringKey, Color) = {
            switch i.sentiment {
            case .up: return ("Positive", Theme.ok)
            case .down: return ("Negative", Theme.danger)
            case .mixed: return ("Mixed", Theme.muted)
            }
        }()
        return Text(key).font(Theme.ui(.caption2, weight: .medium)).foregroundColor(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(color.opacity(0.6), lineWidth: 1))
    }

    private func sourcesList(_ sources: [AIHeadline]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sources").font(Theme.ui(.caption, weight: .medium)).foregroundColor(Theme.muted)
            ForEach(sources) { h in
                Button {
                    if let u = h.url.flatMap(URL.init(string:)) { safariLink = SafariLink(url: u) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "link").font(.caption2)
                        Text(verbatim: h.title + (h.publisher.map { " · \($0)" } ?? ""))
                            .font(Theme.ui(.caption)).multilineTextAlignment(.leading).lineLimit(2)
                    }
                    .foregroundColor(Theme.gold)
                }
                .buttonStyle(.plain)
                .disabled(h.url == nil)
            }
        }
        .padding(.top, 2)
    }

    private func footer(_ i: AIInsight) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(i.usedModel ? "On-device AI" : "Automatic summary")
                .font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
            Text("AI-generated, may be inaccurate. Not investment advice.")
                .font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
        }
        .padding(.top, 2)
    }
}

// MARK: Почему бумага двигается

struct AIInsightView: View {
    let ticker: String
    @StateObject private var model = AIModel()
    @AppStorage(AppLanguage.storageKey) private var languageChoice = ""

    init(ticker: String) { self.ticker = ticker }

    var body: some View {
        AICardContent(title: "Why is it moving?", insight: model.insight, loading: model.loading)
            .padding(.horizontal)
            .task(id: "\(ticker)|\(languageChoice)") {
                await model.run(kind: .stock, subject: ticker, language: AppLanguage.effectiveCode) {
                    await AIService.stockFacts(ticker: ticker)
                }
            }
    }
}

// MARK: Бриф рынка

struct MarketBriefView: View {
    var compact: Bool = true
    @StateObject private var model = AIModel()
    @AppStorage(AppLanguage.storageKey) private var languageChoice = ""
    @State private var expanded = false
    @State private var showFull = false

    init(compact: Bool = true) { self.compact = compact }

    var body: some View {
        Group {
            if compact { compactBody } else { fullBody }
        }
        .task(id: languageChoice) {
            await model.run(kind: .market, subject: "market", language: AppLanguage.effectiveCode) {
                await AIService.marketFacts()
            }
        }
    }

    private var compactBody: some View {
        VStack(alignment: .trailing, spacing: 6) {
            AICardContent(title: "Daily market brief", insight: model.insight, loading: model.loading,
                          showDetails: expanded)
            HStack(spacing: 16) {
                Button { withAnimation { expanded.toggle() } } label: {
                    Label(expanded ? "Show less" : "Show more", systemImage: expanded ? "chevron.up" : "chevron.down")
                }
                Button { showFull = true } label: { Label("Open", systemImage: "arrow.up.left.and.arrow.down.right") }
            }
            .font(Theme.ui(.caption, weight: .medium))
            .foregroundColor(Theme.gold)
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
        }
        .padding(.horizontal)
        .fullScreenCover(isPresented: $showFull) { MarketBriefFullScreen() }
    }

    private var fullBody: some View {
        ScrollView {
            AICardContent(title: "Daily market brief", insight: model.insight, loading: model.loading)
                .padding(.vertical, 12)
        }
        .themeScreen()
    }
}

private struct MarketBriefFullScreen: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").frame(width: 34, height: 34).outlinedControl()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close"))
                Spacer()
            }
            .padding(.horizontal).padding(.top, 8)
            MarketBriefView(compact: false)
        }
        .themeScreen()
    }
}

// MARK: Обзор портфолио

struct PortfolioInsightView: View {
    let holdings: [PortfolioInsightHolding]
    @StateObject private var model = AIModel()
    @AppStorage(AppLanguage.storageKey) private var languageChoice = ""

    init(holdings: [PortfolioInsightHolding]) { self.holdings = holdings }

    var body: some View {
        AICardContent(title: "Portfolio review", insight: model.insight, loading: model.loading)
            .padding(.horizontal)
            .task(id: "\(AIService.portfolioKey(holdings))|\(languageChoice)") {
                guard !holdings.isEmpty else { model.insight = nil; model.loading = false; return }
                await model.run(kind: .portfolio, subject: AIService.portfolioKey(holdings),
                                language: AppLanguage.effectiveCode) {
                    await AIService.portfolioFacts(holdings)
                }
            }
    }
}
