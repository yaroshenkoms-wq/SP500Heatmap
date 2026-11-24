import SwiftUI

/// Быстрый просмотр компании: цена, % за день, график за год.
struct CompanyView: View {
    let ticker: String
    let name: String
    let currency: String?
    @State private var closes: [Double] = []
    @State private var loading = true

    private var price: Double? { closes.last }
    private var day: Double? {
        guard closes.count >= 2, closes[closes.count - 2] != 0 else { return nil }
        return (closes[closes.count - 1] / closes[closes.count - 2] - 1) * 100
    }
    private var year: [Double] { Array(closes.suffix(252)) }
    private var yearChange: Double? {
        guard let first = year.first, first != 0, let last = year.last else { return nil }
        return (last / first - 1) * 100
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: name).font(.footnote).foregroundStyle(WTheme.muted).lineLimit(2)
                if let price {
                    Text(verbatim: priceString(price, currency: currency))
                        .font(.title3.weight(.semibold)).foregroundStyle(WTheme.text)
                        .minimumScaleFactor(0.6).lineLimit(1)
                    HStack {
                        Text(verbatim: "1d").foregroundStyle(WTheme.muted)
                        Text(verbatim: WTheme.pct(day)).foregroundStyle(WTheme.textColor(day))
                        Spacer()
                        Text(verbatim: "1y").foregroundStyle(WTheme.muted)
                        Text(verbatim: WTheme.pct(yearChange)).foregroundStyle(WTheme.textColor(yearChange))
                    }
                    .font(.caption.weight(.semibold))
                    Sparkline(values: year, color: WTheme.textColor(yearChange))
                        .frame(height: 56)
                } else {
                    LoadingOrEmpty(loading: loading)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(Text(verbatim: ticker))
        .task {
            loading = true
            closes = (try? await WatchAPI.closes(ticker: ticker)) ?? []
            loading = false
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color

    private func points(_ size: CGSize) -> [CGPoint] {
        guard let lo = values.min(), let hi = values.max(), values.count > 1, hi > lo else { return [] }
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { i, v in
            CGPoint(x: CGFloat(i) * step, y: size.height * (1 - CGFloat((v - lo) / (hi - lo))))
        }
    }

    var body: some View {
        GeometryReader { geo in
            let pts = points(geo.size)
            if let first = pts.first {
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: geo.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: first)
                        pts.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
        }
    }
}
