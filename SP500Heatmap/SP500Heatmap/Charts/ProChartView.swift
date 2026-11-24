import SwiftUI
import Charts

/// Профессиональный график акции: диапазоны, линия/свечи, объём, SMA/EMA, RSI/MACD,
/// сравнение с индексом, перекрестие при касании, полный экран.
struct ProChartView: View {
    let ticker: String
    let indexId: String
    var fullScreen = false

    @EnvironmentObject private var indexStore: IndexStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss

    @State private var range: ProRange = .y1
    @State private var style: ChartStyle = .line
    @State private var overlays: Set<ChartOverlay> = []
    @State private var lower: LowerPane = .none
    @State private var compare = false
    @State private var bars: [ChartBar] = []
    @State private var indexBars: [ChartBar] = []
    @State private var loading = true
    @State private var lineOnly = false
    @State private var selected: Int?
    @State private var showFullScreen = false
    @State private var plotWidth: CGFloat = 300

    private var isRegular: Bool { sizeClass == .regular }
    private var proxyTicker: String? { ChartIndexProxy.ticker(forIndexId: indexId) }
    private var canCompare: Bool { proxyTicker != nil && proxyTicker != ticker }
    private var comparing: Bool { compare && canCompare && !indexBars.isEmpty }
    private var showCandles: Bool { style == .candles && !lineOnly && !comparing }
    private var hasVolume: Bool { bars.contains { ($0.v ?? 0) > 0 } && !lineOnly }

    private var closes: [Double] { bars.map(\.c) }
    private var rebasedStock: [Double] {
        guard let base = closes.first, base > 0 else { return [] }
        return closes.map { $0 / base * 100 }
    }
    private var rebasedIndex: [Double?] { ChartIndexProxy.rebased(index: indexBars, to: bars) }

    private var upColor: Color { Theme.changeColor(1) }
    private var downColor: Color { Theme.changeColor(-1) }

    private func overlayColor(_ o: ChartOverlay) -> Color {
        switch o {
        case .sma20: return Theme.gold2
        case .sma50: return Color(hex: 0x7FB8EE)
        case .sma200: return Color(hex: 0xB48EE0)
        case .ema20: return Color(hex: 0xF0A85C)
        }
    }

    private func overlaySeries(_ o: ChartOverlay) -> [Double?] {
        switch o {
        case .sma20: return Indicators.sma(closes, period: 20)
        case .sma50: return Indicators.sma(closes, period: 50)
        case .sma200: return Indicators.sma(closes, period: 200)
        case .ema20: return Indicators.ema(closes, period: 20)
        }
    }

    private var mainHeight: CGFloat {
        if fullScreen { return 220 }
        return isRegular ? 380 : 240
    }

    // MARK: Тело

