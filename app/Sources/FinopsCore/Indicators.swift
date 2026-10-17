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

/// Chart options, round-tripped through command args so the command line and
/// the toolbar always agree. e.g. `5Y CANDLE VOL SMA50 RSI VS MSFT,NVDA`
public struct ChartConfig: Equatable, Sendable {
    public enum Style: String, CaseIterable, Sendable { case line = "LINE", candle = "CANDLE" }
    public enum Overlay: String, CaseIterable, Sendable {
        case sma20 = "SMA20", sma50 = "SMA50", sma200 = "SMA200", ema20 = "EMA20", bollinger = "BB"
    }
    public enum Study: String, CaseIterable, Sendable { case rsi = "RSI", macd = "MACD" }

    public var range: ChartRange = .y1
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
            if ChartRange(rawValue: token) == nil, Style(rawValue: token) == nil, token != "VOL",
               Overlay(rawValue: token) == nil, Study(rawValue: token) == nil {
                unknown.append(token)
            }
        }
        return unknown
    }

    public var args: [String] {
        var out = [range.rawValue]
        if style != .line { out.append(style.rawValue) }
        if volume { out.append("VOL") }
        out += overlays.map(\.rawValue)
        out += studies.map(\.rawValue)
        if !compare.isEmpty { out += ["VS", compare.joined(separator: ",")] }
        return out
    }
}
