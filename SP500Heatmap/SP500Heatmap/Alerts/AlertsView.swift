import SwiftUI

/// Слушает хранилище оповещений, чтобы экраны обновлялись сразу.
@MainActor
final class AlertsModel: ObservableObject {
    @Published var items: [StockAlert] = AlertStore.load()
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .stockAlertsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.items = AlertStore.load() }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func reload() { items = AlertStore.load() }
}

private func alertTitle(_ alert: StockAlert) -> String {
    let level = alert.value.map { formatDecimal($0, fractionDigits: $0 >= 100 ? 0 : 2) } ?? ""
    switch alert.kind {
    case .priceAbove: return String(format: AppLanguage.string("Price ≥ %@"), level)
    case .priceBelow: return String(format: AppLanguage.string("Price ≤ %@"), level)
    case .dailyMove: return String(format: AppLanguage.string("Moves ±%@ in a day"), level + "%")
    case .earnings: return AppLanguage.string("Day before earnings")
    case .exDividend: return AppLanguage.string("Day before ex-dividend")
    }
}

private func alertSubtitle(_ alert: StockAlert) -> String? {
    guard alert.isReminder, let fire = alert.fireDate else { return nil }
    return String(format: AppLanguage.string("Reminder on %@"),
                  fire.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(AppLanguage.locale)))
}

/// Все активные оповещения с удалением. Открывается из настроек и со страницы компании.
struct AlertsView: View {
    @StateObject private var model = AlertsModel()

    private var shown: [StockAlert] {
        model.items.sorted { ($0.fireDate ?? $0.createdAt) < ($1.fireDate ?? $1.createdAt) }
    }

    var body: some View {
        List {
            if shown.isEmpty {
                Text("No active alerts.")
                    .font(Theme.ui(.subheadline))
                    .foregroundColor(Theme.muted)
                    .listRowBackground(Theme.panel)
            } else {
                Section {
                    ForEach(shown) { alert in
                        HStack(spacing: 10) {
                            Image(systemName: alert.isReminder ? "calendar.badge.clock" : "bell.badge")
                                .foregroundColor(Theme.gold)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: "\(alert.ticker) · \(alertTitle(alert))")
                                    .font(Theme.ui(.subheadline, weight: .medium))
                                    .foregroundColor(Theme.text)
                                Text(verbatim: alertSubtitle(alert) ?? alert.name)
                                    .font(Theme.ui(.caption)).foregroundColor(Theme.muted)
                            }
                            Spacer()
                            Button(role: .destructive) { AlertStore.remove(id: alert.id) } label: {
                                Image(systemName: "trash").foregroundColor(Theme.danger)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Delete"))
                        }
                        .listRowBackground(Theme.panel)
                    }
                    .onDelete { offsets in
                        for i in offsets { AlertStore.remove(id: shown[i].id) }
                    }
                } footer: {
                    Text("Price alerts are checked in the background. iOS decides when that runs, so they may be delayed or skipped. Earnings and dividend reminders are exact.")
                        .font(Theme.ui(.caption))
                        .foregroundColor(Theme.muted)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .themeScreen()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Alerts").font(Theme.serif(.title3)).foregroundColor(Theme.text)
            }
        }
        .themeNavBar()
        .onAppear { model.reload() }
    }
}

/// Форма «Уведомить, когда цена…».
struct AddPriceAlertSheet: View {
    let company: Company
    let indexId: String
    let currentPrice: Double
    @Environment(\.dismiss) private var dismiss
    @State private var kind: StockAlert.Kind = .priceAbove
    @State private var text = ""
    @State private var showDenied = false

    private var value: Double? {
        let f = NumberFormatter()
        f.locale = AppLanguage.locale
        f.numberStyle = .decimal
        if let n = f.number(from: text)?.doubleValue { return n }
        return Double(text.replacingOccurrences(of: ",", with: "."))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Condition", selection: $kind) {
                        Text("Price at or above").tag(StockAlert.Kind.priceAbove)
                        Text("Price at or below").tag(StockAlert.Kind.priceBelow)
                        Text("Moves ± % in a day").tag(StockAlert.Kind.dailyMove)
                    }
                    .listRowBackground(Theme.panel)
                    HStack {
                        TextField(kind == .dailyMove ? "Percent" : "Price", text: $text)
                            .keyboardType(.decimalPad)
                        if kind == .dailyMove { Text(verbatim: "%").foregroundColor(Theme.muted) }
                    }
                    .listRowBackground(Theme.panel)
                } footer: {
                    Text("Checked in the background. iOS decides when that runs, so the alert may be delayed or skipped.")
                        .font(Theme.ui(.caption)).foregroundColor(Theme.muted)
                }
            }
            .scrollContentBackground(.hidden)
            .themeScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(verbatim: company.ticker).font(Theme.serif(.title3)).foregroundColor(Theme.text)
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled((value ?? 0) <= 0)
                }
            }
            .themeNavBar()
            .onAppear {
                if text.isEmpty, currentPrice > 0 { text = formatDecimal(currentPrice) }
            }
            .onChange(of: kind) { _, new in
                text = new == .dailyMove ? formatDecimal(5, fractionDigits: 0) : (currentPrice > 0 ? formatDecimal(currentPrice) : "")
            }
            .alert("Notifications are off", isPresented: $showDenied) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Allow notifications for this app in iOS Settings to get alerts.")
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard let v = value, v > 0 else { return }
        Task {
            guard await AlertManager.requestPermission() else { showDenied = true; return }
            AlertStore.add(StockAlert(id: UUID().uuidString, kind: kind, ticker: company.ticker, name: company.name,
                                      indexId: indexId, value: v, eventDay: nil, fireDate: nil,
                                      lastFiredDay: nil, createdAt: Date()))
            dismiss()
        }
    }
}

