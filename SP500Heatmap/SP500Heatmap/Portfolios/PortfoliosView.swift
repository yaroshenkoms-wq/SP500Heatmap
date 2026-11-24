import SwiftUI

struct PortfoliosView: View {
    @StateObject private var store = PortfolioStore.shared
    @AppStorage("pfPeriod") private var periodRaw = PortfolioPeriod.y10.rawValue
    @AppStorage("pfCurrency") private var currencyRaw = PortfolioCurrency.usd.rawValue
    @AppStorage("pfReal") private var real = false
    @AppStorage("pfSort") private var sortRaw = PortfolioSort.cagr.rawValue
    @State private var showCalculator = false

    private var period: Binding<PortfolioPeriod> {
        Binding(get: { PortfolioPeriod(rawValue: periodRaw) ?? .y10 }, set: { periodRaw = $0.rawValue })
    }
    private var currency: Binding<PortfolioCurrency> {
        Binding(get: { PortfolioCurrency(rawValue: currencyRaw) ?? .usd }, set: { currencyRaw = $0.rawValue })
    }
    private var sort: PortfolioSort { PortfolioSort(rawValue: sortRaw) ?? .cagr }

    var body: some View {
        VStack(spacing: 0) {
            if !store.isAvailable {
                Text("Data is unavailable.")
                    .font(Theme.ui(.footnote)).foregroundColor(Theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PortfolioOptionsBar(period: period, currency: currency, real: $real)
                    .padding(.top, 8)
                sortBar
                list
            }
        }
        .themeScreen()
        .navigationTitle(Text("Portfolios"))
        .navigationBarTitleDisplayMode(.inline)
        .themeNavBar()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCalculator = true } label: { Image(systemName: "function") }
                    .tint(Theme.gold)
                    .accessibilityLabel(Text("Calculator"))
            }
        }
        .sheet(isPresented: $showCalculator) {
            PortfolioCalculatorView(initialKeys: [store.models.first?.key ?? ""])
        }
    }

    private var sortBar: some View {
        HStack(spacing: 10) {
            Text("Sort").font(Theme.ui(.caption)).foregroundColor(Theme.muted)
            ForEach(PortfolioSort.allCases) { s in
                PortfolioChip(title: sortTitle(s), selected: sort == s) { sortRaw = s.rawValue }
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func sortTitle(_ s: PortfolioSort) -> LocalizedStringKey {
        switch s {
        case .cagr: return "Return"
        case .drawdown: return "Drawdown"
        case .risk: return "Risk"
        }
    }

    private var list: some View {
        let p = period.wrappedValue, c = currency.wrappedValue
        let rows = store.rows(period: p, currency: c, real: real, sort: sort)
        let ref = store.reference.flatMap { store.run($0, period: p, currency: c, real: real) }
        return ScrollView {
            LazyVStack(spacing: 6, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(rows) { row in
                        NavigationLink {
                            PortfolioDetailView(info: row.info)
                        } label: {
                            PortfolioRowView(info: row.info, run: row.run, ref: ref, isReference: false)
                        }
                        .buttonStyle(.plain)
                    }
                    PortfolioDisclaimer().padding(.vertical, 12)
                } header: {
                    if let refInfo = store.reference {
                        NavigationLink {
                            PortfolioDetailView(info: refInfo)
                        } label: {
                            PortfolioRowView(info: refInfo, run: ref, ref: ref, isReference: true)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 4)
                        .background(Theme.bg)
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

struct PortfolioRowView: View {
    @ObservedObject private var store = PortfolioStore.shared
    let info: PortfolioInfo
    let run: PortfolioRun?
    let ref: PortfolioRun?
    let isReference: Bool

    private var beats: Bool? {
        guard !isReference, let a = run?.metrics.cagr, let b = ref?.metrics.cagr else { return nil }
        return a >= b
    }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isReference ? Theme.gold : (beats == nil ? Theme.line : (beats! ? Theme.ok : Theme.danger)))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: store.name(info.key))
                    .font(Theme.ui(.subheadline, weight: .medium))
                    .foregroundColor(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    RiskBadge(risk: info.risk)
                    if isReference {
                        Text("Reference").font(Theme.ui(.caption2, weight: .medium)).foregroundColor(Theme.gold)
                    } else if let run {
                        Text(verbatim: PortfolioFormat.month(run.metrics.from))
                            .font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
                    }
                }
            }
            Spacer(minLength: 6)
            if let m = run?.metrics {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(verbatim: PortfolioFormat.percent(m.cagr))
                        .font(Theme.ui(.callout, weight: .semibold))
                        .foregroundColor(Theme.changeColor(m.cagr))
                    HStack(spacing: 4) {
                        Text("Drawdown").font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
                        Text(verbatim: PortfolioFormat.percent(m.maxDrawdown, digits: 0))
                            .font(Theme.ui(.caption2, weight: .medium)).foregroundColor(Theme.danger)
                    }
                }
            } else {
                Text("Not enough history").font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
                    .multilineTextAlignment(.trailing).frame(maxWidth: 110, alignment: .trailing)
            }
            Image(systemName: "chevron.right").font(.caption2).foregroundColor(Theme.muted)
                .flipsForRightToLeftLayoutDirection(true)
        }
        .padding(10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(isReference ? Theme.goldLine : Theme.line, lineWidth: 1))
    }
}
