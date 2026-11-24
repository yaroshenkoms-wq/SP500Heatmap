import SwiftUI

/// iPad: список индексов по регионам с изменением за период (слева), карта выбранного индекса справа.
struct IndexSidebar: View {
    @ObservedObject var store: WorldStore
    @Binding var selection: String?
    let onSelect: (String) -> Void
    let onHome: () -> Void
    @AppStorage("worldPeriod") private var period = "1d"

    var body: some View {
        List {
            Button(action: onHome) {
                HStack {
                    Image(systemName: "globe").foregroundColor(Theme.gold)
                    Text("World markets")
                        .font(Theme.ui(.body, weight: selection == nil ? .semibold : .regular))
                        .foregroundColor(selection == nil ? Theme.gold : Theme.text)
                }
            }
            .listRowBackground(Theme.bg2)
            ForEach(store.regions) { region in
                Section {
                    ForEach(region.drawable) { index in
                        Button { onSelect(index.id) } label: {
                            HStack {
                                Text(verbatim: "\(index.flag) \(index.name)")
                                    .font(Theme.ui(.subheadline, weight: selection == index.id ? .semibold : .regular))
                                    .foregroundColor(selection == index.id ? Theme.gold : Theme.text)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if let change = index.change(for: period) {
                                    Text(formatPercent(change))
                                        .font(Theme.ui(.footnote, weight: .medium))
                                        .foregroundColor(Theme.changeColor(change))
                                }
                            }
                        }
                        .listRowBackground(selection == index.id ? Theme.chip : Theme.bg2)
                    }
                } header: {
                    Text(region.title)
                        .font(Theme.ui(.caption, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundColor(Theme.muted)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .safeAreaInset(edge: .top, spacing: 0) {
            PeriodSwitchView(selectedPeriod: $period, availablePeriods: ["1d", "3d", "7d", "30d", "180d", "1y", "3y", "5y", "10y"])
                .background(Theme.bg)
        }
        .navigationTitle(Text("World markets"))
        .navigationBarTitleDisplayMode(.inline)
        .themeNavBar()
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                LanguageMenu()
            }
        }
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
    }
}
