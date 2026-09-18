import Foundation
import SwiftUI

// Сектор
struct Sector: Identifiable, Codable {
    let id: String
    let name: String
    var subsectors: [Subsector]
}

// Подсектор
struct Subsector: Identifiable, Codable {
    let id: String
    let name: String
    var companies: [Company]
}

// Компания
struct Company: Identifiable, Codable {
    let ticker: String
    let name: String
    let marketCap: Double
    let description: String?      // текстовое описание компании
    let peRatio: Double?          // P/E коэффициент (опционально)
    let volume: Double?           // объём торгов (опционально)
    
    var id: String { ticker }
    
    var currentPrice: Double?
    var changePercent: Double?
    
    var tileColor: Color {
        guard let change = changePercent else { return Color.gray }
        if change > 3.0 { return Color.green }
        if change > 0.5 { return Color(red: 0.55, green: 0.76, blue: 0.29) }
        if change < -3.0 { return Color.red }
        if change < -0.5 { return Color(red: 1.0, green: 0.54, blue: 0.40) }
        return Color.gray
    }
}
