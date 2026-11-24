import SwiftUI

struct PeriodSwitchView: View {
    @Binding var selectedPeriod: String
    var availablePeriods: [String]? = nil
    @EnvironmentObject private var indexStore: IndexStore

    // "SC" (live session change) exists only for indices with live prices.
    private var periods: [String] {
        if let availablePeriods { return availablePeriods }
        let all = ["SC", "1d", "3d", "7d", "30d", "180d", "1y", "3y", "5y", "10y"]
        return indexStore.isLive ? all : all.filter { $0 != "SC" }
    }

    var body: some View {
        let active = availablePeriods == nil ? indexStore.effectivePeriod(selectedPeriod) : selectedPeriod
        VStack(alignment: .leading, spacing: 2) {
        ScrollViewReader { proxy in
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
                        .id(period)
                    }
                }
                .padding(.horizontal)
            }
            // The selected chip may be off-screen (3y/5y/10y at the end of a long row): bring it into view.
            .onAppear { proxy.scrollTo(active, anchor: .center) }
            .onChange(of: active) { _, new in
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
        .frame(height: 44)
            if ["3y", "5y", "10y"].contains(active) {
                // Эффект выживших: в расчёте только нынешние участники индекса.
                Text("Long periods use today's index members; companies that left the index are not counted.")
                    .font(Theme.ui(.caption2))
                    .foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)
            }
        }
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
