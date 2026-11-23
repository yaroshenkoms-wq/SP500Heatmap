import SwiftUI

struct ContentView: View {
    @StateObject private var networkService = NetworkService.shared
    @StateObject private var webSocketManager = WebSocketManager.shared
    @StateObject private var performanceStore = PerformanceStore.shared
    @StateObject private var indexStore = IndexStore.shared
    @State private var sectors: [Sector] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading data...")
                } else if let error = errorMessage {
                    VStack {
                        Text("Error")
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.gray)
                        Button("Retry") {
                            Task {
                                await loadData()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    SectorsHeatmapView(sectors: sectors, webSocketManager: webSocketManager, performanceStore: performanceStore)
                }
            }
        }
        .environmentObject(indexStore)
        .task(id: indexStore.selectedId) {
            await indexStore.loadIfNeeded()
            await loadData()
        }
        .task {
            webSocketManager.connect()
        }
        .onDisappear {
            webSocketManager.disconnect()
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
