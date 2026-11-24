import SwiftUI

@main
struct SP500WatchApp: App {
    @StateObject private var world = WatchWorldStore.shared
    @StateObject private var lists = WatchListsStore.shared
    @AppStorage("watchPeriod") private var period = "1d"

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                HomeView()
            }
            .tint(WTheme.gold)
            .preferredColorScheme(.dark)
            .environmentObject(world)
            .environmentObject(lists)
            .task { await world.load() }
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var lists: WatchListsStore

    var body: some View {
        List {
            NavigationLink {
                WorldView()
            } label: {
                Label("World markets", systemImage: "globe")
            }
            NavigationLink {
                WatchlistsView()
            } label: {
                Label("Watchlists", systemImage: "star")
            }
        }
        .foregroundStyle(WTheme.text)
        .navigationTitle(Text(verbatim: "SP500"))
    }
}

/// Период (общий для всех экранов часов): нажатие переключает 1d → 7d → 30d → 1y.
struct PeriodMenu: View {
    @AppStorage("watchPeriod") private var period = "1d"
    static let periods = ["1d", "7d", "30d", "1y"]

    var body: some View {
        Button {
            let i = Self.periods.firstIndex(of: period) ?? 0
            period = Self.periods[(i + 1) % Self.periods.count]
        } label: {
            Text(verbatim: period).foregroundStyle(WTheme.gold)
        }
    }
}

/// Строка «название — полоска цвета — %».
struct ChangeBar: View {
    let change: Double?
    let period: String

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(WTheme.fill(change, period: period))
            .frame(width: 4)
    }
}

func regionTitle(_ id: String) -> LocalizedStringKey {
    switch id {
    case "americas": return "Americas"
    case "europe": return "Europe"
    case "asia_pacific": return "Asia-Pacific"
    case "assets": return "Crypto & ETFs"
    default: return "Other"
    }
}

func priceString(_ value: Double, currency: String?) -> String {
    value.formatted(.currency(code: currency ?? "USD"))
}

struct LoadingOrEmpty: View {
    let loading: Bool
    var body: some View {
        if loading { ProgressView() } else { Text("No data").foregroundStyle(WTheme.muted) }
    }
}
