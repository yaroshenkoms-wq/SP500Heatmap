import SwiftUI

// MARK: Редактор сделки

struct TransactionEditor: View {
    let portfolio: MyPortfolio
    var existing: MyPortfolio.Transaction?
    var presetTicker: String?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = MyPortfolioStore.shared
    @ObservedObject private var market = PfMarketData.shared
    @EnvironmentObject private var indexStore: IndexStore

    @State private var type: PfTxType = .buy
    @State private var ticker = ""
    @State private var indexId = ""
    @State private var name = ""
    @State private var date = Date()
    @State private var quantityText = ""
    @State private var priceText = ""
    @State private var priceEdited = false
    @State private var prefilling = false
    @State private var autoPrice = ""
    @State private var currency = "USD"
    @State private var feeText = ""
    @State private var showSearch = false
    @State private var confirmDelete = false

    private static let currencies = ["USD", "EUR", "GBP", "CHF", "JPY", "CAD", "AUD", "HKD", "CNY", "SEK", "NOK", "DKK", "PLN", "BRL", "MXN", "INR", "KRW", "SGD", "ZAR", "TRY"]

    private var quantity: Double? { pfParse(quantityText) }
    private var price: Double? { pfParse(priceText) }
    private var fee: Double { pfParse(feeText) ?? 0 }

    /// Сколько акций было на руках на выбранную дату (без этой сделки) — для проверки продажи.
    private var held: Double {
        let others = portfolio.transactions.filter { $0.id != existing?.id }
        return PfCalc.quantity(of: ticker, in: others, upTo: PfDay.string(date))
    }

    private var error: String? {
        if ticker.isEmpty { return AppLanguage.string("Choose a ticker.") }
        guard let q = quantity, q > 0 else { return AppLanguage.string("Enter a quantity above zero.") }
        guard let p = price, p >= 0 else { return AppLanguage.string("Enter a price.") }
        if !feeText.trimmingCharacters(in: .whitespaces).isEmpty, pfParse(feeText) == nil { return AppLanguage.string("Fee must be a number.") }
        if type == .sell, q > held + 1e-9 { return pfText("You only held %@ on that date.", pfQuantity(held)) }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $type) {
                        Text("Buy").tag(PfTxType.buy)
                        Text("Sell").tag(PfTxType.sell)
                        Text("Dividend").tag(PfTxType.dividend)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("txType")
                    Button { showSearch = true } label: {
                        HStack {
                            Text("Ticker").foregroundColor(Theme.text)
                            Spacer()
                            if ticker.isEmpty {
                                Text("Search").foregroundColor(Theme.gold)
                            } else {
                                Text(verbatim: ticker + (name.isEmpty ? "" : " · " + name)).foregroundColor(Theme.gold).lineLimit(1)
                            }
                        }
                    }
                    .accessibilityIdentifier("txTicker")
                    DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date)
                        .environment(\.locale, AppLanguage.locale)
                }
                Section {
                    field("Quantity", $quantityText, id: "txQuantity")
                    field(type == .dividend ? "Dividend per share" : "Price", $priceText, id: "txPrice") { priceEdited = priceText != autoPrice }
                    Picker("Currency", selection: $currency) {
                        ForEach(Self.currencies, id: \.self) { Text(verbatim: $0).tag($0) }
                    }
                    field("Fee", $feeText, id: "txFee")
                } footer: {
                    if let e = error, !quantityText.isEmpty { Text(verbatim: e).foregroundColor(Theme.danger) }
                    else if prefilling { Text("Looking up the price for that date…") }
                    else { Text("The price is filled from the daily close of that date; you can change it.") }
                }
                if existing != nil {
                    Section {
                        Button("Delete transaction", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .themeScreen()
            .navigationTitle(Text(existing == nil ? "Add transaction" : "Edit transaction"))
            .navigationBarTitleDisplayMode(.inline)
            .themeNavBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(error != nil).accessibilityIdentifier("txSave")
                }
            }
            .confirmationDialog("Delete this transaction?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete transaction", role: .destructive) {
                    if let e = existing { store.deleteTransactions([e.id], in: portfolio.id) }
                    dismiss()
                }
            }
            .sheet(isPresented: $showSearch) {
                TickerSearchView { entry in pick(entry) }
            }
        }
        .tint(Theme.gold)
        .onAppear(perform: setup)
        .task(id: prefillKey) { await prefillPrice() }
    }

    private func field(_ title: LocalizedStringKey, _ text: Binding<String>, id: String, onEdit: (() -> Void)? = nil) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                .frame(maxWidth: 160)
                .accessibilityIdentifier(id)
                .onChange(of: text.wrappedValue) { _, _ in onEdit?() }
        }
    }

    private func setup() {
        if let e = existing {
            type = e.type; ticker = e.ticker; indexId = e.indexId; date = e.date
            quantityText = String(e.quantity)
            priceText = String(e.price); priceEdited = true
            currency = e.currency; feeText = e.fee == 0 ? "" : String(e.fee)
            name = market.entry(e.ticker)?.n ?? ""
        } else if let t = presetTicker, let entry = market.entry(t) {
            pick(entry)
        } else if let t = presetTicker {
            ticker = t
            let last = portfolio.transactions.last { $0.ticker == t }
            indexId = last?.indexId ?? ""
            currency = last?.currency ?? "USD"
        }
    }

    private func pick(_ entry: PfCatalogEntry) {
        ticker = entry.t; name = entry.n; indexId = entry.i
        if let c = indexStore.indices.first(where: { $0.id == entry.i })?.currency, Self.currencies.contains(c) { currency = c }
        priceEdited = false
    }

    private var prefillKey: String { ticker + PfDay.string(date) + (priceEdited ? "x" : "o") + type.rawValue }

    private func prefillPrice() async {
        guard !ticker.isEmpty, !priceEdited, type != .dividend else { return }
        prefilling = true
        defer { prefilling = false }
        let day = PfDay.string(date)
        let range = PfMarketData.range(forOldest: day)
        if let close = await market.close(ticker, on: day, range: range), !priceEdited {
            autoPrice = String(format: "%.4f", close)
            priceText = autoPrice
        }
    }

    private func save() {
        guard let q = quantity, let p = price else { return }
        let t = MyPortfolio.Transaction(id: existing?.id ?? UUID(), ticker: ticker.uppercased(), indexId: indexId, type: type,
                                        date: date, quantity: q, price: p, currency: currency, fee: fee)
        store.upsert(t, in: portfolio.id)
        dismiss()
    }
}