    var body: some View {
        Group {
            if fullScreen {
                VStack(spacing: 8) {
                    HStack {
                        rangeChips
                        Spacer(minLength: 8)
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.subheadline)
                                .frame(width: 34, height: 34)
                                .outlinedControl()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Close"))
                    }
                    controls
                    ScrollView { chartStack }
                }
                .padding(12)
                .themeScreen()
                .onAppear { ProChartView.requestOrientation(.landscape) }
                .onDisappear { ProChartView.requestOrientation(.portrait) }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        rangeChips
                        Spacer(minLength: 4)
                        if UIDevice.current.userInterfaceIdiom == .phone {
                            Button { showFullScreen = true } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.footnote)
                                    .frame(width: 34, height: 34)
                                    .outlinedControl()
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Full-screen chart"))
                        }
                    }
                    controls
                    chartStack
                }
                .padding(12)
                .panelCard()
                .padding(.horizontal)
                .fullScreenCover(isPresented: $showFullScreen) {
                    ProChartView(ticker: ticker, indexId: indexId, fullScreen: true)
                        .environmentObject(indexStore)
                        .preferredColorScheme(.dark)
                }
            }
        }
        .task(id: range) { await load() }
        .task(id: compare) { await loadIndexIfNeeded() }
    }

    static func requestOrientation(_ mask: UIInterfaceOrientationMask) {
        guard UIDevice.current.userInterfaceIdiom == .phone,
              let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }

    // MARK: Управление

    private var rangeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ProRange.allCases) { r in
                    Button { range = r; selected = nil } label: {
                        Text(verbatim: r.label).themeChip(selected: range == r)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var controls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ChartStyle.allCases, id: \.self) { s in
                    Button { style = s } label: {
                        Text(LocalizedStringKey(s == .line ? "Line" : "Candles")).themeChip(selected: style == s)
                    }
                    .buttonStyle(.plain)
                }
                divider
                ForEach(ChartOverlay.allCases) { o in
                    Button {
                        if overlays.contains(o) { overlays.remove(o) } else { overlays.insert(o) }
                    } label: {
                        Text(verbatim: o.label).themeChip(selected: overlays.contains(o))
                    }
                    .buttonStyle(.plain)
                    .disabled(comparing)
                }
                divider
                ForEach(LowerPane.allCases, id: \.self) { p in
                    Button { lower = p } label: {
                        Group {
                            switch p {
                            case .none: Text("None")
                            case .rsi: Text(verbatim: "RSI 14")
                            case .macd: Text(verbatim: "MACD")
                            }
                        }
                        .themeChip(selected: lower == p)
                    }
                    .buttonStyle(.plain)
                }
                if canCompare {
                    divider
                    Button { compare.toggle() } label: {
                        Text("Compare").themeChip(selected: compare)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(width: 1, height: 18)
    }

    // MARK: Графики

    @ViewBuilder private var chartStack: some View {
        if loading && bars.isEmpty {
            ProgressView().frame(height: mainHeight).frame(maxWidth: .infinity)
        } else if bars.count < 2 {
            Text("No data available.")
                .font(Theme.ui(.subheadline))
                .foregroundColor(Theme.muted)
                .frame(height: mainHeight)
                .frame(maxWidth: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if lineOnly {
                    Text("Candles and volume are unavailable: showing closing prices only.")
                        .font(Theme.ui(.caption2))
                        .foregroundColor(Theme.muted)
                }
                legend
                ZStack(alignment: .top) {
                    mainChart.frame(height: mainHeight)
                    if let i = selected, bars.indices.contains(i) { bubble(i) }
                }
                if hasVolume { volumeChart.frame(height: 56) }
                switch lower {
                case .rsi: rsiChart.frame(height: 80)
                case .macd: macdChart.frame(height: 90)
                case .none: EmptyView()
                }
                dateAxis
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            if comparing {
                legendItem(Theme.gold, ticker)
                legendItem(Theme.text, proxyTicker ?? "")
            } else {
                ForEach(ChartOverlay.allCases.filter { overlays.contains($0) }) { o in
                    legendItem(overlayColor(o), o.label)
                }
            }
        }
        .font(Theme.ui(.caption2))
    }

    private func legendItem(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(verbatim: text).foregroundColor(Theme.muted)
        }
    }

    private func barWidth(_ width: CGFloat) -> CGFloat {
        max(1, width / CGFloat(max(bars.count, 1)) * 0.7)
    }

    private var xDomain: ClosedRange<Int> { 0...max(bars.count - 1, 1) }

    private func yDomain(_ lo: Double, _ hi: Double) -> ClosedRange<Double> {
        let pad = max((hi - lo) * 0.06, 0.0001)
        return (lo - pad)...(hi + pad)
    }

    private var mainDomain: ClosedRange<Double> {
        if comparing {
            let all = rebasedStock + rebasedIndex.compactMap { $0 }
            return yDomain(all.min() ?? 90, all.max() ?? 110)
        }
        var lo = bars.map { showCandles ? $0.l : $0.c }.min() ?? 0
        var hi = bars.map { showCandles ? $0.h : $0.c }.max() ?? 1
        for o in overlays {
            for v in overlaySeries(o) { if let v { lo = min(lo, v); hi = max(hi, v) } }
        }
        return yDomain(lo, hi)
    }

    private func axisText(_ v: Double) -> String {
        formatDecimal(v, fractionDigits: abs(v) >= 100 ? 0 : 2)
    }

    private var mainChart: some View {
        GeometryReader { geo in
            let candleWidth = barWidth(geo.size.width - 56)
            Chart {
                if comparing {
                    ForEach(bars) { b in
                        LineMark(x: .value("i", b.id), y: .value("v", rebasedStock[b.id]), series: .value("s", "stock"))
                            .foregroundStyle(Theme.gold)
                    }
                    ForEach(bars) { b in
                        if let v = rebasedIndex[b.id] {
                            LineMark(x: .value("i", b.id), y: .value("v", v), series: .value("s", "index"))
                                .foregroundStyle(Theme.text.opacity(0.85))
                        }
                    }
                    RuleMark(y: .value("base", 100))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(Theme.line)
                } else if showCandles {
                    ForEach(bars) { b in
                        let color = b.c >= b.o ? upColor : downColor
                        RuleMark(x: .value("i", b.id), yStart: .value("l", b.l), yEnd: .value("h", b.h))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .foregroundStyle(color)
                        RectangleMark(x: .value("i", b.id), yStart: .value("o", b.o), yEnd: .value("c", b.c),
                                      width: .fixed(candleWidth))
                            .foregroundStyle(color)
                    }
                } else {
                    ForEach(bars) { b in
                        LineMark(x: .value("i", b.id), y: .value("c", b.c), series: .value("s", "price"))
                            .foregroundStyle(Theme.gold)
                    }
                }
                if !comparing {
                    ForEach(ChartOverlay.allCases.filter { overlays.contains($0) }) { o in
                        let values = overlaySeries(o)
                        ForEach(bars) { b in
                            if let v = values[b.id] {
                                LineMark(x: .value("i", b.id), y: .value("v", v), series: .value("s", o.rawValue))
                                    .foregroundStyle(overlayColor(o))
                                    .lineStyle(StrokeStyle(lineWidth: 1.2))
                            }
                        }
                    }
                }
                if let i = selected, bars.indices.contains(i) {
                    RuleMark(x: .value("i", i))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Theme.text.opacity(0.6))
                }
            }
            .chartXScale(domain: xDomain)
            .chartYScale(domain: mainDomain)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisGridLine().foregroundStyle(Theme.line)
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(verbatim: axisText(v))
                                .font(Theme.ui(.caption2))
                                .foregroundColor(Theme.muted)
                                .frame(width: 44, alignment: .leading)
                        }
                    }
                }
            }
            .chartOverlay { proxy in crosshairLayer(proxy) }
            .onAppear { plotWidth = geo.size.width - 56 }
            .onChange(of: geo.size.width) { _, w in plotWidth = w - 56 }
        }
    }

    private var volumeChart: some View {
        Chart {
            ForEach(bars) { b in
                BarMark(x: .value("i", b.id), y: .value("v", b.v ?? 0), width: .fixed(barWidth(plotWidth)))
                    .foregroundStyle((b.c >= b.o ? upColor : downColor).opacity(0.55))
            }
            if let i = selected, bars.indices.contains(i) {
                RuleMark(x: .value("i", i))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Theme.text.opacity(0.6))
            }
        }
        .chartXScale(domain: xDomain)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(verbatim: formatCompact(v))
                            .font(Theme.ui(.caption2))
                            .foregroundColor(Theme.muted)
                            .frame(width: 44, alignment: .leading)
                    }
                }
            }
        }
    }

    private var rsiChart: some View {
        let rsi = Indicators.rsi(closes, period: 14)
        return Chart {
            ForEach(bars) { b in
                if let v = rsi[b.id] {
                    LineMark(x: .value("i", b.id), y: .value("RSI", v), series: .value("s", "rsi"))
                        .foregroundStyle(Theme.gold)
                }
            }
            RuleMark(y: .value("70", 70)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(downColor.opacity(0.7))
            RuleMark(y: .value("30", 30)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(upColor.opacity(0.7))
            if let i = selected, bars.indices.contains(i) {
                RuleMark(x: .value("i", i))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Theme.text.opacity(0.6))
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [30, 70]) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(verbatim: "\(Int(v))")
                            .font(Theme.ui(.caption2))
                            .foregroundColor(Theme.muted)
                            .frame(width: 44, alignment: .leading)
                    }
                }
            }
        }
    }

    private var macdChart: some View {
        let macd = Indicators.macd(closes)
        return Chart {
            ForEach(bars) { b in
                if let h = macd[b.id]?.histogram {
                    BarMark(x: .value("i", b.id), yStart: .value("0", 0), yEnd: .value("hist", h), width: .fixed(barWidth(plotWidth)))
                        .foregroundStyle((h >= 0 ? upColor : downColor).opacity(0.55))
                }
            }
            ForEach(bars) { b in
                if let m = macd[b.id]?.macd {
                    LineMark(x: .value("i", b.id), y: .value("MACD", m), series: .value("s", "macd"))
                        .foregroundStyle(Theme.gold)
                }
            }
            ForEach(bars) { b in
                if let s = macd[b.id]?.signal {
                    LineMark(x: .value("i", b.id), y: .value("Signal", s), series: .value("s", "signal"))
                        .foregroundStyle(Color(hex: 0x7FB8EE))
                }
            }
            if let i = selected, bars.indices.contains(i) {
                RuleMark(x: .value("i", i))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Theme.text.opacity(0.6))
            }
        }
        .chartXScale(domain: xDomain)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(verbatim: formatDecimal(v, fractionDigits: abs(v) >= 10 ? 0 : 2))
                            .font(Theme.ui(.caption2))
                            .foregroundColor(Theme.muted)
                            .frame(width: 44, alignment: .leading)
                    }
                }
            }
        }
    }

    /// Подписи дат под графиками: пять равномерных меток.
    private var dateAxis: some View {
        let count = bars.count
        let picks = (0..<5).map { Int(Double(count - 1) * Double($0) / 4.0) }
        return HStack {
            ForEach(Array(picks.enumerated()), id: \.offset) { n, i in
                if n > 0 { Spacer(minLength: 0) }
                Text(verbatim: axisDate(bars[i].date))
                    .font(Theme.ui(.caption2))
                    .foregroundColor(Theme.muted)
            }
        }
        .padding(.trailing, 44)
        .environment(\.layoutDirection, .leftToRight)
    }

    private func axisDate(_ d: Date) -> String {
        switch range {
        case .m1, .m3, .m6: return d.formatted(.dateTime.day().month(.abbreviated).locale(AppLanguage.locale))
        default: return d.formatted(.dateTime.month(.abbreviated).year(.twoDigits).locale(AppLanguage.locale))
        }
    }

    // MARK: Перекрестие

    private func crosshairLayer(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle().fill(Color.clear).contentShape(Rectangle())
                .gesture(
                    LongPressGesture(minimumDuration: 0.12)
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .onChanged { value in
                            guard case .second(true, let drag?) = value, let frame = proxy.plotFrame else { return }
                            let x = drag.location.x - geo[frame].origin.x
                            if let idx: Int = proxy.value(atX: x) {
                                selected = min(max(idx, 0), bars.count - 1)
                            }
                        }
                        .onEnded { _ in selected = nil }
                )
        }
    }

    private func bubble(_ i: Int) -> some View {
        let b = bars[i]
        let first = bars.first?.c ?? b.c
        let pct = first > 0 ? (b.c / first - 1) * 100 : 0
        let price = { (v: Double) in indexStore.formatPrice(v) }
        let left = i > bars.count / 2
        return VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: b.date.formatted(.dateTime.day().month(.abbreviated).year().locale(AppLanguage.locale)))
                .font(Theme.ui(.caption2, weight: .semibold))
                .foregroundColor(Theme.text)
            if lineOnly {
                Text(verbatim: price(b.c)).font(Theme.ui(.caption2)).foregroundColor(Theme.text)
            } else {
                Text(verbatim: "O \(price(b.o))  H \(price(b.h))")
                    .font(Theme.ui(.caption2)).foregroundColor(Theme.text)
                Text(verbatim: "L \(price(b.l))  C \(price(b.c))")
                    .font(Theme.ui(.caption2)).foregroundColor(Theme.text)
            }
            if let v = b.v, v > 0 {
                (Text("Volume") + Text(verbatim: " " + formatCompact(v)))
                    .font(Theme.ui(.caption2)).foregroundColor(Theme.muted)
            }
            Text(verbatim: sharedPercent(pct, locale: AppLanguage.locale))
                .font(Theme.ui(.caption2, weight: .semibold))
                .foregroundColor(Theme.changeColor(pct))
        }
        .padding(6)
        .background(Theme.bg2.opacity(0.92), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: left ? .leading : .trailing)
        .padding(.horizontal, 4)
        .allowsHitTesting(false)
        .environment(\.layoutDirection, .leftToRight)
    }

    // MARK: Загрузка

    private func load() async {
        loading = true
        defer { loading = false }
        if let series = try? await NetworkService.shared.fetchOHLC(ticker: ticker, range: range.rawValue) {
            let loaded = ChartBarLoader.bars(from: series)
            if loaded.count >= 2 {
                bars = loaded
                lineOnly = false
                await loadIndexIfNeeded()
                return
            }
        }
        if Task.isCancelled { return }
        let fallback = await ChartBarLoader.fallbackBars(ticker: ticker, range: range)
        if Task.isCancelled { return }
        bars = fallback
        lineOnly = true
        await loadIndexIfNeeded()
    }

    private func loadIndexIfNeeded() async {
        guard compare, canCompare, let proxy = proxyTicker else { indexBars = []; return }
        if let series = try? await NetworkService.shared.fetchOHLC(ticker: proxy, range: range.rawValue) {
            indexBars = ChartBarLoader.bars(from: series)
        } else {
            indexBars = []
        }
    }
}
