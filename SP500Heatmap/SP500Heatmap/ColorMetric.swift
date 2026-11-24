import SwiftUI

/// По какому показателю красить плитки карты.
enum ColorMetric: String, CaseIterable, Identifiable {
    case change, pe, ps, pb, divYield, range52, beta, revGrowth, relVolume

    var id: String { rawValue }
    static let storageKey = "colorMetric"

    var title: LocalizedStringKey {
        switch self {
        case .change: return "% change"
        case .pe: return "P/E"
        case .ps: return "P/S"
        case .pb: return "P/B"
        case .divYield: return "Dividend yield"
        case .range52: return "52-week range"
        case .beta: return "Beta"
        case .revGrowth: return "Revenue growth"
        case .relVolume: return "Relative volume"
        }
    }

    /// Кривая «значение → оценка» для коэффициентов, где меньше = лучше (зелёный): (значение, оценка −1…+1).
    /// Ступени «почти логарифмические»; ниже первой — полностью зелёный, выше последней — полностью красный.
    private var curve: [(Double, Double)]? {
        switch self {
        case .pe: return [(10, 1), (15, 0.6), (20, 0.25), (30, -0.3), (50, -1)]
        case .ps: return [(1, 1), (3, 0.4), (6, -0.2), (10, -0.7), (15, -1)]
        case .pb: return [(1, 1), (2, 0.5), (4, 0), (7, -0.6), (10, -1)]
        case .beta: return [(0.5, 1), (1, 0.15), (1.5, -0.5), (2, -1)]
        default: return nil
        }
    }

    /// Мультипликаторы «цена к чему-то»: отрицательное значение (убыток, отрицательный капитал) смысла не имеет.
    private var needsPositive: Bool { self == .pe || self == .ps || self == .pb }

    /// Положение цвета на шкале: -1 (плохо/красный) … +1 (хорошо/зелёный); nil — серый.
    func score(_ value: Double?) -> Double? {
        guard let value else { return nil }
        if needsPositive && value <= 0 { return nil }
        if let curve {
            if value <= curve[0].0 { return curve[0].1 }
            for i in 1..<curve.count where value <= curve[i].0 {
                let (x0, y0) = curve[i - 1], (x1, y1) = curve[i]
                return y0 + (y1 - y0) * (value - x0) / (x1 - x0)
            }
            return curve[curve.count - 1].1
        }
        switch self {
        case .change:
            return max(-1, min(1, value / SharedHeat.cap))
        case .divYield:
            return max(0, min(1, value / 5))
        case .range52:
            return max(-1, min(1, (value - 0.5) * 2))
        case .revGrowth:
            // −20 % и хуже — красный, +30 % и лучше — зелёный.
            return value < 0 ? max(-1, value / 20) : min(1, value / 30)
        case .relVolume:
            // 0,5× и меньше — серый, 3× и больше — самый яркий.
            return max(0, min(1, (value - 0.5) / 2.5))
        default:
            return nil
        }
    }

    func color(_ value: Double?, period: String? = nil) -> Color {
        if self == .change { return HeatmapColor.color(for: value, period: period) }
        guard let s = score(value) else { return SharedHeat.color(for: nil) }
        return SharedHeat.color(for: s * SharedHeat.cap)
    }

    /// Подпись значения на плитке.
    func format(_ value: Double) -> String {
        switch self {
        case .change: return formatPercent(value)
        case .pe, .ps, .pb: return formatDecimal(value, fractionDigits: 1)
        case .divYield: return formatPercent(value)
        case .range52: return (value).formatted(.percent.precision(.fractionLength(0)).locale(AppLanguage.locale))
        case .beta: return formatDecimal(value, fractionDigits: 2)
        case .revGrowth: return formatPercent(value)
        case .relVolume: return formatDecimal(value, fractionDigits: 1) + "×"
        }
    }

