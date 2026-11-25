import SwiftUI

struct ContentView: View {
    @StateObject private var webSocketManager = WebSocketManager.shared
    @StateObject private var indexStore = IndexStore.shared
    @StateObject private var worldStore = WorldStore.shared
    @State private var path: [String] = []
    @State private var stackToken = UUID()
    @State private var showSettings = false
    @State private var companyLink: CompanyLink?
    #if DEBUG
    @State private var debugScreen: String?
    #endif
    @ObservedObject private var settings = AppSettings.shared
    @State private var tab: AppTab = .markets
    @Environment(\.scenePhase) private var scenePhase

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var splitSelection: String?

    private var hasWorld: Bool { !worldStore.regions.isEmpty }
    private var useSplit: Bool { sizeClass == .regular && hasWorld }

    private func selectIndex(_ id: String?) {
        if let id { indexStore.selectedId = id }
        splitSelection = id
    }

    private var rootContent: some View {
        TabView(selection: $tab) {
            Tab("Markets", systemImage: "globe", value: AppTab.markets) { marketsContent }
            Tab("Watchlists", systemImage: "star", value: AppTab.watchlists) {
                NavigationStack { FavoritesView(isRoot: true) }
            }
            Tab("Portfolio", systemImage: "briefcase", value: AppTab.portfolio) {
                NavigationStack { MyPortfolioView() }
            }
            Tab("Screener", systemImage: "slider.horizontal.3", value: AppTab.screener) {
                NavigationStack { ScreenerView() }
            }
            Tab("More", systemImage: "ellipsis", value: AppTab.more) {
                NavigationStack { MoreView(onSettings: { showSettings = true }) }
            }
        }
        .tint(Theme.gold)
        .toolbarBackground(Theme.bg, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarColorScheme(.dark, for: .tabBar)
    }

    @ViewBuilder private var marketsContent: some View {
        if useSplit {
            NavigationSplitView(columnVisibility: .constant(.all)) {
                IndexSidebar(store: worldStore, selection: $splitSelection,
                             onSelect: { selectIndex($0) }, onHome: { selectIndex(nil) })
            } detail: {
                NavigationStack {
                    if splitSelection == nil {
                        WorldOverviewView(store: worldStore, onSelect: { selectIndex($0.id) })
                    } else {
                        IndexFlowView(webSocketManager: webSocketManager)
                    }
                }
                .id(splitSelection ?? "home")
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            compactStack
        }
    }

    private var compactStack: some View {
        NavigationStack(path: $path) {
            Group {
                if !worldStore.didFinishFirstLoad {
                    ProgressView("Loading data...")
                        .font(Theme.ui(.footnote))
                        .foregroundColor(Theme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .themeScreen()
                } else if hasWorld {
                    WorldOverviewView(store: worldStore, onSelect: { index in
                        indexStore.selectedId = index.id
                        path.append(index.id)
                    })
                } else {
                    // Old server without world-overview: open the S&P 500 map directly.
                    IndexFlowView(webSocketManager: webSocketManager)
                }
            }
            .navigationDestination(for: String.self) { _ in
                IndexFlowView(webSocketManager: webSocketManager)
            }
        }
    }

    var body: some View {
        rootContent
        // Смена палитры пересобирает карты (размер плиток карты читают сами) (окно настроек стоит снаружи).
        .id("\(stackToken.uuidString)-\(settings.palette.rawValue)")
        .sheet(isPresented: $showSettings) {
            SettingsView(indices: worldStore.regions.flatMap { $0.indices })
                .presentationSizing(.form)
        }
        #if DEBUG
        .fullScreenCover(item: Binding(get: { debugScreen.map(DebugScreen.init) }, set: { debugScreen = $0?.id })) { screen in
            NavigationStack {
                if screen.id == "portfolios" { PortfoliosView() }
                else if screen.id == "calendar" { CalendarView() }
                else if screen.id == "screener" { ScreenerView() }
                else if screen.id == "favorites" { FavoritesView() }
                else if screen.id == "news" { NewsView() }
                else if screen.id == "languages" { LanguagePickerView() }
                else if screen.id == "chat" { AIChatView(autoAsk: AIQuestion.suggested.first) }
                else if screen.id.hasPrefix("portfolio:"), let info = PortfolioStore.shared.info(String(screen.id.dropFirst(10))) {
                    PortfolioDetailView(info: info)
                }
                else if screen.id.hasPrefix("company:") {
                    CompanyDetailView(company: Company(ticker: String(screen.id.dropFirst(8)), name: String(screen.id.dropFirst(8)), marketCap: 0, description: nil, peRatio: nil, volume: nil), webSocketManager: webSocketManager)
                }
            }
            .environmentObject(indexStore)
        }
        #endif
        .background(Theme.bg.ignoresSafeArea())
        .environment(\.goHome, hasWorld ? { tab = .markets; goHome() } : nil)
        .environmentObject(indexStore)
        .task {
            await indexStore.loadIfNeeded()
            await worldStore.load()
            #if DEBUG
            // Для проверки на симуляторе: `-openIndex ibex35` сразу открывает карту индекса.
            if let id = UserDefaults.standard.string(forKey: "openIndex"), hasWorld {
                indexStore.selectedId = id
                splitSelection = id
                path.append(id)
            }
            // Для снимков App Store: `-demoPortfolio` / `-demoWatchlist` заполняют портфель и список демо-данными.
            if UserDefaults.standard.bool(forKey: "demoPortfolio") { DebugDemoData.seedPortfolio() }
            if UserDefaults.standard.bool(forKey: "demoWatchlist") { DebugDemoData.seedWatchlist() }
            // `-openTab markets|watchlists|portfolio|screener|more` — сразу открыть вкладку.
            if let raw = UserDefaults.standard.string(forKey: "openTab"), let t = AppTab(rawValue: raw) { tab = t }
            // `-openScreen settings|calendar|screener|portfolios|favorites|portfolio:m_dalio` — сразу открыть экран.
            if let screen = UserDefaults.standard.string(forKey: "openScreen") {
                if screen == "settings" { showSettings = true } else { debugScreen = screen }
            }
            #endif
        }
        .task {
            webSocketManager.connect()
        }
        .onOpenURL { url in handleURL(url) }
        // Нажатие на push-уведомление: ссылка приходит от AppDelegate.
        .onReceive(DeepLinkRouter.shared.$url.compactMap { $0 }) { _ in processPendingLink() }
        .onChange(of: worldStore.didFinishFirstLoad) { _, _ in processPendingLink() }
        .sheet(item: $companyLink) { link in
            NavigationStack {
                CompanyDetailView(company: Company(ticker: link.id, name: link.id, marketCap: 0, description: nil, peRatio: nil, volume: nil),
                                  webSocketManager: webSocketManager)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { companyLink = nil } } }
            }
            .environmentObject(indexStore)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && worldStore.didFinishFirstLoad {
                Task { await worldStore.load() }
            }
        }
        .onDisappear {
            webSocketManager.disconnect()
        }
    }

    /// sp500heatmap://index/<id> открывает карту индекса, company/<тикер> — карточку компании, home — главный экран.
    private func handleURL(_ url: URL) {
        guard url.scheme == "sp500heatmap" else { return }
        if let host = url.host, let t = AppTab(rawValue: host) {
            tab = t
        } else if url.host == "index", let id = url.pathComponents.dropFirst().first, hasWorld {
            tab = .markets
            indexStore.selectedId = id
            if useSplit { splitSelection = id } else { path = [id] }
        } else if url.host == "company", let ticker = url.pathComponents.dropFirst().first {
            companyLink = CompanyLink(id: ticker)
        } else if url.host == "home" {
            tab = .markets
            goHome()
        }
    }

    /// Ссылка из уведомления на индекс ждёт, пока загрузятся индексы (холодный старт).
    private func processPendingLink() {
        guard let url = DeepLinkRouter.shared.url else { return }
        if url.host == "index" && !hasWorld {
            if worldStore.didFinishFirstLoad { DeepLinkRouter.shared.url = nil }
            return
        }
        DeepLinkRouter.shared.url = nil
        handleURL(url)
    }

    // Rebuilding the stack drops every pushed level at once (pop to root).
    private func goHome() {
        if useSplit {
            selectIndex(nil)
            Task { await worldStore.load() }
            return
        }
        path = []
        stackToken = UUID()
        Task { await worldStore.load() }
    }
}

// The S&P-style flow of one index: loads its hierarchy and shows the sector map.
struct IndexFlowView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    @StateObject private var networkService = NetworkService.shared
    @StateObject private var performanceStore = PerformanceStore.shared
    @EnvironmentObject private var indexStore: IndexStore
    @State private var sectors: [Sector] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 0) {
                    HStack { HomeButton(); Spacer() }
                        .padding(.horizontal)
                        .padding(.top, 8)
                    ProgressView("Loading data...")
                        .font(Theme.ui(.footnote))
                        .foregroundColor(Theme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .themeScreen()
                .navigationBarHidden(true)
            } else if let error = errorMessage {
                VStack {
                    HStack { HomeButton(); Spacer() }
                        .padding(.horizontal)
                    Spacer()
                    Text("Error")
                        .font(Theme.serif(.title2))
                        .foregroundColor(Theme.text)
                    Text(error)
                        .font(Theme.ui(.caption))
                        .foregroundColor(Theme.muted)
                    Button("Retry") {
                        Task { await loadData() }
                    }
                    .buttonStyle(OutlinedButtonStyle())
                    Spacer()
                }
                .themeScreen()
                .navigationBarHidden(true)
            } else {
                SectorsHeatmapView(sectors: sectors, webSocketManager: webSocketManager, performanceStore: performanceStore)
            }
        }
        .task(id: indexStore.selectedId) {
            await indexStore.loadIfNeeded()
            await loadData()
        }
    }

    private func loadData() async {
        isLoading = true
        errorMessage = nil
        sectors = []
        let indexId = indexStore.apiIndexId

        // Performance loads in parallel with the hierarchy.
        Task { await performanceStore.reload(index: indexId) }

        do {
            let fetchedSectors = try await networkService.fetchMarketHierarchy(index: indexId)
            guard !Task.isCancelled, indexId == indexStore.apiIndexId else { return }
            self.sectors = fetchedSectors
            self.isLoading = false
        } catch {
            guard !Task.isCancelled, indexId == indexStore.apiIndexId else { return }
            self.errorMessage = error.localizedDescription
            self.isLoading = false
        }
    }
}

