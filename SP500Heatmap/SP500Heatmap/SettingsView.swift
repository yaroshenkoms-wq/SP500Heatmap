import SwiftUI

/// Экран настроек: карта, язык, уведомления, о приложении.
struct SettingsView: View {
    let indices: [WorldIndex]
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage(AppLanguage.storageKey) private var language = ""
    @AppStorage(AlertManager.moveKey) private var moveEnabled = false
    @AppStorage(AlertManager.summaryKey) private var summaryEnabled = false
    @AppStorage(AlertManager.thresholdKey) private var threshold = AlertManager.defaultThreshold
    @ObservedObject private var metricStore = MetricStore.shared
    @State private var showDenied = false
    @Environment(\.dismiss) private var dismiss

    private var currentLanguage: Binding<String> {
        Binding(get: { AppLanguage.codes.contains(language) ? language : AppLanguage.systemDefault },
                set: { language = $0 })
    }

    /// Объём и оборот предлагаем, только если сервер их прислал.
    private var sizeOptions: [SizeMode] {
        SizeMode.allCases.filter { mode in
            switch mode {
            case .volume: return metricStore.anyVolumeData || settings.sizeMode == mode
            case .turnover: return metricStore.anyTurnoverData || settings.sizeMode == mode
            default: return true
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                mapSection
                languageSection
                notificationsSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .themeScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Settings")
                        .font(Theme.serif(.title3))
                        .foregroundColor(Theme.text)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(Theme.ui(.body, weight: .medium))
                }
            }
            .themeNavBar()
            .task { await metricStore.load(index: "sp500") }
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

    // MARK: Секции

    private var mapSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tile size")
                    .font(Theme.ui(.subheadline))
                    .foregroundColor(Theme.text)
                Picker("Tile size", selection: $settings.sizeMode) {
                    ForEach(sizeOptions) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Text("Volume and turnover apply to company maps; world and sector maps use market cap where there is no data.")
                    .font(Theme.ui(.caption))
                    .foregroundColor(Theme.muted)
            }
            .listRowBackground(Theme.panel)
            ForEach(ColorPalette.allCases, id: \.self) { palette in
                Button { settings.palette = palette } label: {
                    HStack {
                        Text(LocalizedStringKey(palette == .redGreen ? "Red–Green" : "Colour-blind: Blue–Orange"))
                            .font(Theme.ui(.subheadline))
                            .foregroundColor(Theme.text)
                        Spacer()
                        HStack(spacing: 2) {
                            swatch(SharedHeat.color(for: SharedHeat.cap, palette: palette))
                            swatch(SharedHeat.color(for: nil, palette: palette))
                            swatch(SharedHeat.color(for: -SharedHeat.cap, palette: palette))
                        }
                        Image(systemName: settings.palette == palette ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(settings.palette == palette ? Theme.gold : Theme.muted)
                    }
                }
                .listRowBackground(Theme.panel)
            }
        } header: {
            sectionTitle("Map")
        }
    }

