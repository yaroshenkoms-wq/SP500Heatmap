import SwiftUI
import EventKit

/// Month strip + day list of earnings / ex-dividend / dividend-pay events from /api/v1/calendar.
struct CalendarView: View {
    private enum Filter: String { case all, watchlists, index }

    @EnvironmentObject private var indexStore: IndexStore
    @ObservedObject private var favorites = FavoritesStore.shared
    @State private var month = CalendarView.startOfMonth(Date())
    @State private var selected = Calendar.current.startOfDay(for: Date())
    @State private var filter: Filter = .all
    @State private var events: [CalendarEvent] = []
    @State private var loading = false
    @State private var failed = false
    @State private var open: CompanyRef?
    @State private var toast: LocalizedStringKey?
    private let store = EKEventStore()

    private static let cal = Calendar.current

    static func startOfMonth(_ d: Date) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
    }

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static func key(_ d: Date) -> String { keyFormatter.string(from: d) }

    private var days: [Date] {
        let range = Self.cal.range(of: .day, in: .month, for: month) ?? 1..<31
        return range.compactMap { Self.cal.date(byAdding: .day, value: $0 - 1, to: month) }
    }

    private var eventsByDay: [String: [CalendarEvent]] {
        Dictionary(grouping: events, by: \.date)
    }

    private var dayEvents: [CalendarEvent] {
        (eventsByDay[Self.key(selected)] ?? []).sorted {
            ($0.type, $0.ticker) < ($1.type, $1.ticker)
        }
    }

    private var monthTitle: String {
        month.formatted(.dateTime.month(.wide).year().locale(AppLanguage.locale))
    }

    private func filterTitle(_ f: Filter) -> LocalizedStringKey {
        switch f {
        case .all: return "All"
        case .watchlists: return "Watchlists"
        case .index: return "Current index"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            strip
            filterChips
            list
        }
        .themeScreen()
        .navigationTitle(Text("Calendar"))
        .navigationBarTitleDisplayMode(.inline)
        .themeNavBar()
        .companyDestination($open)
        .task(id: "\(Self.key(month))|\(filter.rawValue)|\(favorites.allItems.count)|\(indexStore.selectedId)") {
            await load()
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(Theme.ui(.subheadline, weight: .medium))
                    .foregroundColor(Theme.text)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.chip, in: Capsule())
                    .overlay(Capsule().stroke(Theme.goldLine, lineWidth: 1))
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: toast == nil)
    }

    private var header: some View {
        HStack {
            Button { shift(-1) } label: {
                Image(systemName: "chevron.left").frame(width: 34, height: 34).outlinedControl()
            }
            Spacer()
            Text(verbatim: monthTitle)
                .font(Theme.serif(.title2)).foregroundColor(Theme.text)
            Spacer()
            Button { shift(1) } label: {
                Image(systemName: "chevron.right").frame(width: 34, height: 34).outlinedControl()
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func shift(_ delta: Int) {
        guard let m = Self.cal.date(byAdding: .month, value: delta, to: month) else { return }
        month = m
        let today = Self.cal.startOfDay(for: Date())
        selected = Self.cal.isDate(today, equalTo: m, toGranularity: .month) ? today : m
    }

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(days, id: \.self) { d in
                        let isSel = Self.cal.isDate(d, inSameDayAs: selected)
                        let count = eventsByDay[Self.key(d)]?.count ?? 0
                        Button { selected = d } label: {
                            VStack(spacing: 3) {
                                Text(verbatim: d.formatted(.dateTime.weekday(.narrow).locale(AppLanguage.locale)))
                                    .font(Theme.ui(.caption2)).foregroundColor(isSel ? Theme.gold : Theme.muted)
                                Text(verbatim: d.formatted(.dateTime.day().locale(AppLanguage.locale)))
                                    .font(Theme.ui(.body, weight: .semibold)).foregroundColor(isSel ? Theme.gold : Theme.text)
                                Circle().fill(count > 0 ? Theme.gold : Color.clear).frame(width: 5, height: 5)
                            }
                            .frame(width: 42, height: 62)
                            .background(Theme.chip, in: RoundedRectangle(cornerRadius: Theme.radius))
                            .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                                .strokeBorder(isSel ? Theme.goldLine : Theme.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .id(d)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
            .environment(\.layoutDirection, .leftToRight)
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
            .onChange(of: month) { _, _ in proxy.scrollTo(selected, anchor: .center) }
        }
    }

    private var filterChips: some View {
        HStack(spacing: 8) {
            ForEach([Filter.all, .watchlists, .index], id: \.rawValue) { f in
                Button { filter = f } label: { Text(filterTitle(f)).themeChip(selected: filter == f) }
                    .buttonStyle(.plain)
            }
            if filter == .index {
                Text(verbatim: indexStore.current.name).font(Theme.ui(.caption)).foregroundColor(Theme.muted)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var list: some View {
        if loading && events.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if failed {
            message("Couldn't load data.")
        } else if filter == .watchlists && favorites.allItems.isEmpty {
            message("Your watchlists are empty.")
        } else if dayEvents.isEmpty {
            message("No events on this day.")
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(dayEvents) { e in row(e) }
                    Text("Dates come from company reports and may change.")
                        .font(Theme.ui(.caption2)).foregroundColor(Theme.muted).padding(.top, 6)
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
        }
    }

    private func message(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(Theme.ui(.subheadline)).foregroundColor(Theme.muted)
            .multilineTextAlignment(.center)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func typeInfo(_ type: String) -> (icon: String, title: LocalizedStringKey) {
        switch type {
        case "earnings": return ("doc.text.magnifyingglass", "Earnings")
        case "exDividend": return ("scissors", "Ex-dividend")
        default: return ("banknote", "Dividend payment")
        }
    }

    private func row(_ e: CalendarEvent) -> some View {
        let info = typeInfo(e.type)
        return HStack(spacing: 10) {
            Button {
                let ref = CompanyRef(ticker: e.ticker, name: e.name ?? e.ticker, index: e.index)
                prepareCompany(ref, store: indexStore)
                open = ref
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: info.icon).foregroundColor(Theme.gold).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: e.ticker).font(Theme.ui(.subheadline, weight: .semibold)).foregroundColor(Theme.text)
                        Text(verbatim: e.name ?? "").font(Theme.ui(.caption)).foregroundColor(Theme.muted).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(info.title).font(Theme.ui(.caption)).foregroundColor(Theme.gold)
                            if let eps = e.detail?.epsEstimate {
                                Text("EPS est.").font(Theme.ui(.caption)).foregroundColor(Theme.muted)
                                Text(verbatim: formatDecimal(eps)).font(Theme.ui(.caption)).foregroundColor(Theme.text)
                            }
                            if let div = e.detail?.dividendRate {
                                Text("Dividend per share").font(Theme.ui(.caption)).foregroundColor(Theme.muted)
                                Text(verbatim: formatDecimal(div)).font(Theme.ui(.caption)).foregroundColor(Theme.text)
                            }
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { Task { await addToCalendar(e) } } label: {
                Image(systemName: "calendar.badge.plus")
                    .frame(width: 34, height: 34).outlinedControl()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Add to Calendar"))
        }
        .padding(10)
        .panelCard()
    }

    private func load() async {
        loading = true
        failed = false
        defer { loading = false }
        let from = Self.key(month)
        let last = Self.cal.date(byAdding: DateComponents(month: 1, day: -1), to: month) ?? month
        let tickers = filter == .watchlists ? Array(Set(favorites.allItems.map(\.ticker))).sorted() : []
        if filter == .watchlists && tickers.isEmpty { events = []; return }
        let index = filter == .index ? indexStore.selectedId : "all"
        do {
            let result = try await NetworkService.shared.fetchCalendar(from: from, to: Self.key(last), index: index, tickers: tickers)
            events = result
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled { events = []; failed = true }
        }
    }

    private func addToCalendar(_ e: CalendarEvent) async {
        do {
            let granted = try await store.requestWriteOnlyAccessToEvents()
            guard granted, let day = Self.keyFormatter.date(from: e.date) else { show("Calendar access is off."); return }
            let ev = EKEvent(eventStore: store)
            ev.title = "\(e.ticker) · \(AppLanguage.string(e.type == "earnings" ? "Earnings" : e.type == "exDividend" ? "Ex-dividend" : "Dividend payment"))"
            ev.startDate = day
            ev.endDate = day
            ev.isAllDay = true
            ev.notes = e.name
            ev.calendar = store.defaultCalendarForNewEvents
            try store.save(ev, span: .thisEvent)
            show("Added to Calendar")
        } catch {
            show("Calendar access is off.")
        }
    }

    private func show(_ key: LocalizedStringKey) {
        toast = key
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            toast = nil
        }
    }
}
