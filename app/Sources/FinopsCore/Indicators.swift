import Foundation

/// Technical indicators over a close series. Outputs align with the input;
/// positions without enough history are nil.
public enum Indicators {
    public static func sma(_ values: [Double], period: Int) -> [Double?] {
        guard period > 0 else { return values.map { _ in nil } }
        var out = [Double?](repeating: nil, count: values.count)
        var sum = 0.0
        for i in values.indices {
            sum += values[i]
            if i >= period { sum -= values[i - period] }
            if i >= period - 1 { out[i] = sum / Double(period) }
        }
        return out
    }

    public static func ema(_ values: [Double], period: Int) -> [Double?] {
        guard period > 0, values.count >= period else { return values.map { _ in nil } }
        var out = [Double?](repeating: nil, count: values.count)
        let k = 2.0 / Double(period + 1)
        var prev = values[0..<period].reduce(0, +) / Double(period)
        out[period - 1] = prev
        for i in period..<values.count {
            prev = values[i] * k + prev * (1 - k)
            out[i] = prev
        }
        return out
    }

    /// Wilder's RSI.
    public static func rsi(_ values: [Double], period: Int = 14) -> [Double?] {
        guard values.count > period else { return values.map { _ in nil } }
        var out = [Double?](repeating: nil, count: values.count)
        var gain = 0.0, loss = 0.0
        for i in 1...period {
            let d = values[i] - values[i - 1]
            gain += max(d, 0)
            loss += max(-d, 0)
        }
        gain /= Double(period)
        loss /= Double(period)
        out[period] = loss == 0 ? 100 : 100 - 100 / (1 + gain / loss)
        for i in (period + 1)..<values.count {
            let d = values[i] - values[i - 1]
            gain = (gain * Double(period - 1) + max(d, 0)) / Double(period)
            loss = (loss * Double(period - 1) + max(-d, 0)) / Double(period)
            out[i] = loss == 0 ? 100 : 100 - 100 / (1 + gain / loss)
        }
        return out
    }

    public struct MACD: Sendable {
        public let macd: [Double?]
        public let signal: [Double?]
        public let histogram: [Double?]
    }

    public static func macd(_ values: [Double], fast: Int = 12, slow: Int = 26, signal: Int = 9) -> MACD {
        let f = ema(values, period: fast), s = ema(values, period: slow)
        let line: [Double?] = zip(f, s).map { a, b in a.flatMap { a in b.map { a - $0 } } }
        let firstIndex = line.firstIndex { $0 != nil } ?? line.count
        var sig = [Double?](repeating: nil, count: values.count)
        let compact = line[firstIndex...].compactMap { $0 }
        for (offset, v) in ema(compact, period: signal).enumerated() {
            sig[firstIndex + offset] = v
        }
        let hist: [Double?] = zip(line, sig).map { a, b in a.flatMap { a in b.map { a - $0 } } }
        return MACD(macd: line, signal: sig, histogram: hist)
    }

    public struct Bands: Sendable {
        public let middle: [Double?]
        public let upper: [Double?]
        public let lower: [Double?]
    }

    public static func bollinger(_ values: [Double], period: Int = 20, k: Double = 2) -> Bands {
        let mid = sma(values, period: period)
        var upper = [Double?](repeating: nil, count: values.count)
        var lower = upper
        for i in values.indices {
            guard let m = mid[i] else { continue }
            let window = values[(i - period + 1)...i]
            let sd = (window.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(period)).squareRoot()
            upper[i] = m + k * sd
            lower[i] = m - k * sd
        }
        return Bands(middle: mid, upper: upper, lower: lower)
    }
}

public extension Indicators {
    /// Stochastic oscillator %K (smoothed over `smooth`) and %D.
    static func stochastic(high: [Double], low: [Double], close: [Double], period: Int = 14, smooth: Int = 3,
                           signal: Int = 3) -> (k: [Double?], d: [Double?]) {
        let n = close.count
        var raw = [Double?](repeating: nil, count: n)
        for i in 0..<n where i >= period - 1 {
            let hh = high[(i - period + 1)...i].max()!, ll = low[(i - period + 1)...i].min()!
            raw[i] = hh == ll ? 50 : (close[i] - ll) / (hh - ll) * 100
        }
        let k = smoothOptional(raw, smooth)
        return (k, smoothOptional(k, signal))
    }

