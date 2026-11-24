import SwiftUI

struct ScreenerView: View {
    @EnvironmentObject private var indexStore: IndexStore
    @ObservedObject private var saved = SavedScreensStore.shared
    @State private var filters = ScreenerFilters()
    @State private var rows: [ScreenerRow] = []
    @State private var total = 0
    @State private var loading = false
    @State private var failed = false
    @State private var showFilters = false
    @State private var showSave = false
    @State private var saveName = ""
    @State private var open: CompanyRef?
    @AppStorage("scrMap") private var showMap = false
    @AppStorage("scrCols") private var colsCSV = "pe,divYield"
    @Environment(\.horizontalSizeClass) private var sizeClass

    private static let allColumns = ["pe", "ps", "pb", "divYield", "beta", "revGrowth", "pos52w", "relVolume"]

    private var columns: [String] {
        let chosen = Set(colsCSV.split(separator: ",").map(String.init))
        return Self.allColumns.filter { chosen.contains($0) }.prefix(sizeClass == .regular ? 5 : 2).map { $0 }
    }

    static func columnTitle(_ f: String) -> LocalizedStringKey {
        switch f {
        case "pe": return "P/E"
        case "ps": return "P/S"
        case "pb": return "P/B"
        case "divYield": return "Dividend yield"
        case "beta": return "Beta"
        case "revGrowth": return "Revenue growth"
        case "pos52w": return "52-week position"
        case "relVolume": return "Relative volume"
        case "change": return "Change"
        case "capUSD": return "Market Cap"
        default: return "Ticker"
        }
    }

