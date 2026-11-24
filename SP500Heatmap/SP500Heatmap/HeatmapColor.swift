import SwiftUI

enum HeatmapColor {
    /// Цвет текста на плитках.
    static let tileText = Theme.text

    /// Палитра (красно-зелёная или для дальтоников) берётся из настроек, см. SharedHeat.
    static func color(for changePercent: Double?) -> Color {
        SharedHeat.color(for: changePercent)
    }
}
