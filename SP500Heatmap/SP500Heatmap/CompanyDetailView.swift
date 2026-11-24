import SwiftUI
import Charts
import SafariServices

struct CompanyDetailView: View {
    let company: Company
    @ObservedObject var webSocketManager: WebSocketManager
    @State private var selectedPeriod = "SC"
    @State private var history: [DailyClose] = []
    // Недельные ряды для 3y/5y/10y; nil в failedLong — сервер не отдал, показываем 1y.
    @State private var longHistory: [String: [DailyClose]] = [:]
    @State private var failedLong: Set<String> = []
    @EnvironmentObject private var indexStore: IndexStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var infoState: InfoState = .loading
    @State private var safariLink: SafariLink?

    private enum InfoState { case loading, failed, loaded(CompanyInfo) }

    // Текущая цена (последняя известная)
    var currentPrice: Double {
        if indexStore.isLive {
            return webSocketManager.priceUpdates[company.ticker]?.price ?? 0
        }
        // No live feed: the last close from history is the current price.
        return history.last?.close ?? 0
    }

    // Изменение за текущую сессию (SC)
    var currentChangePercent: Double {
        webSocketManager.priceUpdates[company.ticker]?.changePercent ?? 0
    }

    // Сколько торговых дней назад брать данные для каждого периода
    private static let periodTradingDaysBack: [String: Int] = [
        "SC": 1, "1d": 1, "3d": 3, "7d": 5, "30d": 21, "180d": 126, "1y": 252, "3y": 252, "5y": 252, "10y": 252
    ]

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    // Реальные цены закрытия за выбранный период (из истории с бэкенда)
    private static let longPeriods: Set<String> = ["3y", "5y", "10y"]

    private var longFallbackActive: Bool {
        Self.longPeriods.contains(selectedPeriod) && (longHistory[selectedPeriod] ?? []).isEmpty
            && failedLong.contains(selectedPeriod)
    }

    var pricesForPeriod: [StockPrice] {
        if let long = longHistory[selectedPeriod], !long.isEmpty {
            return long.compactMap { point in
                guard let date = Self.dateFormatter.date(from: point.date) else { return nil }
                return StockPrice(date: date, price: point.close)
            }
        }
        guard !history.isEmpty else { return [] }
        let daysBack = Self.periodTradingDaysBack[indexStore.effectivePeriod(selectedPeriod)] ?? history.count
        let startIndex = max(0, history.count - 1 - daysBack)
        return history[startIndex...].compactMap { point in
            guard let date = Self.dateFormatter.date(from: point.date) else { return nil }
            return StockPrice(date: date, price: point.close)
        }
    }

    // Изменение за выбранный период (в процентах), посчитанное по реальным ценам закрытия
    var periodChangePercent: Double {
        let prices = pricesForPeriod
        guard let firstPrice = prices.first?.price, let lastPrice = prices.last?.price, firstPrice > 0 else { return 0 }
        return ((lastPrice - firstPrice) / firstPrice) * 100
    }

    private func loadLongHistory(_ period: String) async {
        guard Self.longPeriods.contains(period), longHistory[period] == nil else { return }
        do {
            let fetched = try await NetworkService.shared.fetchHistory(ticker: company.ticker, range: period)
            if fetched.count >= 2 {
                longHistory[period] = fetched
            } else {
                failedLong.insert(period)
            }
        } catch {
            failedLong.insert(period)
        }
    }

    private func loadHistory() async {
        do {
            let fetched = try await NetworkService.shared.fetchHistory(ticker: company.ticker)
            await MainActor.run {
                self.history = fetched
            }
        } catch {
            print("Failed to load history for \(company.ticker): \(error)")
        }
    }
    
    private var isRegular: Bool { sizeClass == .regular }
    private var isCrypto: Bool { indexStore.selectedId == "crypto50" || company.ticker.hasSuffix("-USD") }

