import SwiftUI

struct ContentView: View {
    @StateObject private var networkService = NetworkService.shared
    @StateObject private var webSocketManager = WebSocketManager.shared
    @StateObject private var performanceStore = PerformanceStore.shared
    @State private var sectors: [Sector] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Загрузка данных...")
                } else if let error = errorMessage {
                    VStack {
                        Text("Ошибка")
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.gray)
                        Button("Повторить") {
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
        .task {
            await loadData()
            webSocketManager.connect()
            performanceStore.loadIfNeeded()
        }
        .onDisappear {
            webSocketManager.disconnect()
        }
    }
    
    private func loadData() async {
        isLoading = true
        errorMessage = nil
        
        do {
            let fetchedSectors = try await networkService.fetchMarketHierarchy()
            await MainActor.run {
                self.sectors = fetchedSectors
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }
}

#Preview {
    ContentView()
}
