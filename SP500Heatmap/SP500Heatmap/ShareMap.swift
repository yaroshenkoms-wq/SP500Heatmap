import SwiftUI
import UIKit

/// Подпись под заголовком картинки: период и дата данных.
func shareSubtitle(period: String, asOf: String?) -> String {
    let date = localizedShortDate(asOf)
        ?? Date().formatted(.dateTime.day().month(.abbreviated).year().locale(AppLanguage.locale))
    return AppLanguage.string(period) + " · " + date
}

private struct SharedImageFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Картинка для отправки: заголовок, период, дата, сама карта и водяной знак.
private struct ShareCard<Map: View>: View {
    let title: String
    let subtitle: String
    let map: Map

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(Theme.serif(.title))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(verbatim: subtitle)
                    .font(Theme.ui(.footnote))
                    .foregroundColor(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            map
                .frame(height: 500)
            HStack {
                Text(verbatim: "SP500 Heatmap")
                    .font(Theme.ui(.caption, weight: .semibold))
                    .tracking(0.8)
                    .foregroundColor(Theme.gold)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 390)
        .background(Theme.bg)
    }
}

/// Кнопка «Поделиться картой»: рисует текущую карту через ImageRenderer (масштаб 3)
/// и открывает системное окно отправки.
struct ShareMapButton<Map: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let map: () -> Map
    @State private var file: SharedImageFile?

    var body: some View {
        Button(action: render) {
            Image(systemName: "square.and.arrow.up")
                .font(.subheadline)
                .frame(width: 34, height: 34)
                .outlinedControl()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Share map"))
        .sheet(item: $file) { item in
            ActivityView(items: [item.url])
                .presentationDetents([.medium, .large])
        }
    }

    @MainActor
    private func render() {
        let card = ShareCard(title: title, subtitle: subtitle, map: map())
            .environment(\.locale, AppLanguage.locale)
            .environment(\.layoutDirection, AppLanguage.isRightToLeft ? .rightToLeft : .leftToRight)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        guard let image = renderer.uiImage, let data = image.pngData() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SP500 Heatmap.png")
        do {
            try data.write(to: url, options: .atomic)
            file = SharedImageFile(url: url)
        } catch {
            return
        }
    }
}