    private static func presetTitle(_ p: String) -> LocalizedStringKey {
        switch p {
        case "gainers": return "Top gainers"
        case "losers": return "Top losers"
        case "active": return "Most active"
        case "dividend": return "High dividend"
        case "value": return "Value"
        case "highs52": return "52-week highs"
        default: return "52-week lows"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            presetRow
            controls
            content
            Text("For information only. Not investment advice.")
                .font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .themeScreen()
        .navigationTitle(Text("Screener"))
        .navigationBarTitleDisplayMode(.inline)
        .themeNavBar()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { savedMenu }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showFilters = true } label: {
                    Image(systemName: filters.activeCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel(Text("Filters"))
            }
        }
        .sheet(isPresented: $showFilters) {
            ScreenerFilterSheet(filters: $filters)
                .environmentObject(indexStore)
                .presentationDetents([.large])
        }
        .alert("Save screen", isPresented: $showSave) {
            TextField("Name", text: $saveName)
            Button("Save") {
                let n = saveName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { saved.save(name: n, filters: filters) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .companyDestination($open)
        .task(id: filters) { await load() }
    }

    // MARK: Parts

    private var presetRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ScreenerFilters.presets, id: \.self) { p in
                    Button {
                        if filters.preset == p {
                            filters.preset = nil
                        } else {
                            filters.preset = p
                            let s = ScreenerFilters.defaultSort(for: p)
                            filters.sort = s.0; filters.ascending = s.1
                        }
                    } label: { Text(Self.presetTitle(p)).themeChip(selected: filters.preset == p) }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal).padding(.vertical, 8)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Menu {
                Picker(selection: $filters.sort) {
                    ForEach(ScreenerFilters.sortFields, id: \.self) { f in Text(Self.columnTitle(f)).tag(f) }
                } label: { Text("Sort") }
                Toggle("Ascending", isOn: $filters.ascending)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: filters.ascending ? "arrow.up" : "arrow.down")
                    Text(Self.columnTitle(filters.sort))
                }
                .font(Theme.ui(.caption, weight: .medium))
                .padding(.horizontal, 10).frame(height: 30).outlinedControl(gold: false)
            }
            Menu {
                ForEach(Self.allColumns, id: \.self) { f in
                    Button {
                        var set = Set(colsCSV.split(separator: ",").map(String.init))
                        if set.contains(f) { set.remove(f) } else { set.insert(f) }
                        colsCSV = Self.allColumns.filter { set.contains($0) }.joined(separator: ",")
                    } label: {
                        Label { Text(Self.columnTitle(f)) } icon: {
                            if colsCSV.split(separator: ",").contains(Substring(f)) { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                Label { Text("Columns") } icon: { Image(systemName: "tablecells") }
                    .font(Theme.ui(.caption, weight: .medium))
                    .padding(.horizontal, 10).frame(height: 30).outlinedControl(gold: false)
            }
            Spacer()
            if total > 0 {
                Text(verbatim: "\(rows.count)/\(total)").font(Theme.ui(.caption)).foregroundColor(Theme.muted)
            }
            Button { showMap.toggle() } label: {
                Label { Text("Show as map") } icon: { Image(systemName: showMap ? "list.bullet" : "square.grid.3x3.fill") }
                    .labelStyle(.iconOnly)
                    .frame(width: 34, height: 30).outlinedControl(gold: showMap)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Show as map"))
        }
        .padding(.horizontal).padding(.bottom, 8)
    }

    @ViewBuilder private var content: some View {
        if loading && rows.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if failed {
            VStack(spacing: 8) {
                Text("Couldn't load data.").font(Theme.ui(.subheadline)).foregroundColor(Theme.muted)
                Button("Retry") { Task { await load() } }.buttonStyle(OutlinedButtonStyle())
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            Text("No stocks match these filters.")
                .font(Theme.ui(.subheadline)).foregroundColor(Theme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if showMap {
            mapView
        } else {
            list
        }
    }

    private var list: some View {
        List {
            ForEach(rows) { row in
                Button { openRow(row) } label: { rowView(row) }
                    .buttonStyle(.plain)
                    .listRowBackground(Theme.bg)
                    .listRowSeparatorTint(Theme.line)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .opacity(loading ? 0.5 : 1)
    }

    private func flag(_ row: ScreenerRow) -> String {
        indexStore.indices.first { $0.id == row.index }?.flag ?? ""
    }

    private func rowView(_ r: ScreenerRow) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(verbatim: r.ticker).font(Theme.ui(.subheadline, weight: .semibold)).foregroundColor(Theme.text)
                    Text(verbatim: flag(r)).font(.caption)
                }
                Text(verbatim: r.name ?? "").font(Theme.ui(.caption)).foregroundColor(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            ForEach(columns, id: \.self) { f in
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Self.columnTitle(f)).font(Theme.ui(.caption2)).foregroundColor(Theme.muted).lineLimit(1).minimumScaleFactor(0.6)
                    Text(verbatim: Self.value(r, f)).font(Theme.ui(.footnote, weight: .medium)).foregroundColor(Theme.text)
                }
                .frame(minWidth: 52, alignment: .trailing)
            }
            Text(verbatim: r.change.map { formatPercent($0) } ?? "—")
                .font(Theme.ui(.footnote, weight: .semibold))
                .foregroundColor(Theme.changeColor(r.change ?? 0))
                .frame(minWidth: 62, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    static func value(_ r: ScreenerRow, _ f: String) -> String {
        func d(_ v: Double?, _ digits: Int = 1) -> String { v.map { formatDecimal($0, fractionDigits: digits) } ?? "—" }
        func p(_ v: Double?) -> String { v.map { formatDecimal($0, fractionDigits: 1) + "%" } ?? "—" }
        switch f {
        case "pe": return d(r.pe)
        case "ps": return d(r.ps)
        case "pb": return d(r.pb)
        case "divYield": return p(r.divYield)
        case "beta": return d(r.beta, 2)
        case "revGrowth": return p(r.revGrowth)
        case "pos52w": return p(r.pos52w.map { $0 * 100 })  // сервер: 0…1
        case "relVolume": return d(r.relVolume, 2) + (r.relVolume == nil ? "" : "x")
        default: return "—"
        }
    }

    private var mapView: some View {
        let items = rows
        return TreemapLayout(weights: items.map { max($0.capUSD ?? 0, 1) }) {
            ForEach(items) { r in
                Button { openRow(r) } label: {
                    TileContainer {
                        VStack(spacing: 2) {
                            Text(verbatim: r.ticker).font(Theme.ui(.subheadline, weight: .semibold))
                                .foregroundColor(HeatmapColor.tileText).lineLimit(1).minimumScaleFactor(0.5)
                            if let c = r.change {
                                Text(formatPercent(c)).font(Theme.ui(.caption))
                                    .foregroundColor(HeatmapColor.tileText.opacity(0.9)).lineLimit(1).minimumScaleFactor(0.6)
                            }
                        }
                    }
                    .background(HeatmapColor.color(for: r.change, period: filters.period))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
        .opacity(loading ? 0.5 : 1)
    }

    private var savedMenu: some View {
        Menu {
            Button { saveName = ""; showSave = true } label: { Label { Text("Save screen") } icon: { Image(systemName: "bookmark") } }
            if !saved.screens.isEmpty {
                Section("Saved screens") {
                    ForEach(saved.screens) { s in
                        Button { filters = s.filters } label: { Text(verbatim: s.name) }
                    }
                }
                Menu {
                    ForEach(saved.screens) { s in
                        Button(role: .destructive) { saved.delete(s.id) } label: { Text(verbatim: s.name) }
                    }
                } label: { Label { Text("Delete saved screen") } icon: { Image(systemName: "trash") } }
            }
            if filters != ScreenerFilters() {
                Button(role: .destructive) { filters = ScreenerFilters() } label: { Label { Text("Reset") } icon: { Image(systemName: "arrow.counterclockwise") } }
            }
        } label: { Image(systemName: "bookmark") }
        .accessibilityLabel(Text("Saved screens"))
    }

    private func openRow(_ r: ScreenerRow) {
        let ref = CompanyRef(ticker: r.ticker, name: r.name ?? r.ticker, index: r.index)
        prepareCompany(ref, store: indexStore)
        open = ref
    }

    private func load() async {
        loading = true
        failed = false
        defer { loading = false }
        do {
            let result = try await NetworkService.shared.fetchScreener(filters.query())
            rows = result.rows
            total = result.total
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled { rows = []; total = 0; failed = true }
        }
    }
}

// MARK: Filter sheet

struct ScreenerFilterSheet: View {
    @Binding var filters: ScreenerFilters
    @EnvironmentObject private var indexStore: IndexStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Universe") {
                    Picker("Index", selection: $filters.index) {
                        Text("All indices").tag("all")
                        ForEach(indexStore.indices) { i in Text(verbatim: "\(i.flag) \(i.name)").tag(i.id) }
                    }
                    Picker("Sector", selection: $filters.sector) {
                        Text("Any").tag("")
                        ForEach(ScreenerFilters.sectors, id: \.self) { s in Text(verbatim: localizedSectorName(s)).tag(s) }
                    }
                    Picker("Market Cap", selection: $filters.cap) {
                        Text("Any").tag("any")
                        Text("Mega (over $200B)").tag("mega")
                        Text("Large ($10B–$200B)").tag("large")
                        Text("Mid ($2B–$10B)").tag("mid")
                        Text("Small (under $2B)").tag("small")
                    }
                }
                .listRowBackground(Theme.panel)
                Section("Valuation") {
                    NumField(title: "P/E min", value: $filters.peMin)
                    NumField(title: "P/E max", value: $filters.peMax)
                    NumField(title: "P/S max", value: $filters.psMax)
                    NumField(title: "P/B max", value: $filters.pbMax)
                }
                .listRowBackground(Theme.panel)
                Section("Fundamentals") {
                    NumField(title: "Dividend yield min, %", value: $filters.divMin)
                    NumField(title: "Beta max", value: $filters.betaMax)
                    NumField(title: "Revenue growth min, %", value: $filters.revGrowthMin)
                }
                .listRowBackground(Theme.panel)
                Section("Price") {
                    Picker("Period", selection: $filters.period) {
                        ForEach(ScreenerFilters.periods, id: \.self) { Text(verbatim: $0.uppercased()).tag($0) }
                    }
                    NumField(title: "Change min, %", value: $filters.chgMin)
                    NumField(title: "Change max, %", value: $filters.chgMax)
                    NumField(title: "52-week position min, %", value: $filters.pos52Min)
                    NumField(title: "52-week position max, %", value: $filters.pos52Max)
                    NumField(title: "Relative volume min", value: $filters.relVolMin)
                }
                .listRowBackground(Theme.panel)
                Section {
                    Button("Reset", role: .destructive) {
                        let preset = filters.preset
                        filters = ScreenerFilters()
                        filters.preset = preset
                    }
                }
                .listRowBackground(Theme.panel)
            }
            .scrollContentBackground(.hidden)
            .themeScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Filters").font(Theme.serif(.title3)).foregroundColor(Theme.text)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .themeNavBar()
        }
    }
}

/// Optional decimal field that edits a `Double?`.
private struct NumField: View {
    let title: LocalizedStringKey
    @Binding var value: Double?
    @State private var text = ""

    var body: some View {
        HStack {
            Text(title).font(Theme.ui(.subheadline)).foregroundColor(Theme.text)
            Spacer()
            TextField("Any", text: $text)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110)
                .foregroundColor(Theme.gold)
                .onChange(of: text) { _, new in
                    let t = new.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
                    value = t.isEmpty ? nil : Double(t)
                }
        }
        .onAppear { text = value.map { String($0) } ?? "" }
        .onChange(of: value) { _, new in
            if new == nil && Double(text.replacingOccurrences(of: ",", with: ".")) != nil { text = "" }
        }
    }
}
