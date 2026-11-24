import SwiftUI

struct PortfolioCalculatorView: View {
    @StateObject private var store = PortfolioStore.shared
    @Environment(\.dismiss) private var dismiss
    @State var keys: [String]
    @State private var initial = "10000"
    @State private var monthly = "200"
    @State private var startYear = 2000
    @State private var endYear = 2026
    @AppStorage("pfCurrency") private var currencyRaw = PortfolioCurrency.usd.rawValue
    @AppStorage("pfReal") private var real = false
    @State private var logScale = false

    init(initialKeys: [String]) {
        _keys = State(initialValue: initialKeys.filter { !$0.isEmpty })
    }

    private static let colors: [Color] = [Color(hex: 0xC9A96E), Color(hex: 0x8FBF9A), Color(hex: 0x7FA8D1)]
    private var currency: PortfolioCurrency { PortfolioCurrency(rawValue: currencyRaw) ?? .usd }
    private var initialValue: Double { Double(initial.replacingOccurrences(of: ",", with: ".")) ?? 0 }
    private var monthlyValue: Double { Double(monthly.replacingOccurrences(of: ",", with: ".")) ?? 0 }

    private struct Result: Identifiable {
        let key: String
        let color: Color
        let run: PortfolioRun
        let values: [Double]
        var id: String { key }
    }

    private var results: [Result] {
        keys.enumerated().compactMap { i, k in
            guard let info = store.info(k),
                  let run = store.run(info, from: String(format: "%04d-01", startYear), to: String(format: "%04d-12", endYear),
                                      currency: currency, real: real) else { return nil }
            return Result(key: k, color: Self.colors[i % Self.colors.count], run: run,
                          values: run.growth(initial: initialValue, monthly: monthlyValue))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    inputs
                    portfolioPickers
                    let res = results
                    if res.isEmpty {
                        Text("Not enough history").font(Theme.ui(.footnote)).foregroundColor(Theme.muted)
                    } else {
                        chart(res)
                        ForEach(res) { r in resultCard(r) }
                    }
                    PortfolioDisclaimer()
                }
                .padding()
            }
            .themeScreen()
            .navigationTitle(Text("Calculator"))
            .navigationBarTitleDisplayMode(.inline)
            .themeNavBar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Text("Done") }.tint(Theme.gold)
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
        .environment(\.layoutDirection, AppLanguage.isRightToLeft ? .rightToLeft : .leftToRight)
    }

    // MARK: Inputs

    private var inputs: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                field("Initial amount", text: $initial)
                field("Monthly contribution", text: $monthly)
            }
            HStack(spacing: 10) {
                yearPicker("From year", selection: $startYear, range: 1926...(endYear - 1))
                yearPicker("To year", selection: $endYear, range: (startYear + 1)...2026)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(PortfolioCurrency.allCases, id: \.self) { c in
                        Button { currencyRaw = c.rawValue } label: { Text(verbatim: c.rawValue).themeChip(selected: currency == c) }
                            .buttonStyle(.plain)
                    }
                    PortfolioChip(title: "Nominal", selected: !real) { real = false }
                    PortfolioChip(title: "Real", selected: real) { real = true }
                    PortfolioChip(title: "Log scale", selected: logScale) { logScale.toggle() }
                }
            }
        }
    }

    private func field(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.ui(.caption2)).foregroundColor(Theme.muted).lineLimit(1).minimumScaleFactor(0.7)
            TextField("", text: text)
                .keyboardType(.decimalPad)
                .font(Theme.ui(.body, weight: .medium))
                .foregroundColor(Theme.text)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.bg2, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line, lineWidth: 1))
        }
    }

    private func yearPicker(_ title: LocalizedStringKey, selection: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
            Menu {
                Picker(selection: selection) {
                    ForEach(Array(range.reversed()), id: \.self) { y in Text(verbatim: String(y)).tag(y) }
                } label: { Text(title) }
            } label: {
                HStack {
                    Text(verbatim: String(selection.wrappedValue)).font(Theme.ui(.body, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .outlinedControl(gold: false)
            }
        }
    }

    private var portfolioPickers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compare up to 3 portfolios").font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
            ForEach(Array(keys.enumerated()), id: \.offset) { i, k in
                HStack(spacing: 8) {
                    Circle().fill(Self.colors[i % Self.colors.count]).frame(width: 10, height: 10)
                    Menu {
                        Picker(selection: Binding(get: { keys[i] }, set: { keys[i] = $0 })) {
                            if let r = store.reference { Text(verbatim: store.name(r.key)).tag(r.key) }
                            ForEach(store.models) { m in Text(verbatim: store.name(m.key)).tag(m.key) }
                        } label: { Text("Choose portfolio") }
                    } label: {
                        HStack {
                            Text(verbatim: store.name(k)).font(Theme.ui(.footnote, weight: .medium)).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 9)
                        .outlinedControl(gold: false)
                    }
                    if keys.count > 1 {
                        Button { keys.remove(at: i) } label: {
                            Image(systemName: "minus.circle").frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain).foregroundColor(Theme.muted)
                        .accessibilityLabel(Text("Remove"))
                    }
                }
            }
            if keys.count < 3 {
                Button {
                    let next = store.models.first { !keys.contains($0.key) }?.key ?? PortfolioStore.referenceKey
                    keys.append(next)
                } label: {
                    Label { Text("Add portfolio") } icon: { Image(systemName: "plus") }
                }
                .buttonStyle(OutlinedButtonStyle())
            }
        }
    }

    // MARK: Output

    private func chart(_ res: [Result]) -> some View {
        var lines = res.enumerated().map { i, r in
            GrowthChart.Line(name: store.name(r.key), color: r.color, dashed: false,
                             points: chartPoints(months: r.run.months, values: r.values, series: r.key, offset: i * 10_000))
        }
        if let first = res.first {
            let n = first.run.months.count
            let contrib = (0...n).map { initialValue + monthlyValue * Double($0) }
            lines.append(GrowthChart.Line(name: AppLanguage.string("Contributions"), color: Theme.muted, dashed: true,
                                          points: chartPoints(months: first.run.months, values: contrib, series: "c", offset: 90_000)))
        }
        return VStack(alignment: .leading, spacing: 8) {
            GrowthChart(lines: lines.filter { $0.points.allSatisfy { $0.y > 0 } || !logScale }, currency: currency, log: logScale)
            ChartLegend(items: lines.map { ($0.name, $0.color, $0.dashed) })
        }
        .padding(12)
        .panelCard()
    }

    private func resultCard(_ r: Result) -> some View {
        let m = r.run.metrics
        let final = r.values.last ?? 0
        let contributed = initialValue + monthlyValue * Double(r.run.returns.count)
        let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(r.color).frame(width: 10, height: 10)
                Text(verbatim: store.name(r.key)).font(Theme.ui(.subheadline, weight: .semibold)).foregroundColor(Theme.text)
                    .lineLimit(2)
            }
            if m.from > String(format: "%04d-01", startYear) {
                Text("History starts \(PortfolioFormat.month(m.from))").font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
            }
            LazyVGrid(columns: cols, spacing: 10) {
                MetricCell(title: "Final value", value: PortfolioFormat.money(final, currency: currency), tint: Theme.gold)
                MetricCell(title: "Total contributed", value: PortfolioFormat.money(contributed, currency: currency))
                MetricCell(title: "Gain", value: PortfolioFormat.money(final - contributed, currency: currency),
                           tint: Theme.changeColor(final - contributed))
                MetricCell(title: "Return per year", value: PortfolioFormat.percent(m.cagr), tint: Theme.changeColor(m.cagr))
            }
        }
    }
}