    /// Левый и правый край легенды.
    var legendEnds: (low: String, high: String) {
        if let curve, let first = curve.first, let last = curve.last {
            func plain(_ x: Double) -> String { formatDecimal(x, fractionDigits: x == x.rounded() ? 0 : 1) }
            return ("≤" + plain(first.0), "≥" + plain(last.0))
        }
        switch self {
        case .divYield: return (formatPercent(0), "≥" + formatPercent(5))
        case .range52: return (format(0), format(1))
        case .revGrowth: return ("−20%", "+30%")
        case .relVolume: return ("≤" + formatDecimal(0.5, fractionDigits: 1) + "×", "≥" + formatDecimal(3, fractionDigits: 0) + "×")
        default: return ("−3%", "+3%")
        }
    }

    /// Градиент легенды слева направо (для коэффициентов слева дорого/красный, справа дёшево/зелёный — как у остальных: плохо → хорошо).
    var legendStops: [Color] {
        if let curve { return curve.map(\.1).reversed().map { SharedHeat.color(for: $0 * SharedHeat.cap) } }
        switch self {
        case .change: return [-1.0, 0, 1].map { color($0 * SharedHeat.cap) }
        case .divYield: return [0.0, 0.5, 1].map { SharedHeat.color(for: $0 * SharedHeat.cap) }
        case .relVolume: return [0.0, 0.5, 1].map { SharedHeat.color(for: $0 * SharedHeat.cap) }
        default: return [-1.0, 0, 1].map { SharedHeat.color(for: $0 * SharedHeat.cap) }
        }
    }

    /// Для коэффициентов шкала перевёрнута: слева большое значение (дорого), справа маленькое.
    var legendReversed: Bool { curve != nil }
}

struct CompanyMetrics: Decodable {
    let pe: Double?
    let ps: Double?
    let pb: Double?
    let divYield: Double?
    let pos52w: Double?
    let beta: Double?
    let revGrowth: Double?
    let volume: Double?
    let avgVolume: Double?
    let relVolume: Double?
    let turnoverUSD: Double?

    func value(_ metric: ColorMetric) -> Double? {
        switch metric {
        case .change: return nil
        case .pe: return pe
        case .ps: return ps
        case .pb: return pb
        case .divYield: return divYield
        case .range52: return pos52w
        case .beta: return beta
        case .revGrowth: return revGrowth
        case .relVolume: return relVolume
        }
    }

    /// Вес плитки при размере «по объёму» / «по обороту».
    func sizeValue(_ mode: SizeMode) -> Double? {
        switch mode {
        case .volume: return volume
        case .turnover: return turnoverUSD
        default: return nil
        }
    }
}

/// Показатели для окраски: одна загрузка на индекс, затем из памяти.
@MainActor
final class MetricStore: ObservableObject {
    static let shared = MetricStore()

    @Published private(set) var data: [String: [String: CompanyMetrics]] = [:]
    private var loading: Set<String> = []

    func load(index: String) async {
        guard data[index] == nil, !loading.contains(index) else { return }
        loading.insert(index)
        defer { loading.remove(index) }
        if let fetched = try? await NetworkService.shared.fetchMetrics(index: index) {
            data[index] = fetched
        }
    }

    func available(for index: String) -> [ColorMetric] {
        guard let all = data[index] else { return [.change] }
        var result: [ColorMetric] = [.change]
        for m in ColorMetric.allCases where m != .change && all.values.contains(where: { $0.value(m) != nil }) {
            result.append(m)
        }
        return result
    }

    /// Значение для одной компании.
    func value(_ metric: ColorMetric, ticker: String, index: String) -> Double? {
        data[index]?[ticker]?.value(metric)
    }

    /// Значение для плитки сектора или подсектора: среднее по капитализации; для «цена к чему-то»
    /// (P/E, P/S, P/B) — гармоническое среднее (одна дорогая бумага не раздувает сектор).
    func aggregate(_ metric: ColorMetric, companies: [Company], index: String) -> Double? {
        var sum = 0.0, weight = 0.0
        let harmonic = metric == .pe || metric == .ps || metric == .pb
        for c in companies {
            guard var v = value(metric, ticker: c.ticker, index: index) else { continue }
            if harmonic && v <= 0 { continue }
            if metric == .revGrowth { v = max(-100, min(200, v)) }   // выбросы после малой базы
            sum += (harmonic ? 1 / v : v) * c.marketCap
            weight += c.marketCap
        }
        guard weight > 0, sum != 0 else { return nil }
        return harmonic ? weight / sum : sum / weight
    }

