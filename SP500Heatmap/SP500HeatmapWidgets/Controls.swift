import SwiftUI
import WidgetKit
import AppIntents

// Пункты управления iOS 18: открыть приложение или сразу нужный индекс.
// Приложение понимает адреса sp500heatmap://home и sp500heatmap://index/<id>.

struct OpenAppControl: ControlWidget {
    static let kind = "com.maximyaroshenko.SP500Heatmap2.OpenAppControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "sp500heatmap://home")!)) {
                Label("Open SP500 Heatmap", systemImage: "chart.bar.xaxis")
            }
        }
        .displayName("Open SP500 Heatmap")
        .description("Opens the world markets map.")
    }
}

struct OpenIndexConfiguration: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Choose index"

    @Parameter(title: "Index")
    var index: IndexEntity?
}

struct OpenIndexControl: ControlWidget {
    static let kind = "com.maximyaroshenko.SP500Heatmap2.OpenIndexControl"

    struct Value {
        var id: String
        var name: String
    }

    struct Provider: AppIntentControlValueProvider {
        func previewValue(configuration: OpenIndexConfiguration) -> Value {
            Value(id: configuration.index?.id ?? "sp500", name: configuration.index?.name ?? "S&P 500")
        }

        func currentValue(configuration: OpenIndexConfiguration) async throws -> Value {
            previewValue(configuration: configuration)
        }
    }

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: Self.kind, provider: Provider()) { value in
            ControlWidgetButton(action: OpenURLIntent(URL(string: "sp500heatmap://index/\(value.id)")!)) {
                Label(value.name, systemImage: "chart.line.uptrend.xyaxis")
            }
        }
        .displayName("Open index…")
        .description("Opens the map of the index you choose.")
    }
}
