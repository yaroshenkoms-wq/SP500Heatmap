import SwiftUI
import UniformTypeIdentifiers

/// Личный портфель: вкладка «Portfolio». Без параметров.
struct MyPortfolioView: View {
    @ObservedObject private var store = MyPortfolioStore.shared
    @ObservedObject private var market = PfMarketData.shared
    @EnvironmentObject private var indexStore: IndexStore
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var editing: EditorTarget?
    @State private var showNew = false
    @State private var newName = ""
    @State private var newBase: PfBase = .EUR
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showImporter = false
    @State private var importMessage: String?
    @State private var confirmDelete = false

    struct EditorTarget: Identifiable {
        let id = UUID()
        var transaction: MyPortfolio.Transaction?
        var ticker: String?
    }

    var body: some View {
        NavigationStack {
            Group {
                if let portfolio = store.selected {
                    content(portfolio)
                } else {
                    emptyState
                }
            }
            .themeScreen()
            .navigationTitle(Text("Portfolio"))
            .navigationBarTitleDisplayMode(.inline)
            .themeNavBar()
            .toolbar { toolbar }
        }
        .tint(Theme.gold)
        .sheet(item: $editing) { target in
            if let p = store.selected {
                TransactionEditor(portfolio: p, existing: target.transaction, presetTicker: target.ticker)
            }
        }
        .alert("New portfolio", isPresented: $showNew) {
            TextField("Portfolio name", text: $newName)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                store.create(name: name.isEmpty ? AppLanguage.string("My portfolio") : name, base: newBase)
                newName = ""
            }
        } message: {
            Text("Base currency can be changed later in the portfolio menu.")
        }
        .alert("Rename portfolio", isPresented: $showRename) {
            TextField("Portfolio name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if var p = store.selected, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    p.name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.update(p)
                }
            }
        }
        .confirmationDialog("Delete this portfolio?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete portfolio", role: .destructive) { if let p = store.selected { store.delete(p.id) } }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
            importCSV(result)
        }
        .alert(importMessage ?? "", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .task { await market.loadCatalog(indices: indexStore.indices) }
    }

    // MARK: панель

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                ForEach(store.portfolios) { p in
                    Button {
                        store.selectedId = p.id
                    } label: {
                        Label(p.name, systemImage: p.id == store.selected?.id ? "checkmark" : "briefcase")
                    }
                }
                Divider()
                Button { showNew = true } label: { Label("New portfolio", systemImage: "plus") }
            } label: {
                HStack(spacing: 4) {
                    Text(verbatim: store.selected?.name ?? AppLanguage.string("Portfolio"))
                        .font(Theme.ui(.subheadline, weight: .semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .foregroundColor(Theme.gold)
            }
            .accessibilityIdentifier("portfolioSwitcher")
        }
        if let p = store.selected {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = EditorTarget() } label: { Image(systemName: "plus") }
                    .accessibilityLabel(Text("Add transaction"))
                    .accessibilityIdentifier("addTransaction")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { renameText = p.name; showRename = true } label: { Label("Rename", systemImage: "pencil") }
                    Picker(selection: Binding(get: { p.baseCurrency }, set: { var q = p; q.baseCurrency = $0; store.update(q) })) {
                        ForEach(PfBase.allCases) { Text(verbatim: $0.rawValue).tag($0) }
                    } label: { Text("Base currency") }
                    Divider()
                    Button { showImporter = true } label: { Label("Import CSV", systemImage: "square.and.arrow.down") }
                    ShareLink(item: PfCSVExport(name: p.name, text: PfCSV.export(p.transactions)),
                              preview: SharePreview(p.name + ".csv")) {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                    }
                    Divider()
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete portfolio", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel(Text("More"))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "briefcase").font(.system(size: 44)).foregroundColor(Theme.gold)
            Text("Track your own portfolio").font(Theme.serif(.title2)).foregroundColor(Theme.text)
            Text("Add buys, sells and dividends to see value, profit, allocation and performance against an index.")
                .font(Theme.ui(.subheadline)).foregroundColor(Theme.muted).multilineTextAlignment(.center)
            Picker("Base currency", selection: $newBase) {
                ForEach(PfBase.allCases) { Text(verbatim: $0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).frame(maxWidth: 200)
            Button {
                store.create(name: AppLanguage.string("My portfolio"), base: newBase)
            } label: { Text("Create portfolio") }
                .buttonStyle(OutlinedButtonStyle())
                .accessibilityIdentifier("createPortfolio")
        }
        .padding(32)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: содержимое

    private func result(_ p: MyPortfolio) -> PfResult {
        PfCalc.compute(transactions: p.transactions, base: p.baseCurrency, fx: market.fx,
                       quotes: market.quotes, meta: market.meta)
    }

    @ViewBuilder
    private func content(_ p: MyPortfolio) -> some View {
        let r = result(p)
        ScrollView {
            VStack(spacing: 12) {
                if p.transactions.isEmpty {
                    emptyPortfolio(p)
                } else if sizeClass == .regular {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 12) {
                            PfSummaryCard(result: r, base: p.baseCurrency)
                            PfHoldingsList(holdings: r.holdings, base: p.baseCurrency) { editing = EditorTarget(ticker: $0) }
                            transactionsLink(p)
                        }
                        .frame(maxWidth: .infinity)
                        VStack(spacing: 12) {
                            PfPerformanceCard(portfolio: p)
                            PfTreemapCard(holdings: r.holdings)
                            PfAllocationCard(holdings: r.holdings, base: p.baseCurrency)
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    PfSummaryCard(result: r, base: p.baseCurrency)
                    #if DEBUG
                    // Снимки App Store (`-demoPortfolio`): карта портфеля сразу под сводкой.
                    if UserDefaults.standard.bool(forKey: "demoPortfolio") { PfTreemapCard(holdings: r.holdings) }
                    #endif
                    PfPerformanceCard(portfolio: p)
                    PfHoldingsList(holdings: r.holdings, base: p.baseCurrency) { editing = EditorTarget(ticker: $0) }
                    #if DEBUG
                    if !UserDefaults.standard.bool(forKey: "demoPortfolio") { PfTreemapCard(holdings: r.holdings) }
                    #else
                    PfTreemapCard(holdings: r.holdings)
                    #endif
                    PfAllocationCard(holdings: r.holdings, base: p.baseCurrency)
                    transactionsLink(p)
                }
                if !p.transactions.isEmpty {
                    PortfolioInsightView(holdings: r.holdings.map(PortfolioInsightHolding.init))
                    AskAIButton(question: .portfolio, suggestions: [.portfolio, .marketToday, .compare("AAPL", "MSFT")])
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                footer
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .refreshable { await market.refresh(p, indices: indexStore.indices) }
        .task(id: refreshKey(p)) { await market.refresh(p, indices: indexStore.indices) }
    }

    private func refreshKey(_ p: MyPortfolio) -> String {
        p.id.uuidString + "|" + p.baseCurrency.rawValue + "|" + p.tickers.joined(separator: ",")
    }

    private func emptyPortfolio(_ p: MyPortfolio) -> some View {
        VStack(spacing: 12) {
            Text("No transactions yet").font(Theme.ui(.headline)).foregroundColor(Theme.text)
            Text("Add your first buy, or import a CSV file (date,type,ticker,quantity,price,currency,fee).")
                .font(Theme.ui(.subheadline)).foregroundColor(Theme.muted).multilineTextAlignment(.center)
            HStack {
                Button { editing = EditorTarget() } label: { Label("Add transaction", systemImage: "plus") }
                    .buttonStyle(OutlinedButtonStyle())
                Button { showImporter = true } label: { Label("Import CSV", systemImage: "square.and.arrow.down") }
                    .buttonStyle(OutlinedButtonStyle())
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .panelCard()
    }

    private func transactionsLink(_ p: MyPortfolio) -> some View {
        NavigationLink {
            PfTransactionsView(portfolioId: p.id)
        } label: {
            HStack {
                Text("Transactions").font(Theme.ui(.subheadline, weight: .medium))
                Spacer()
                Text(verbatim: "\(p.transactions.count)").foregroundColor(Theme.muted)
                Image(systemName: "chevron.right").font(.caption).foregroundColor(Theme.muted)
            }
            .foregroundColor(Theme.text)
            .padding(14)
            .panelCard()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("transactionsLink")
    }

    private var footer: some View {
        VStack(spacing: 4) {
            if store.cloudSkipped {
                Text("This portfolio is too large for iCloud sync and is kept on this device only.")
                    .foregroundColor(Theme.gold)
            }
            Text("Prices are daily closes and may be delayed. Currency conversion uses daily exchange rates. Not investment advice.")
        }
        .font(Theme.ui(.caption2))
        .foregroundColor(Theme.muted)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    // MARK: CSV

    private func importCSV(_ result: Result<URL, Error>) {
        guard let p = store.selected, case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            importMessage = AppLanguage.string("Could not read the file.")
            return
        }
        var parsed = PfCSV.parse(text)
        for i in parsed.transactions.indices where parsed.transactions[i].indexId.isEmpty {
            parsed.transactions[i].indexId = market.entry(parsed.transactions[i].ticker)?.i ?? ""
        }
        store.add(parsed.transactions, to: p.id)
        importMessage = pfText("Imported %lld transactions, skipped %lld lines.", parsed.transactions.count, parsed.badLines.count)
    }
}

/// Файл CSV для «Поделиться».
struct PfCSVExport: Transferable {
    let name: String
    let text: String
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { item in
            let safe = item.name.replacingOccurrences(of: "/", with: "-")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe + ".csv")
            try item.text.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

// MARK: Итоговая карточка

struct PfSummaryCard: View {
    let result: PfResult
    let base: PfBase

    var body: some View {
        let s = result.summary
        let code = base.rawValue
        VStack(alignment: .leading, spacing: 12) {
            Text("Market value").font(Theme.ui(.caption)).foregroundColor(Theme.muted)
            Text(verbatim: pfMoney(s.value, code))
                .font(Theme.serif(.largeTitle)).foregroundColor(Theme.text)
                .minimumScaleFactor(0.6).lineLimit(1)
                .accessibilityIdentifier("portfolioValue")
            HStack(spacing: 6) {
                Text(verbatim: pfMoney(s.todayChange, code, signed: true))
                Text(verbatim: pfSignedPercent(s.todayPct))
                Text("today").foregroundColor(Theme.muted)
            }
            .font(Theme.ui(.subheadline, weight: .medium))
            .foregroundColor(Theme.changeColor(s.todayChange))
            Divider().overlay(Theme.line)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    stat("Total profit / loss", money: s.totalPL, pct: s.totalPLPct)
                    stat("Unrealized", money: s.unrealized, pct: s.unrealizedPct)
                }
                GridRow {
                    stat("Realized", money: s.realized, pct: nil)
                    stat("Dividends received", money: s.dividends, pct: nil, colored: false)
                }
                GridRow {
                    stat("Expected dividends per year", money: s.expectedAnnualDividends, pct: nil, colored: false)
                    stat("Invested", money: s.invested, pct: nil, colored: false)
                }
            }
            if s.missingPrices > 0 {
                Text(verbatim: pfText("No price for %lld holdings yet.", s.missingPrices))
                    .font(Theme.ui(.caption2)).foregroundColor(Theme.gold)
            }
            if s.missingFX {
                Text("Some exchange rates are missing; amounts in other currencies are shown unconverted.")
                    .font(Theme.ui(.caption2)).foregroundColor(Theme.gold)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
    }

    private func stat(_ title: LocalizedStringKey, money: Double, pct: Double?, colored: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.ui(.caption)).foregroundColor(Theme.muted).lineLimit(2)
            Text(verbatim: pfMoney(money, base.rawValue, signed: colored))
                .font(Theme.ui(.subheadline, weight: .semibold))
                .foregroundColor(colored ? Theme.changeColor(money) : Theme.text)
                .minimumScaleFactor(0.7).lineLimit(1)
            if let pct {
                Text(verbatim: pfSignedPercent(pct)).font(Theme.ui(.caption)).foregroundColor(Theme.changeColor(pct))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Позиции

struct PfHoldingsList: View {
    let holdings: [PfHolding]
    let base: PfBase
    var onTap: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Holdings").font(Theme.ui(.headline)).foregroundColor(Theme.text).padding(14)
            if holdings.isEmpty {
                Text("No open positions.").font(Theme.ui(.subheadline)).foregroundColor(Theme.muted)
                    .padding([.horizontal, .bottom], 14)
            }
            ForEach(holdings) { h in
                Divider().overlay(Theme.line)
                Button { onTap(h.ticker) } label: { row(h) }
                    .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
    }

    private func row(_ h: PfHolding) -> some View {
        let code = base.rawValue
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: h.ticker).font(Theme.ui(.subheadline, weight: .semibold)).foregroundColor(Theme.text)
                    if !h.name.isEmpty {
                        Text(verbatim: h.name).font(Theme.ui(.caption)).foregroundColor(Theme.muted).lineLimit(1)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(verbatim: h.value.map { pfMoney($0, code) } ?? "—")
                        .font(Theme.ui(.subheadline, weight: .semibold)).foregroundColor(Theme.text)
                    if let u = h.unrealized, let p = h.unrealizedPct {
                        Text(verbatim: pfMoney(u, code, signed: true) + " · " + pfSignedPercent(p))
                            .font(Theme.ui(.caption)).foregroundColor(Theme.changeColor(u))
                    }
                }
            }
            HStack(spacing: 10) {
                detail("Qty", pfQuantity(h.quantity))
                detail("Avg cost", pfMoney(h.avgCost, h.quoteCurrency))
                detail("Last", h.last.map { pfMoney($0, h.quoteCurrency) } ?? "—")
                detail("Weight", formatPercent(h.weight))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func detail(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
            Text(verbatim: value).font(Theme.ui(.caption)).foregroundColor(Theme.text).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