// MARK: Поиск тикера

struct TickerSearchView: View {
    var onPick: (PfCatalogEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var market = PfMarketData.shared
    @EnvironmentObject private var indexStore: IndexStore
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                let results = market.search(query)
                if market.catalogLoading && market.catalog.isEmpty {
                    HStack { ProgressView(); Text("Loading companies…").foregroundColor(Theme.muted) }
                        .listRowBackground(Theme.panel)
                }
                ForEach(results) { e in
                    Button {
                        onPick(e); dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(verbatim: e.t).font(Theme.ui(.subheadline, weight: .semibold)).foregroundColor(Theme.text)
                                Text(verbatim: e.n).font(Theme.ui(.caption)).foregroundColor(Theme.muted).lineLimit(1)
                            }
                            Spacer()
                            Text(verbatim: indexStore.indices.first { $0.id == e.i }?.name ?? e.i)
                                .font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
                        }
                    }
                    .listRowBackground(Theme.panel)
                }
                let typed = query.trimmingCharacters(in: .whitespaces).uppercased()
                if !typed.isEmpty, !results.contains(where: { $0.t == typed }) {
                    Button {
                        onPick(PfCatalogEntry(t: typed, n: "", i: "", s: "")); dismiss()
                    } label: {
                        Text(verbatim: pfText("Use \"%@\" as typed", typed)).foregroundColor(Theme.gold)
                    }
                    .listRowBackground(Theme.panel)
                }
            }
            .scrollContentBackground(.hidden)
            .themeScreen()
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Ticker or company name"))
            .textInputAutocapitalization(.never)
            .navigationTitle(Text("Choose a ticker"))
            .navigationBarTitleDisplayMode(.inline)
            .themeNavBar()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .tint(Theme.gold)
        .task { await market.loadCatalog(indices: indexStore.indices) }
    }
}

// MARK: Список сделок

struct PfTransactionsView: View {
    let portfolioId: UUID
    @ObservedObject private var store = MyPortfolioStore.shared
    @State private var editing: MyPortfolio.Transaction?

    private var portfolio: MyPortfolio? { store.portfolios.first { $0.id == portfolioId } }

    var body: some View {
        let txns = (portfolio?.transactions ?? []).sorted { $0.date > $1.date }
        List {
            ForEach(txns) { t in
                Button { editing = t } label: { row(t) }
                    .listRowBackground(Theme.panel)
            }
            .onDelete { offsets in
                store.deleteTransactions(Set(offsets.map { txns[$0].id }), in: portfolioId)
            }
        }
        .scrollContentBackground(.hidden)
        .themeScreen()
        .navigationTitle(Text("Transactions"))
        .navigationBarTitleDisplayMode(.inline)
        .themeNavBar()
        .overlay {
            if txns.isEmpty { Text("No transactions yet").foregroundColor(Theme.muted) }
        }
        .sheet(item: $editing) { t in
            if let p = portfolio { TransactionEditor(portfolio: p, existing: t) }
        }
    }

    private func row(_ t: MyPortfolio.Transaction) -> some View {
        let label: LocalizedStringKey = t.type == .buy ? "Buy" : (t.type == .sell ? "Sell" : "Dividend")
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(label).font(Theme.ui(.caption, weight: .semibold))
                        .foregroundColor(t.type == .sell ? Theme.danger : (t.type == .buy ? Theme.ok : Theme.gold))
                    Text(verbatim: t.ticker).font(Theme.ui(.subheadline, weight: .semibold)).foregroundColor(Theme.text)
                }
                Text(verbatim: t.date.formatted(.dateTime.day().month(.abbreviated).year().locale(AppLanguage.locale)))
                    .font(Theme.ui(.caption)).foregroundColor(Theme.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: pfMoney(t.gross, t.currency)).font(Theme.ui(.subheadline)).foregroundColor(Theme.text)
                Text(verbatim: pfQuantity(t.quantity) + " × " + pfMoney(t.price, t.currency))
                    .font(Theme.ui(.caption)).foregroundColor(Theme.muted)
            }
        }
    }
}