    private func swatch(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 18, height: 18)
    }

    private var languageSection: some View {
        Section {
            Picker(selection: currentLanguage) {
                ForEach(AppLanguage.codes, id: \.self) { code in
                    Text(verbatim: "\(AppLanguage.shortCode(code))  \(AppLanguage.nativeName(code))").tag(code)
                }
            } label: {
                Text("Language")
                    .font(Theme.ui(.subheadline))
                    .foregroundColor(Theme.text)
            }
            .listRowBackground(Theme.panel)
        } header: {
            sectionTitle("Language")
        }
    }

    private var notificationsSection: some View {
        Section {
            Toggle(isOn: gatedToggle($moveEnabled)) {
                Text("Index moved more than the threshold")
                    .font(Theme.ui(.subheadline))
                    .foregroundColor(Theme.text)
            }
            .tint(Theme.gold)
            .listRowBackground(Theme.panel)
            if moveEnabled {
                Picker("Threshold", selection: $threshold) {
                    ForEach([1.0, 2.0, 3.0, 5.0], id: \.self) { value in
                        Text(verbatim: formatDecimal(value, fractionDigits: 0) + "%").tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Theme.panel)
                NavigationLink {
                    AlertIndicesList(indices: indices)
                } label: {
                    Text("Indices to watch")
                        .font(Theme.ui(.subheadline))
                        .foregroundColor(Theme.text)
                }
                .listRowBackground(Theme.panel)
            }
            Toggle(isOn: gatedToggle($summaryEnabled)) {
                Text("Daily summary after the US close")
                    .font(Theme.ui(.subheadline))
                    .foregroundColor(Theme.text)
            }
            .tint(Theme.gold)
            .listRowBackground(Theme.panel)
        } header: {
            sectionTitle("Notifications")
        } footer: {
            Text("Alerts are checked in the background. iOS decides when that runs, so alerts may be delayed or skipped, especially if the app has not been opened for a while.")
                .font(Theme.ui(.caption))
                .foregroundColor(Theme.muted)
        }
    }

    private var aboutSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Data sources")
                    .font(Theme.ui(.subheadline, weight: .medium))
                    .foregroundColor(Theme.text)
                Text(verbatim: "Yahoo Finance · Finnhub · CoinGecko")
                    .font(Theme.ui(.footnote))
                    .foregroundColor(Theme.gold)
                Text("Data: CoinGecko")
                    .font(Theme.ui(.caption))
                    .foregroundColor(Theme.muted)
                Text("Prices may be delayed. This app is for information only and is not investment advice.")
                    .font(Theme.ui(.caption))
                    .foregroundColor(Theme.muted)
            }
            .listRowBackground(Theme.panel)
            HStack {
                Text("Version")
                    .font(Theme.ui(.subheadline))
                    .foregroundColor(Theme.text)
                Spacer()
                Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    .font(Theme.ui(.subheadline))
                    .foregroundColor(Theme.muted)
            }
            .listRowBackground(Theme.panel)
        } header: {
            sectionTitle("About")
        }
    }

    private func sectionTitle(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(Theme.ui(.caption, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundColor(Theme.muted)
    }

    /// Переключатель, который при включении сначала просит разрешение на уведомления.
    private func gatedToggle(_ flag: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { flag.wrappedValue },
            set: { newValue in
                guard newValue else {
                    flag.wrappedValue = false
                    AlertManager.scheduleRefresh()
                    return
                }
                Task {
                    if await AlertManager.requestPermission() {
                        flag.wrappedValue = true
                        AlertManager.scheduleRefresh()
                    } else {
                        showDenied = true
                    }
                }
            })
    }
}

/// Какие индексы отслеживать (по умолчанию S&P 500, IBEX 35, Euro Stoxx 50).
private struct AlertIndicesList: View {
    let indices: [WorldIndex]
    @AppStorage(AlertManager.indicesKey) private var csv = AlertManager.defaultIndices.joined(separator: ",")

    private var selected: Set<String> { Set(csv.split(separator: ",").map(String.init)) }

    var body: some View {
        List(indices) { index in
            Button {
                var set = selected
                if set.contains(index.id) { set.remove(index.id) } else { set.insert(index.id) }
                csv = set.sorted().joined(separator: ",")
            } label: {
                HStack {
                    Text(verbatim: "\(index.flag) \(index.name)")
                        .font(Theme.ui(.subheadline))
                        .foregroundColor(Theme.text)
                    Spacer()
                    Image(systemName: selected.contains(index.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(selected.contains(index.id) ? Theme.gold : Theme.muted)
                }
            }
            .listRowBackground(Theme.panel)
        }
        .scrollContentBackground(.hidden)
        .themeScreen()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Indices to watch")
                    .font(Theme.serif(.title3))
                    .foregroundColor(Theme.text)
            }
        }
        .themeNavBar()
    }
}
