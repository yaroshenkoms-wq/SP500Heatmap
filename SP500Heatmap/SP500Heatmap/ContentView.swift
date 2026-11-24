import SwiftUI

struct ContentView: View {
    @StateObject private var webSocketManager = WebSocketManager.shared
    @StateObject private var indexStore = IndexStore.shared
    @StateObject private var worldStore = WorldStore.shared
    @State private var path: [String] = []
    @State private var stackToken = UUID()
    @State private var showSettings = false
    #if DEBUG
    @State private var debugScreen: String?
    #endif
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.scenePhase) private var scenePhase

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var splitSelection: String?

    private var hasWorld: Bool { !worldStore.regions.isEmpty }
    private var useSplit: Bool { sizeClass == .regular && hasWorld }

    private func selectIndex(_ id: String?) {
        if let id { indexStore.selectedId = id }
        splitSelection = id
    }

    @ViewBuilder private var rootContent: some View {
        if useSplit {
            NavigationSplitView(columnVisibility: .constant(.all)) {
                IndexSidebar(store: worldStore, selection: $splitSelection,
                             onSelect: { selectIndex($0) }, onHome: { selectIndex(nil) },
                             onSettings: { showSettings = true })
            } detail: {
                NavigationStack {
                    if splitSelection == nil {
                        WorldOverviewView(store: worldStore, onSelect: { selectIndex($0.id) },
                                          onSettings: { showSettings = true })
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
                    }, onSettings: { showSettings = true })
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
        // Смена палитры или размера плиток пересобирает карты (окно настроек стоит снаружи).
        .id("\(stackToken.uuidString)-\(settings.palette.rawValue)-\(settings.sizeMode.rawValue)")
        .sheet(isPresented: $showSettings) {
            SettingsView(indices: worldStore.regions.flatMap { $0.indices })
                .presentationSizing(.form)
        }
        #if DEBUG
        .fullScreenCover(item: Binding(get: { debugScreen.map(DebugScreen.init) }, set: { debugScreen = $0?.id })) { screen in
            NavigationStack {
                if screen.id == "portfolios" { PortfoliosView() }
                else if screen.id == "favorites" { FavoritesView() }
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
        .environment(\.goHome, hasWorld ? { goHome() } : nil)
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
            // `-openScreen settings|portfolios|favorites|portfolio:m_dalio` — сразу открыть экран.
            if let screen = UserDefaults.standard.string(forKey: "openScreen") {
                if screen == "settings" { showSettings = true } else { debugScreen = screen }
            }
            #endif
        }
        .task {
            webSocketManager.connect()
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