    /// Wilder's Average True Range.
    static func atr(high: [Double], low: [Double], close: [Double], period: Int = 14) -> [Double?] {
        let n = close.count
        guard n > period else { return Array(repeating: nil, count: n) }
        var tr = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let hl = high[i] - low[i]
            tr[i] = i == 0 ? hl : max(hl, abs(high[i] - close[i - 1]), abs(low[i] - close[i - 1]))
        }
        var out = [Double?](repeating: nil, count: n)
        var prev = tr[1...period].reduce(0, +) / Double(period)
        out[period] = prev
        for i in (period + 1)..<n {
            prev = (prev * Double(period - 1) + tr[i]) / Double(period)
            out[i] = prev
        }
        return out
    }

    /// On-balance volume.
    static func obv(close: [Double], volume: [Double]) -> [Double?] {
        var total = 0.0
        return close.indices.map { i in
            if i > 0 { total += close[i] > close[i - 1] ? volume[i] : (close[i] < close[i - 1] ? -volume[i] : 0) }
            return total
        }
    }

    /// Average Directional Index (Wilder).
    static func adx(high: [Double], low: [Double], close: [Double], period: Int = 14) -> [Double?] {
        let n = close.count
        guard n > period * 2 else { return Array(repeating: nil, count: n) }
        var tr = [Double](repeating: 0, count: n), plus = tr, minus = tr
        for i in 1..<n {
            let up = high[i] - high[i - 1], down = low[i - 1] - low[i]
            plus[i] = up > down && up > 0 ? up : 0
            minus[i] = down > up && down > 0 ? down : 0
            tr[i] = max(high[i] - low[i], abs(high[i] - close[i - 1]), abs(low[i] - close[i - 1]))
        }
        var sTR = tr[1...period].reduce(0, +), sP = plus[1...period].reduce(0, +), sM = minus[1...period].reduce(0, +)
        var dx = [Double?](repeating: nil, count: n)
        for i in period..<n {
            if i > period {
                sTR = sTR - sTR / Double(period) + tr[i]
                sP = sP - sP / Double(period) + plus[i]
                sM = sM - sM / Double(period) + minus[i]
            }
            let pdi = sTR == 0 ? 0 : sP / sTR * 100, mdi = sTR == 0 ? 0 : sM / sTR * 100
            dx[i] = pdi + mdi == 0 ? 0 : abs(pdi - mdi) / (pdi + mdi) * 100
        }
        var out = [Double?](repeating: nil, count: n)
        let start = period * 2 - 1
        var prev = dx[period...start].compactMap { $0 }.reduce(0, +) / Double(period)
        out[start] = prev
        for i in (start + 1)..<n {
            prev = (prev * Double(period - 1) + (dx[i] ?? 0)) / Double(period)
            out[i] = prev
        }
        return out
    }

    private static func smoothOptional(_ values: [Double?], _ period: Int) -> [Double?] {
        values.indices.map { i in
            guard i >= period - 1 else { return nil }
            let window = values[(i - period + 1)...i]
            guard window.allSatisfy({ $0 != nil }) else { return nil }
            return window.compactMap { $0 }.reduce(0, +) / Double(period)
        }
    }
}

/// Chart options, round-tripped through command args so the command line and
/// the toolbar always agree. e.g. `5Y CANDLE VOL SMA50 RSI VS MSFT,NVDA`
public struct ChartConfig: Equatable, Sendable {
    public enum Style: String, CaseIterable, Sendable { case line = "LINE", candle = "CANDLE" }
    public enum Overlay: String, CaseIterable, Sendable {
        case sma20 = "SMA20", sma50 = "SMA50", sma200 = "SMA200", ema20 = "EMA20", bollinger = "BB"
    }
    public enum Study: String, CaseIterable, Sendable {
        case rsi = "RSI", macd = "MACD", stoch = "STOCH", atr = "ATR", obv = "OBV", adx = "ADX"
    }

    /// Bar size. nil = automatic from the range (1D → 5m, 5D → 15m, 1M → 1h, longer → daily/weekly).
    public enum Interval: String, CaseIterable, Sendable {
        case m1 = "1MIN", m5 = "5MIN", m15 = "15MIN", m30 = "30MIN", h1 = "1H", h4 = "4H", d1 = "1DAY", w1 = "1WK"

        public var label: String {
            switch self {
            case .m1: "1m"
            case .m5: "5m"
            case .m15: "15m"
            case .m30: "30m"
            case .h1: "1h"
            case .h4: "4h"
            case .d1: "D"
            case .w1: "W"
            }
        }
    }

    public var range: ChartRange = .y1
    public var interval: Interval?
    public var style: Style = .line
    public var volume = false
    public var overlays: [Overlay] = []
    public var studies: [Study] = []
    public var compare: [String] = []

    public init() {}

    public init(args: [String]) {
        var i = 0
        while i < args.count {
            let token = args[i]
            if let r = ChartRange(rawValue: token) { range = r }
            else if let iv = Interval(rawValue: token) { interval = iv }
            else if let s = Style(rawValue: token) { style = s }
            else if token == "VOL" { volume = true }
            else if let o = Overlay(rawValue: token), !overlays.contains(o) { overlays.append(o) }
            else if let s = Study(rawValue: token), !studies.contains(s) { studies.append(s) }
            else if token == "VS", i + 1 < args.count {
                compare = args[i + 1].split(separator: ",").map(String.init).filter { !$0.isEmpty }
                i += 1
            }
            i += 1
        }
    }

    /// Unknown tokens (anything that isn't an option) for validation messages.
    public static func unknownTokens(in args: [String]) -> [String] {
        var unknown: [String] = []
        var skipNext = false
        for token in args {
            if skipNext { skipNext = false; continue }
            if token == "VS" { skipNext = true; continue }
            if ChartRange(rawValue: token) == nil, Interval(rawValue: token) == nil, Style(rawValue: token) == nil, token != "VOL",
               Overlay(rawValue: token) == nil, Study(rawValue: token) == nil {
                unknown.append(token)
            }
        }
        return unknown
    }

    public var args: [String] {
        var out = [range.rawValue]
        if let interval { out.append(interval.rawValue) }
        if style != .line { out.append(style.rawValue) }
        if volume { out.append("VOL") }
        out += overlays.map(\.rawValue)
        out += studies.map(\.rawValue)
        if !compare.isEmpty { out += ["VS", compare.joined(separator: ",")] }
        return out
    }
}
