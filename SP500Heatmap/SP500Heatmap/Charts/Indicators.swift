import Foundation

/// Технические индикаторы: чистые функции без UI. Результат того же размера, что вход;
/// там, где значения ещё нет (мало данных), стоит nil.
enum Indicators {
    /// Простая скользящая средняя за `period` значений.
    static func sma(_ values: [Double], period: Int) -> [Double?] {
        guard period > 0 else { return Array(repeating: nil, count: values.count) }
        var result = [Double?](repeating: nil, count: values.count)
        var sum = 0.0
        for i in values.indices {
            sum += values[i]
            if i >= period { sum -= values[i - period] }
            if i >= period - 1 { result[i] = sum / Double(period) }
        }
        return result
    }

    /// Экспоненциальная средняя: первое значение — SMA первых `period`, дальше k = 2/(period+1).
    static func ema(_ values: [Double], period: Int) -> [Double?] {
        var result = [Double?](repeating: nil, count: values.count)
        guard period > 0, values.count >= period else { return result }
        let k = 2.0 / Double(period + 1)
        var prev = values[0..<period].reduce(0, +) / Double(period)
        result[period - 1] = prev
        if values.count > period {
            for i in period..<values.count {
                prev = values[i] * k + prev * (1 - k)
                result[i] = prev
            }
        }
        return result
    }

    /// RSI по Уайлдеру (сглаживание 1/period). Первое значение — на индексе `period`.
    static func rsi(_ values: [Double], period: Int = 14) -> [Double?] {
        var result = [Double?](repeating: nil, count: values.count)
        guard period > 0, values.count > period else { return result }
        var gain = 0.0, loss = 0.0
        for i in 1...period {
            let d = values[i] - values[i - 1]
            if d >= 0 { gain += d } else { loss -= d }
        }
        var avgGain = gain / Double(period)
        var avgLoss = loss / Double(period)
        result[period] = rsiValue(avgGain, avgLoss)
        if values.count > period + 1 {
            for i in (period + 1)..<values.count {
                let d = values[i] - values[i - 1]
                avgGain = (avgGain * Double(period - 1) + max(d, 0)) / Double(period)
                avgLoss = (avgLoss * Double(period - 1) + max(-d, 0)) / Double(period)
                result[i] = rsiValue(avgGain, avgLoss)
            }
        }
        return result
    }

    private static func rsiValue(_ gain: Double, _ loss: Double) -> Double {
        if loss == 0 { return gain == 0 ? 50 : 100 }
        return 100 - 100 / (1 + gain / loss)
    }

    struct MACDPoint { let macd: Double; let signal: Double?; let histogram: Double? }

    /// MACD(fast, slow, signal): линия = EMA(fast) − EMA(slow), сигнал = EMA линии, гистограмма = линия − сигнал.
    static func macd(_ values: [Double], fast: Int = 12, slow: Int = 26, signal: Int = 9) -> [MACDPoint?] {
        let fastEMA = ema(values, period: fast)
        let slowEMA = ema(values, period: slow)
        var line = [Double?](repeating: nil, count: values.count)
        for i in values.indices {
            if let f = fastEMA[i], let s = slowEMA[i] { line[i] = f - s }
        }
        guard let first = line.firstIndex(where: { $0 != nil }) else {
            return [MACDPoint?](repeating: nil, count: values.count)
        }
        let defined = line[first...].compactMap { $0 }
        let sig = ema(defined, period: signal)
        var result = [MACDPoint?](repeating: nil, count: values.count)
        for (offset, m) in defined.enumerated() {
            let s = sig[offset]
            result[first + offset] = MACDPoint(macd: m, signal: s, histogram: s.map { m - $0 })
        }
        return result
    }
}
