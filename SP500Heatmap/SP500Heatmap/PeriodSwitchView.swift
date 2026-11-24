import SwiftUI

struct PeriodSwitchView: View {
    @Binding var selectedPeriod: String
    var availablePeriods: [String]? = nil
    @EnvironmentObject private var indexStore: IndexStore

    // "SC" (live session change) exists only for indices with live prices.
    private var periods: [String] {
        if let availablePeriods { return availablePeriods }
        let all = ["SC", "1d", "3d", "7d", "30d", "180d", "1y"]
        return indexStore.isLive ? all : all.filter { $0 != "SC" }
    }

    var body: some View {
        let active = availablePeriods == nil ? indexStore.effectivePeriod(selectedPeriod) : selectedPeriod
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(periods, id: \.self) { period in
                    Button(action: {
                        selectedPeriod = period
                    }) {
                        Text(LocalizedStringKey(period))
                            .themeChip(selected: active == period)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 44)
    }
}

// Small note under the header of a map whose index has no live prices.
struct ClosingPricesNote: View {
    @EnvironmentObject private var indexStore: IndexStore

    var body: some View {
        if !indexStore.isLive {
            Group {
                if let date = localizedShortDate(indexStore.current.historyThrough) {
                    Text("Closing prices · \(date)")
                } else {
                    Text("Closing prices")
                }
            }
            .font(Theme.ui(.caption2))
            .foregroundColor(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
        }
    }
}
