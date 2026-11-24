import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity «Market session»: экран блокировки и Dynamic Island, чёрно-золотая тема.
struct MarketSessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: IndexActivityAttributes.self) { context in
            MarketSessionLockView(state: context.state)
                .activityBackgroundTint(WTheme.bg)
                .activitySystemActionForegroundColor(WTheme.gold)
                .environment(\.locale, WTheme.locale)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(verbatim: s.name)
                        .font(.system(.subheadline, design: .serif).weight(.semibold))
                        .foregroundColor(WTheme.text)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(verbatim: WTheme.percent(s.changePct))
                        .font(.system(.title3).weight(.semibold))
                        .foregroundColor(SharedHeat.textColor(for: s.changePct))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    MoversRow(movers: s.movers)
                }
            } compactLeading: {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundColor(WTheme.gold)
            } compactTrailing: {
                Text(verbatim: WTheme.percent(s.changePct))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(SharedHeat.textColor(for: s.changePct))
            } minimal: {
                Image(systemName: s.changePct >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .foregroundColor(SharedHeat.textColor(for: s.changePct))
            }
            .keylineTint(WTheme.gold)
        }
    }
}

private struct MarketSessionLockView: View {
    let state: IndexActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Market session")
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundColor(WTheme.gold)
                    Text(verbatim: state.name)
                        .font(.system(.title3, design: .serif))
                        .foregroundColor(WTheme.text)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: WTheme.percent(state.changePct))
                        .font(.system(.title2).weight(.semibold))
                        .foregroundColor(SharedHeat.textColor(for: state.changePct))
                    if let value = state.value {
                        Text(verbatim: value.formatted(.number.precision(.fractionLength(2)).locale(WTheme.locale)))
                            .font(.caption)
                            .foregroundColor(WTheme.muted)
                    }
                }
            }
            if !state.movers.isEmpty {
                MoversRow(movers: state.movers)
            }
        }
        .padding(14)
    }
}

private struct MoversRow: View {
    let movers: [IndexActivityAttributes.Mover]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(movers.prefix(3), id: \.ticker) { mover in
                VStack(spacing: 1) {
                    Text(verbatim: mover.ticker)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(WTheme.text)
                        .lineLimit(1)
                    Text(verbatim: WTheme.percent(mover.changePct))
                        .font(.caption2)
                        .foregroundColor(SharedHeat.textColor(for: mover.changePct))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(WTheme.panel))
            }
        }
    }
}