    // MARK: размер плиток

    /// Режимы размера, для которых есть данные (иначе пункт скрыт).
    func availableSizeModes(for index: String) -> [SizeMode] {
        var result: [SizeMode] = [.marketCap, .equal]
        guard let all = data[index] else { return result }
        if all.values.contains(where: { ($0.volume ?? 0) > 0 }) { result.append(.volume) }
        if all.values.contains(where: { ($0.turnoverUSD ?? 0) > 0 }) { result.append(.turnover) }
        return result
    }

    /// Есть ли данные объёма хотя бы по одному загруженному индексу (для экрана настроек).
    var anyVolumeData: Bool {
        data.values.contains { $0.values.contains { ($0.volume ?? 0) > 0 } }
    }
    var anyTurnoverData: Bool {
        data.values.contains { $0.values.contains { ($0.turnoverUSD ?? 0) > 0 } }
    }

    /// Вес плитки (компании или группы компаний) в карте. Нет данных для режима — работает капитализация.
    func sizeWeight(_ companies: [Company], index: String) -> Double {
        var mode = SizeMode.current
        if mode != .marketCap && mode != .equal && !availableSizeModes(for: index).contains(mode) { mode = .marketCap }
        switch mode {
        case .equal: return 1
        case .marketCap: return max(companies.reduce(0) { $0 + $1.marketCap }, 1)
        case .volume, .turnover:
            let total = companies.reduce(0) { $0 + (data[index]?[$1.ticker]?.sizeValue(mode) ?? 0) }
            return max(total, 1)
        }
    }
}

/// Выбор показателя (рядом с чипами периода). Одно значение хранится на все экраны карт.
struct MetricMenu: View {
    @Binding var metric: ColorMetric
    let options: [ColorMetric]

    var body: some View {
        if options.count > 1 {
            Menu {
                Picker(selection: $metric) {
                    ForEach(options) { m in Text(m.title).tag(m) }
                } label: { Text("Color by") }
            } label: {
                HStack(spacing: 4) {
                    Text(metric.title).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .themeChip(selected: metric != .change)
            }
            .accessibilityLabel(Text("Color by"))
        }
    }
}

/// Быстрый выбор размера плиток (значок рядом с «Окраска по»).
struct SizeMenu: View {
    let index: String
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var metrics = MetricStore.shared

    var body: some View {
        let options = metrics.availableSizeModes(for: index)
        if options.count > 2 {
            Menu {
                Picker(selection: $settings.sizeMode) {
                    ForEach(options) { m in Text(m.title).tag(m) }
                } label: { Text("Size by") }
            } label: {
                Image(systemName: "square.resize")
                    .font(.system(size: 12, weight: .semibold))
                    .themeChip(selected: settings.sizeMode != .marketCap)
            }
            .accessibilityLabel(Text("Size by"))
        }
    }
}

/// Полоса-легенда под чипами (для всех показателей, кроме % изменения).
struct MetricLegend: View {
    let metric: ColorMetric

    var body: some View {
        if metric != .change {
            let ends = metric.legendEnds
            HStack(spacing: 8) {
                Text(verbatim: metric.legendReversed ? ends.high : ends.low)
                LinearGradient(colors: metric.legendStops, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 8)
                    .clipShape(Capsule())
                Text(verbatim: metric.legendReversed ? ends.low : ends.high)
            }
            .font(Theme.ui(.caption2))
            .foregroundColor(Theme.muted)
            .padding(.horizontal)
            .padding(.vertical, 2)
        }
    }
}

/// Ряд «показатель + периоды».
struct MetricPeriodRow: View {
    @Binding var period: String
    @Binding var metric: ColorMetric
    let options: [ColorMetric]
    var availablePeriods: [String]? = nil

    var body: some View {
        HStack(spacing: 0) {
            SizeMenu(index: IndexStore.shared.selectedId)
                .padding(.leading)
            MetricMenu(metric: $metric, options: options)
                .padding(.leading, 8)
            PeriodSwitchView(selectedPeriod: $period, availablePeriods: availablePeriods)
        }
    }
}
