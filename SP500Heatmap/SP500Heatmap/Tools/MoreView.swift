import SwiftUI

/// "More" tab: calendar, model portfolios, alerts, settings, about.
struct MoreView: View {
    let onSettings: () -> Void

    var body: some View {
        List {
            Section {
                NavigationLink { CalendarView() } label: { row("Calendar", "calendar") }
                NavigationLink { PortfoliosView() } label: { row("Model portfolios", "chart.pie") }
                NavigationLink { AlertsView() } label: { row("Stock alerts", "bell") }
            }
            .listRowBackground(Theme.panel)
            Section {
                Button(action: onSettings) { row("Settings", "gearshape") }
                NavigationLink { AboutView() } label: { row("About and data sources", "info.circle") }
            }
            .listRowBackground(Theme.panel)
        }
        .scrollContentBackground(.hidden)
        .themeScreen()
        .navigationTitle(Text("More"))
        .navigationBarTitleDisplayMode(.inline)
        .themeNavBar()
    }

    private func row(_ title: LocalizedStringKey, _ icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundColor(Theme.gold).frame(width: 26)
            Text(title).font(Theme.ui(.body)).foregroundColor(Theme.text)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Data sources").font(Theme.ui(.subheadline, weight: .medium)).foregroundColor(Theme.text)
                    Text(verbatim: "Yahoo Finance · Finnhub · CoinGecko").font(Theme.ui(.footnote)).foregroundColor(Theme.gold)
                    Text("Company filings (13F) of famous investors come from public SEC data.")
                        .font(Theme.ui(.caption)).foregroundColor(Theme.muted)
                    Text("Prices may be delayed. This app is for information only and is not investment advice.")
                        .font(Theme.ui(.caption)).foregroundColor(Theme.muted)
                }
                .listRowBackground(Theme.panel)
                HStack {
                    Text("Version").font(Theme.ui(.subheadline)).foregroundColor(Theme.text)
                    Spacer()
                    Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                        .font(Theme.ui(.subheadline)).foregroundColor(Theme.muted)
                }
                .listRowBackground(Theme.panel)
            }
        }
        .scrollContentBackground(.hidden)
        .themeScreen()
        .navigationTitle(Text("About"))
        .navigationBarTitleDisplayMode(.inline)
        .themeNavBar()
    }
}
