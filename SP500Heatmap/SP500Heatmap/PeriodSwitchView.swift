import SwiftUI

struct PeriodSwitchView: View {
    @Binding var selectedPeriod: String
    @EnvironmentObject private var indexStore: IndexStore

    // "SC" (live session change) exists only for indices with live prices.
    private var periods: [String] {
        let all = ["SC", "1d", "3d", "7d", "30d", "180d", "1y"]
        return indexStore.isLive ? all : all.filter { $0 != "SC" }
    }

    var body: some View {
        let active = indexStore.effectivePeriod(selectedPeriod)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(periods, id: \.self) { period in
                    Button(action: {
                        selectedPeriod = period
                    }) {
                        Text(LocalizedStringKey(period))
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(active == period ? Color.blue : Color.gray.opacity(0.3))
                            .foregroundColor(active == period ? .white : .primary)
                            .cornerRadius(8)
                    }
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
            .font(.caption2)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
        }
    }
}