/// Блок «Оповещения» на странице компании.
struct CompanyAlertsSection: View {
    let company: Company
    let indexId: String
    let currentPrice: Double
    let info: CompanyInfo?
    @StateObject private var model = AlertsModel()
    @State private var showAdd = false
    @State private var showAll = false
    @State private var showDenied = false
    @State private var noticeKey: String?

    private var mine: [StockAlert] { model.items.filter { $0.ticker == company.ticker } }

    private func reminderBinding(_ kind: StockAlert.Kind, day: String?) -> Binding<Bool> {
        Binding(
            get: { mine.contains { $0.kind == kind } },
            set: { on in
                if !on {
                    if let existing = mine.first(where: { $0.kind == kind }) { AlertStore.remove(id: existing.id) }
                    return
                }
                guard let day, let fire = ReminderScheduler.fireDate(forEventDay: day) else {
                    noticeKey = "That date is too close or already passed."
                    return
                }
                Task {
                    guard await AlertManager.requestPermission() else { showDenied = true; return }
                    AlertStore.add(StockAlert(id: UUID().uuidString, kind: kind, ticker: company.ticker, name: company.name,
                                              indexId: indexId, value: nil, eventDay: String(day.prefix(10)),
                                              fireDate: fire, lastFiredDay: nil, createdAt: Date()))
                    noticeKey = nil
                }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Alerts")
                .font(Theme.serif(.title3))
                .foregroundColor(Theme.text)
            VStack(spacing: 0) {
                row {
                    Button { showAdd = true } label: {
                        HStack {
                            Image(systemName: "bell.badge").foregroundColor(Theme.gold)
                            Text("Notify me about the price")
                                .font(Theme.ui(.subheadline)).foregroundColor(Theme.text)
                            Spacer()
                            Image(systemName: "plus").foregroundColor(Theme.gold)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Divider().overlay(Theme.line)
                row {
                    Toggle(isOn: reminderBinding(.earnings, day: info?.earningsDate)) {
                        Text("Remind me the day before earnings")
                            .font(Theme.ui(.subheadline)).foregroundColor(Theme.text)
                    }
                    .tint(Theme.gold)
                    .disabled(info?.earningsDate == nil)
                }
                Divider().overlay(Theme.line)
                row {
                    Toggle(isOn: reminderBinding(.exDividend, day: info?.exDividendDate)) {
                        Text("Remind me the day before ex-dividend")
                            .font(Theme.ui(.subheadline)).foregroundColor(Theme.text)
                    }
                    .tint(Theme.gold)
                    .disabled(info?.exDividendDate == nil)
                }
                Divider().overlay(Theme.line)
                row {
                    Button { showAll = true } label: {
                        HStack {
                            Text("All alerts")
                                .font(Theme.ui(.subheadline)).foregroundColor(Theme.text)
                            if !model.items.isEmpty {
                                Text(verbatim: "\(model.items.count)")
                                    .font(Theme.ui(.caption)).foregroundColor(Theme.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote).foregroundColor(Theme.muted)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .panelCard()
            if let noticeKey {
                Text(LocalizedStringKey(noticeKey)).font(Theme.ui(.caption)).foregroundColor(Theme.muted)
            }
            Text("Price alerts are checked in the background; iOS decides when, so they may be delayed or skipped.")
                .font(Theme.ui(.caption2))
                .foregroundColor(Theme.muted)
        }
        .padding(.horizontal)
        .sheet(isPresented: $showAdd) {
            AddPriceAlertSheet(company: company, indexId: indexId, currentPrice: currentPrice)
        }
        .sheet(isPresented: $showAll) {
            NavigationStack { AlertsView() }
        }
        .alert("Notifications are off", isPresented: $showDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow notifications for this app in iOS Settings to get alerts.")
        }
        .task(id: info?.earningsDate) {
            await ReminderScheduler.sync(ticker: company.ticker, kind: .earnings, eventDay: info?.earningsDate)
        }
        .task(id: info?.exDividendDate) {
            await ReminderScheduler.sync(ticker: company.ticker, kind: .exDividend, eventDay: info?.exDividendDate)
        }
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(.vertical, 10)
    }
}
