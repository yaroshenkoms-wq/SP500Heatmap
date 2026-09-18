import SwiftUI

enum HeatmapColor {
    // % change at which the color reaches full saturation. Sector/subsector
    // moves are averages across many stocks and rarely exceed this, so most
    // tiles land inside the gradient instead of clipping to flat gray.
    private static let cap = 3.0

    private static let neutral = (r: 0.42, g: 0.42, b: 0.45)
    private static let positive = (r: 0.20, g: 0.70, b: 0.32)
    private static let negative = (r: 0.86, g: 0.24, b: 0.24)

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
