import SwiftUI

/// По какому показателю красить плитки карты.
enum ColorMetric: String, CaseIterable, Identifiable {
    case change, pe, divYield, range52

    var id: String { rawValue }
    static let storageKey = "colorMetric"

    var title: LocalizedStringKey {
        switch self {
        case .change: return "% change"
        case .pe: return "P/E"
        case .divYield: return "Dividend yield"
        case .range52: return "52-week range"
        }
    }

    /// Положение цвета на шкале: -1 (плохо/красный) … +1 (хорошо/зелёный); nil — серый.
    func score(_ value: Double?) -> Double? {
        guard let value else { return nil }
        switch self {
        case .change:
            return max(-1, min(1, value / SharedHeat.cap))
        case .pe:
            guard value > 0 else { return nil }
            // Ступени «почти логарифмические»: ≤10 дёшево, 15, 20, 30, ≥50 дорого.
            let stops: [(Double, Double)] = [(10, 1), (15, 0.6), (20, 0.25), (30, -0.3), (50, -1)]
            if value <= stops[0].0 { return 1 }
            for i in 1..<stops.count where value <= stops[i].0 {
                let (x0, y0) = stops[i - 1], (x1, y1) = stops[i]
                return y0 + (y1 - y0) * (value - x0) / (x1 - x0)
            }
            return -1
        case .divYield:
            return max(0, min(1, value / 5))
        case .range52:
            return max(-1, min(1, (value - 0.5) * 2))
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
        case .pe: return formatDecimal(value, fractionDigits: 1)
        case .divYield: return formatPercent(value)
        case .range52: return (value).formatted(.percent.precision(.fractionLength(0)).locale(AppLanguage.locale))
        }
    }

    /// Левый и правый край легенды.
    var legendEnds: (low: String, high: String) {
        switch self {
        case .change: return ("−3%", "+3%")
        case .pe: return ("≤" + formatDecimal(10, fractionDigits: 0), "≥" + formatDecimal(50, fractionDigits: 0))
        case .divYield: return (formatPercent(0), "≥" + formatPercent(5))
        case .range52: return (format(0), format(1))
        }
    }

    /// Градиент легенды слева направо (для P/E слева дорого/красный, справа дёшево/зелёный — как у остальных: плохо → хорошо).
    var legendStops: [Color] {
        switch self {
        case .change: return [-1.0, 0, 1].map { color($0 * SharedHeat.cap) }
        case .pe: return [-1.0, -0.3, 0.25, 0.6, 1].map { SharedHeat.color(for: $0 * SharedHeat.cap) }
        case .divYield: return [0.0, 0.5, 1].map { SharedHeat.color(for: $0 * SharedHeat.cap) }
        case .range52: return [-1.0, 0, 1].map { SharedHeat.color(for: $0 * SharedHeat.cap) }
        }
    }

    /// Для P/E шкала перевёрнута: слева большое значение (дорого), справа маленькое.
    var legendReversed: Bool { self == .pe }
}

struct CompanyMetrics: Decodable {
    let pe: Double?
    let divYield: Double?
    let pos52w: Double?

    func value(_ metric: ColorMetric) -> Double? {
        switch metric {
        case .change: return nil
        case .pe: return pe
        case .divYield: return divYield
        case .range52: return pos52w
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
        for m in [ColorMetric.pe, .divYield, .range52] where all.values.contains(where: { $0.value(m) != nil }) {
            result.append(m)
        }
        return result
    }

    /// Значение для одной компании.
    func value(_ metric: ColorMetric, ticker: String, index: String) -> Double? {
        data[index]?[ticker]?.value(metric)
    }

    /// Среднее по капитализации для плитки сектора или подсектора.
    func aggregate(_ metric: ColorMetric, companies: [Company], index: String) -> Double? {
        var sum = 0.0, weight = 0.0
        for c in companies {
            guard let v = value(metric, ticker: c.ticker, index: index) else { continue }
            if metric == .pe && v <= 0 { continue }
            sum += v * c.marketCap
            weight += c.marketCap
        }
        return weight > 0 ? sum / weight : nil
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
            MetricMenu(metric: $metric, options: options)
                .padding(.leading)
            PeriodSwitchView(selectedPeriod: $period, availablePeriods: availablePeriods)
        }
    }
}