#Preview {
    ContentView()
}

#if DEBUG
private struct DebugScreen: Identifiable { let id: String }
#endif

struct CompanyLink: Identifiable { let id: String }

enum AppTab: String {
    case markets, watchlists, portfolio, screener, more
}

#if DEBUG
/// Демо-данные для снимков App Store (только Debug).
@MainActor
enum DebugDemoData {
    static func seedPortfolio() {
        let store = MyPortfolioStore.shared
        for p in store.all { store.delete(p.id) }
        let cal = Calendar(identifier: .gregorian)
        func d(_ monthsAgo: Int) -> Date { cal.date(byAdding: .month, value: -monthsAgo, to: Date()) ?? Date() }
        // (тикер, индекс, валюта, количество, цена покупки, месяцев назад)
        let rows: [(String, String, String, Double, Double, Int)] = [
            ("AAPL", "sp500", "USD", 40, 172, 22), ("MSFT", "sp500", "USD", 18, 340, 20),
            ("NVDA", "sp500", "USD", 60, 48, 24), ("AMZN", "sp500", "USD", 30, 128, 18),
            ("SAN.MC", "ibex35", "EUR", 1200, 3.9, 16), ("ITX.MC", "ibex35", "EUR", 150, 35.5, 14),
            ("IBE.MC", "ibex35", "EUR", 400, 11.8, 12), ("BBVA.MC", "ibex35", "EUR", 500, 8.7, 10),
        ]
        var p = store.create(name: AppLanguage.string("My portfolio"), base: .EUR)
        p.transactions = rows.map { MyPortfolio.Transaction(ticker: $0.0, indexId: $0.1, type: .buy, date: d($0.5), quantity: $0.3, price: $0.4, currency: $0.2) }
        store.update(p)
        store.selectedId = p.id
    }

    static func seedWatchlist() {
        let f = FavoritesStore.shared
        let items: [(String, String, String)] = [("TSLA", "Tesla", "sp500"), ("META", "Meta Platforms", "sp500"), ("GOOGL", "Alphabet", "sp500"), ("TEF.MC", "Telefónica", "ibex35"), ("REP.MC", "Repsol", "ibex35")]
        for it in items where !f.contains(it.0) { f.toggle(ticker: it.0, name: it.1, indexId: it.2) }
    }
}
#endif