    private func loadInfo() async {
        infoState = .loading
        do {
            let info = try await NetworkService.shared.fetchCompanyInfo(ticker: company.ticker)
            infoState = .loaded(info)
        } catch is CancellationError {
            return
        } catch {
            infoState = .failed
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 8) {
                    if isRegular {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(spacing: 8) { chartSection; alertsSection; descriptionSection; metricsSection }
                                .frame(maxWidth: .infinity)
                            VStack(spacing: 8) { keyDataSection; newsSection }
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        chartSection
                        alertsSection
                        descriptionSection
                        metricsSection
                        keyDataSection
                        newsSection
                    }
                    Text(isCrypto ? "Data: CoinGecko" : "Data: Yahoo Finance")
                        .font(Theme.ui(.caption2))
                        .foregroundColor(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.top, 4)
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: isRegular ? 1100 : .infinity)
                .frame(maxWidth: .infinity)
            }
        }
        .themeScreen()
        .navigationBarHidden(true)
        .edgesIgnoringSafeArea(.bottom)
        .task {
            await loadHistory()
        }
        .task(id: selectedPeriod) {
            await loadLongHistory(selectedPeriod)
        }
        .task(id: company.ticker) {
            await loadInfo()
        }
        .sheet(item: $safariLink) { link in
            SafariView(url: link.url).ignoresSafeArea()
        }
    }

    // Верхняя панель с кнопкой Back, названием компании и изменением
    private var header: some View {
        VStack(spacing: 4) {
            HStack {
                Button(action: {
                    dismiss()
                }) {
                    HStack {
                        Image(systemName: "chevron.backward")
                        Text("Back")
                    }
                    .font(Theme.ui(.subheadline, weight: .medium))
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .outlinedControl()
                }
                .buttonStyle(.plain)
                Spacer()
                VStack(alignment: .trailing) {
                    Text(company.ticker)
                        .font(Theme.serif(.title2))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(company.name)
                        .font(Theme.ui(.caption))
                        .foregroundColor(Theme.muted)
                }
                FavoriteStarButton(ticker: company.ticker, name: company.name)
                Spacer()
                VStack(alignment: .trailing) {
                    Text(indexStore.formatPrice(currentPrice))
                        .font(Theme.ui(.title2, weight: .semibold))
                        .foregroundColor(Theme.text)
                    Text(formatPercent(periodChangePercent))
                        .font(Theme.ui(.headline, weight: .medium))
                        .foregroundColor(Theme.changeColor(periodChangePercent))
                }
            }
            .padding(.horizontal)

            PeriodSwitchView(selectedPeriod: $selectedPeriod)
        }
        .padding(.top, 8)
        .background(Theme.bg)
    }

    private var chartSection: some View {
        ProChartView(ticker: company.ticker, indexId: indexStore.selectedId)
    }

    private var loadedInfo: CompanyInfo? {
        if case .loaded(let info) = infoState { return info }
        return nil
    }

    private var alertsSection: some View {
        CompanyAlertsSection(company: company, indexId: indexStore.selectedId,
                             currentPrice: history.last?.close ?? currentPrice, info: loadedInfo)
    }

    // Описаний компаний сервер пока не отдаёт: без текста раздел не показываем.
    @ViewBuilder private var descriptionSection: some View {
        if let text = company.description, !text.isEmpty {
        VStack(alignment: .leading) {
            Text("Description")
                .font(Theme.serif(.title3))
                .foregroundColor(Theme.text)
            Text(verbatim: text)
                .font(Theme.ui(.subheadline))
                .foregroundColor(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        }
    }

    private var metricsSection: some View {
        VStack(alignment: .leading) {
            Text("Metrics")
                .font(Theme.serif(.title3))
                .foregroundColor(Theme.text)
            // P/E и прочее — в «Ключевых данных» (/company); здесь только капитализация, без пустых «Н/Д».
            HStack {
                MetricItem(title: "Market Cap", value: formatMarketCap(company.marketCap))
                if let pe = company.peRatio {
                    Spacer()
                    MetricItem(title: "P/E", value: formatDecimal(pe))
                }
                if let volume = company.volume {
                    Spacer()
                    MetricItem(title: "Volume", value: formatVolume(volume))
                }
                Spacer()
            }
            .padding(12)
            .panelCard()
        }
        .padding(.horizontal)
    }

    // MARK: Ключевые данные

    private var keyDataSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Key data")
                .font(Theme.serif(.title3))
                .foregroundColor(Theme.text)
            switch infoState {
            case .loading:
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16)
            case .failed:
                retryBox
            case .loaded(let info):
                let rows = keyRows(info)
                if rows.isEmpty && info.high52w == nil {
                    emptyNote("No additional data available.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                            if i > 0 { Divider().overlay(Theme.line) }
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.title)
                                    .font(Theme.ui(.subheadline))
                                    .foregroundColor(Theme.muted)
                                Spacer(minLength: 12)
                                Text(verbatim: row.value)
                                    .font(Theme.ui(.subheadline, weight: .medium))
                                    .foregroundColor(Theme.text)
                                    .multilineTextAlignment(.trailing)
                            }
                            .padding(.vertical, 8)
                        }
                        if let low = info.low52w, let high = info.high52w, high > low {
                            if !rows.isEmpty { Divider().overlay(Theme.line) }
                            rangeBar(low: low, high: high)
                                .padding(.vertical, 8)
                        }
                    }
                    .padding(.horizontal, 12)
                    .panelCard()
                }
            }
        }
        .padding(.horizontal)
    }

    private struct KeyRow { let title: LocalizedStringKey; let value: String }

    private func keyRows(_ info: CompanyInfo) -> [KeyRow] {
        var rows: [KeyRow] = []
        let code = info.currency ?? indexStore.current.currency ?? "USD"
        if let v = info.pe { rows.append(KeyRow(title: "P/E", value: formatDecimal(v))) }
        if let v = info.forwardPe { rows.append(KeyRow(title: "Forward P/E", value: formatDecimal(v))) }
        if let v = info.divYield { rows.append(KeyRow(title: "Dividend yield", value: formatPercent(v))) }
        if let v = info.dividendRate {
            rows.append(KeyRow(title: "Dividend per share",
                               value: v.formatted(.currency(code: code).locale(AppLanguage.locale))))
        }
        if let d = parseDay(info.exDividendDate) {
            rows.append(KeyRow(title: "Ex-dividend date", value: dayText(d, withCountdown: false)))
        }
        if let d = parseDay(info.earningsDate) {
            rows.append(KeyRow(title: "Next earnings", value: dayText(d, withCountdown: true)))
        }
        if let v = info.beta { rows.append(KeyRow(title: "Beta", value: formatDecimal(v))) }
        return rows
    }

    private func parseDay(_ iso: String?) -> Date? {
        guard let iso, iso.count >= 10 else { return nil }
        return Self.dateFormatter.date(from: String(iso.prefix(10)))
    }

    private func dayText(_ date: Date, withCountdown: Bool) -> String {
        let text = date.formatted(.dateTime.day().month(.abbreviated).year().locale(AppLanguage.locale))
        guard withCountdown else { return text }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let today = cal.startOfDay(for: Date())
        let days = cal.dateComponents([.day], from: today, to: date).day ?? -1
        guard days >= 0 else { return text }
        let f = RelativeDateTimeFormatter()
        f.locale = AppLanguage.locale
        f.unitsStyle = .full
        f.dateTimeStyle = .numeric
        let rel = f.localizedString(from: DateComponents(day: days))
        return text + " · " + rel
    }

    // Диапазон за 52 недели: полоса с отметкой текущей цены.
    private func rangeBar(low: Double, high: Double) -> some View {
        let price = history.last?.close ?? currentPrice
        let pos = max(0, min(1, (price - low) / (high - low)))
        return VStack(alignment: .leading, spacing: 6) {
            Text("52-week range")
                .font(Theme.ui(.subheadline))
                .foregroundColor(Theme.muted)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.chip).frame(height: 6)
                    Capsule().fill(Theme.goldLine).frame(width: geo.size.width * pos, height: 6)
                    Circle().fill(Theme.gold2)
                        .frame(width: 14, height: 14)
                        .offset(x: max(0, geo.size.width * pos - 7))
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 16)
            .environment(\.layoutDirection, .leftToRight)
            HStack {
                Text(verbatim: indexStore.formatPrice(low))
                Spacer()
                Text(verbatim: indexStore.formatPrice(high))
            }
            .font(Theme.ui(.caption))
            .foregroundColor(Theme.text)
            .environment(\.layoutDirection, .leftToRight)
        }
    }

    // MARK: Новости

    private var newsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("News")
                .font(Theme.serif(.title3))
                .foregroundColor(Theme.text)
            switch infoState {
            case .loading:
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16)
            case .failed:
                retryBox
            case .loaded(let info):
                let items = Array(info.news.filter { URL(string: $0.url) != nil }.prefix(8))
                if items.isEmpty {
                    emptyNote("No news available.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                            if i > 0 { Divider().overlay(Theme.line) }
                            Button { open(item) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: item.title)
                                        .font(Theme.ui(.subheadline, weight: .medium))
                                        .foregroundColor(Theme.text)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(verbatim: newsMeta(item))
                                        .font(Theme.ui(.caption))
                                        .foregroundColor(Theme.muted)
                                }
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .panelCard()
                }
            }
        }
        .padding(.horizontal)
    }

    private func open(_ item: NewsItem) {
        guard let url = URL(string: item.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        safariLink = SafariLink(url: url)
    }

    private func newsMeta(_ item: NewsItem) -> String {
        var parts: [String] = []
        if let p = item.publisher, !p.isEmpty { parts.append(p) }
        if let raw = item.published, let date = ISO8601DateFormatter().date(from: raw) {
            let f = RelativeDateTimeFormatter()
            f.locale = AppLanguage.locale
            f.unitsStyle = .short
            parts.append(f.localizedString(for: date, relativeTo: Date()))
        }
        return parts.joined(separator: " · ")
    }

    private func emptyNote(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(Theme.ui(.subheadline))
            .foregroundColor(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .panelCard()
    }

    private var retryBox: some View {
        VStack(spacing: 8) {
            Text("Couldn't load data.")
                .font(Theme.ui(.subheadline))
                .foregroundColor(Theme.muted)
            Button("Retry") { Task { await loadInfo() } }
                .buttonStyle(OutlinedButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .panelCard()
    }

    private func formatMarketCap(_ value: Double) -> String {
        return formatCompact(value)
    }
    
    private func formatVolume(_ value: Double) -> String {
        return formatCompact(value)
    }
}

struct StockPrice: Identifiable {
    let id = UUID()
    let date: Date
    let price: Double
}

struct MetricItem: View {
    let title: LocalizedStringKey
    let value: String
    
    var body: some View {
        VStack {
            Text(title)
                .font(Theme.ui(.caption))
                .foregroundColor(Theme.muted)
            Text(value)
                .font(Theme.ui(.body, weight: .semibold))
                .foregroundColor(Theme.text)
        }
    }
}

// MARK: Данные /company

struct NewsItem: Decodable {
    let title: String
    let publisher: String?
    let url: String
    let published: String?
}

struct CompanyInfo: Decodable {
    let pe: Double?
    let forwardPe: Double?
    let divYield: Double?
    let dividendRate: Double?
    let exDividendDate: String?
    let earningsDate: String?
    let high52w: Double?
    let low52w: Double?
    let beta: Double?
    let currency: String?
    let news: [NewsItem]

    enum CodingKeys: String, CodingKey {
        case pe, forwardPe, divYield, dividendRate, exDividendDate, earningsDate, high52w, low52w, beta, currency, news
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pe = try c.decodeIfPresent(Double.self, forKey: .pe)
        forwardPe = try c.decodeIfPresent(Double.self, forKey: .forwardPe)
        divYield = try c.decodeIfPresent(Double.self, forKey: .divYield)
        dividendRate = try c.decodeIfPresent(Double.self, forKey: .dividendRate)
        exDividendDate = try c.decodeIfPresent(String.self, forKey: .exDividendDate)
        earningsDate = try c.decodeIfPresent(String.self, forKey: .earningsDate)
        high52w = try c.decodeIfPresent(Double.self, forKey: .high52w)
        low52w = try c.decodeIfPresent(Double.self, forKey: .low52w)
        beta = try c.decodeIfPresent(Double.self, forKey: .beta)
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        news = (try? c.decodeIfPresent([NewsItem].self, forKey: .news)) ?? []
    }
}

struct SafariLink: Identifiable {
    let id = UUID()
    let url: URL
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.preferredBarTintColor = UIColor(Theme.bg)
        vc.preferredControlTintColor = UIColor(Theme.gold)
        return vc
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
