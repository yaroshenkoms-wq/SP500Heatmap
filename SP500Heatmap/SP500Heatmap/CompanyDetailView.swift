import SwiftUI
import Charts

struct CompanyDetailView: View {
    let company: Company
    @ObservedObject var webSocketManager: WebSocketManager
    @State private var selectedPeriod = "SC"
    @State private var history: [DailyClose] = []
    @EnvironmentObject private var indexStore: IndexStore
    @Environment(\.dismiss) private var dismiss

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
        "SC": 1, "1d": 1, "3d": 3, "7d": 5, "30d": 21, "180d": 126, "1y": 252
    ]

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    // Реальные цены закрытия за выбранный период (из истории с бэкенда)
    var pricesForPeriod: [StockPrice] {
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
    
    var body: some View {
        VStack(spacing: 0) {
            // Верхняя панель с кнопкой Back, названием компании и изменением
            VStack(spacing: 4) {
                HStack {
                    Button(action: {
                        dismiss()
                    }) {
                        HStack {
                            Image(systemName: "chevron.backward")
                            Text("Back")
                        }
                        .foregroundColor(.blue)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(company.ticker)
                            .font(.title2)
                            .bold()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(company.name)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(indexStore.formatPrice(currentPrice))
                            .font(.title2)
                            .bold()
                        Text(formatPercent(periodChangePercent))
                            .font(.headline)
                            .foregroundColor(periodChangePercent >= 0 ? .green : .red)
                    }
                }
                .padding(.horizontal)
                
                // Переключатель периодов
                PeriodSwitchView(selectedPeriod: $selectedPeriod)
            }
            .padding(.top, 8)
            .background(Color(.systemBackground))
            
            // График
            VStack(alignment: .leading) {
                if pricesForPeriod.isEmpty {
                    ProgressView()
                        .frame(height: 200)
                } else {
                    Chart(pricesForPeriod) { item in
                        LineMark(
                            x: .value("Date", item.date),
                            y: .value("Price", item.price)
                        )
                        .foregroundStyle(.blue)
                    }
                    .frame(height: 200)
                    .padding(.horizontal)
                }
            }
            .padding(.top, 8)
            
            // Описание компании
            VStack(alignment: .leading) {
                Text("Description")
                    .font(.headline)
                Text(verbatim: (company.description?.isEmpty ?? true) ? AppLanguage.string("No description available.") : (company.description ?? ""))
                    .font(.body)
                    .foregroundColor(.gray)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            
            // Метрики
            VStack(alignment: .leading) {
                Text("Metrics")
                    .font(.headline)
                HStack {
                    MetricItem(title: "Market Cap", value: formatMarketCap(company.marketCap))
                    Spacer()
                    MetricItem(title: "P/E", value: company.peRatio != nil ? formatDecimal(company.peRatio!) : AppLanguage.string("N/A"))
                    Spacer()
                    MetricItem(title: "Volume", value: company.volume != nil ? formatVolume(company.volume!) : AppLanguage.string("N/A"))
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            
            Spacer()
        }
        .navigationBarHidden(true)
        .edgesIgnoringSafeArea(.bottom)
        .task {
            await loadHistory()
        }
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
                .font(.caption)
                .foregroundColor(.gray)
            Text(value)
                .font(.body)
                .bold()
        }
    }
}
