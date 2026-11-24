import SwiftUI
import Charts

// Shared small views for the portfolio screens.

struct PortfolioDisclaimer: View {
    var body: some View {
        Text("Historical simulation, not investment advice. Past returns do not guarantee future results.")
            .font(Theme.ui(.caption2))
            .foregroundColor(Theme.muted)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("portfolioDisclaimer")
    }
}

struct RiskBadge: View {
    let risk: String
    private var label: LocalizedStringKey {
        switch risk {
        case "low": return "Low"
        case "high": return "High"
        default: return "Medium"
        }
    }
    private var color: Color {
        switch risk {
        case "low": return Theme.ok
        case "high": return Theme.danger
        default: return Theme.gold
        }
    }
    var body: some View {
        Text(label)
            .font(Theme.ui(.caption2, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.6), lineWidth: 1))
    }
}

struct PortfolioChip: View {
    let title: LocalizedStringKey
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) { Text(title).themeChip(selected: selected) }.buttonStyle(.plain)
    }
}

func periodTitle(_ p: PortfolioPeriod) -> LocalizedStringKey {
    switch p {
    case .y1: return "1Y"
    case .y3: return "3Y"
    case .y5: return "5Y"
    case .y10: return "10Y"
    case .y20: return "20Y"
    case .y30: return "30Y"
    case .all: return "Max"
    }
}

/// Period, currency and nominal/real selectors shared by list and detail (same stored settings).
struct PortfolioOptionsBar: View {
    @Binding var period: PortfolioPeriod
    @Binding var currency: PortfolioCurrency
    @Binding var real: Bool
    var periods: [PortfolioPeriod] = [.y3, .y5, .y10, .y20, .y30, .all]

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(periods) { p in
                        PortfolioChip(title: periodTitle(p), selected: period == p) { period = p }
                    }
                }
                .padding(.horizontal)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(PortfolioCurrency.allCases, id: \.self) { c in
                        Button { currency = c } label: { Text(verbatim: c.rawValue).themeChip(selected: currency == c) }
                            .buttonStyle(.plain)
                    }
                    PortfolioChip(title: "Nominal", selected: !real) { real = false }
                    PortfolioChip(title: "Real", selected: real) { real = true }
                }
                .padding(.horizontal)
            }
        }
    }
}

struct SeriesPoint: Identifiable {
    let id: Int
    let x: Double
    let y: Double
    let series: String
}

/// Chart points for a value series (index 0 = start), thinned to roughly 300 points.
func chartPoints(months: [String], values: [Double], series: String, offset: Int = 0) -> [SeriesPoint] {
    guard values.count == months.count + 1, let first = months.first else { return [] }
    let stride = max(1, values.count / 300)
    var out: [SeriesPoint] = []
    // start point: one month before the first month
    let start = PortfolioFormat.decimalYear(first) - 1.0 / 12
    for i in Swift.stride(from: 0, to: values.count, by: stride) {
        let x = i == 0 ? start : PortfolioFormat.decimalYear(months[i - 1]) + 1.0 / 12
        out.append(SeriesPoint(id: offset + i, x: x, y: values[i], series: series))
    }
    if let last = values.indices.last, last % stride != 0 {
        out.append(SeriesPoint(id: offset + last, x: PortfolioFormat.decimalYear(months[last - 1]) + 1.0 / 12, y: values[last], series: series))
    }
    return out
}

struct GrowthChart: View {
    struct Line: Identifiable {
        let name: String
        let color: Color
        let dashed: Bool
        let points: [SeriesPoint]
        var id: String { name }
    }
    let lines: [Line]
    let currency: PortfolioCurrency
    let log: Bool

    var body: some View {
        Chart {
            ForEach(lines) { line in
                ForEach(line.points) { p in
                    LineMark(x: .value("Year", p.x), y: .value("Value", p.y), series: .value("Series", line.name))
                        .foregroundStyle(line.color)
                        .lineStyle(StrokeStyle(lineWidth: line.dashed ? 1.3 : 2, dash: line.dashed ? [4, 3] : []))
                        .interpolationMethod(.linear)
                }
            }
        }
        .chartYScale(type: log ? .log : .linear)
        .chartXScale(domain: .automatic(includesZero: false))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { v in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(verbatim: String(Int(d.rounded()))) }
                }
                .foregroundStyle(Theme.muted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { v in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(verbatim: PortfolioFormat.moneyCompact(d, currency: currency)) }
                }
                .foregroundStyle(Theme.muted)
            }
        }
        .chartLegend(.hidden)
        .frame(height: 220)
    }
}

struct ChartLegend: View {
    let items: [(String, Color, Bool)]
    var body: some View {
        FlowRow {
            ForEach(items.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1).fill(items[i].1).frame(width: 14, height: items[i].2 ? 1.5 : 3)
                    Text(verbatim: items[i].0).font(Theme.ui(.caption2)).foregroundColor(Theme.muted).lineLimit(1)
                }
            }
        }
    }
}

/// Simple wrapping row.
struct FlowRow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 14) { content() } }
    }
}

struct MetricCell: View {
    let title: LocalizedStringKey
    let value: String
    var sub: String? = nil
    var tint: Color = Theme.text
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.ui(.caption2)).foregroundColor(Theme.muted).lineLimit(1).minimumScaleFactor(0.7)
            Text(verbatim: value).font(Theme.ui(.title3, weight: .semibold)).foregroundColor(tint).lineLimit(1).minimumScaleFactor(0.6)
            if let sub {
                Text(verbatim: sub).font(Theme.ui(.caption2)).foregroundColor(Theme.muted).lineLimit(1).minimumScaleFactor(0.6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .panelCard()
    }
}

/// Entry button for the home header.
struct PortfoliosEntryButton: View {
    var body: some View {
        NavigationLink {
            PortfoliosView()
        } label: {
            Image(systemName: "chart.pie")
                .font(.subheadline)
                .frame(width: 34, height: 34)
                .outlinedControl()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Portfolios"))
    }
}
