import SwiftUI

enum HeatmapColor {
    // % change at which the color reaches full saturation. Sector/subsector
    // moves are averages across many stocks and rarely exceed this, so most
    // tiles land inside the gradient instead of clipping to flat gray.
    private static let cap = 3.0

    // Палитра «чёрное с золотом»: нейтральный как чип, зелёный и красный приглушённые.
    private static let neutral = (r: 0x2A / 255.0, g: 0x27 / 255.0, b: 0x30 / 255.0)
    private static let positive = (r: 0x36 / 255.0, g: 0x8C / 255.0, b: 0x56 / 255.0)
    private static let negative = (r: 0xB4 / 255.0, g: 0x4A / 255.0, b: 0x40 / 255.0)

    /// Цвет текста на плитках.
    static let tileText = Theme.text

    static func color(for changePercent: Double?) -> Color {
        guard let change = changePercent else {
            return Color(red: neutral.r, green: neutral.g, blue: neutral.b)
        }
        let t = max(-1.0, min(1.0, change / cap))
        let target = t >= 0 ? positive : negative
        let f = abs(t)
        return Color(
            red: neutral.r + (target.r - neutral.r) * f,
            green: neutral.g + (target.g - neutral.g) * f,
            blue: neutral.b + (target.b - neutral.b) * f
        )
    }
}
