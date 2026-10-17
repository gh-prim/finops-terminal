import Charts
import FinopsCore
import SwiftUI

/// Price chart with candles, volume, overlays, studies and comparison. Every
/// option lives in `ChartConfig`, which round-trips through the panel's args.
struct ChartView: View {
    let client: DataClient
    let security: String
    let config: ChartConfig
    let onChange: (ChartConfig) -> Void
    let onError: (Error) -> Void

    @State private var main: History?
    @State private var compares: [History] = []
    @State private var failure: String?
    @State private var hovered: Int?
    @State private var compareInput = ""
    /// Bars updated from the live quote stream (nil until the first tick).
    @State private var liveBars: [Bar]?
    @State private var lastTick: Date?

    private var comparing: Bool { !config.compare.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar
            if let failure {
                StatusMessage(title: "Couldn't chart \(security)", detail: failure, isError: true)
                Spacer()
            } else if let main, main.bars.count > 1 {
                if comparing {
                    CompareChart(series: [main] + compares, security: security)
                } else {
                    let bars = liveBars ?? main.bars
                    header(bars)
                    if main.range != config.range.rawValue, let interval = config.interval {
                        Text("Yahoo serves \(interval.label) bars for \(main.range) at most — range limited.")
                            .font(.terminalSmall).foregroundStyle(Palette.muted)
                    }
                    charts(bars, interval: main.interval)
                }
            } else if main != nil {
                StatusMessage(title: "Not enough data for \(security)", detail: "Try a longer range.")
                Spacer()
            } else {
                ProgressView().controlSize(.small)
                Spacer()
            }
            rangeBar
        }
        .padding(12)
        .task { await load() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button("AUTO") { update { $0.interval = nil } }
                    .buttonStyle(TerminalButtonStyle(selected: config.interval == nil))
                    .help("Bar size chosen from the range")
                    .disabled(comparing)
                ForEach(ChartConfig.Interval.allCases, id: \.self) { interval in
                    Button(interval.label) { update { $0.interval = interval } }
                        .buttonStyle(TerminalButtonStyle(selected: config.interval == interval))
                        .help("\(interval.label) bars — or type CHART \(interval.rawValue)")
                        .disabled(comparing)
                }
                divider
                ForEach(ChartConfig.Style.allCases, id: \.self) { style in
                    Button(style.rawValue) { update { $0.style = style } }
                        .buttonStyle(TerminalButtonStyle(selected: config.style == style))
                        .disabled(comparing)
                }
                divider
                toggle("VOL", on: config.volume) { $0.volume.toggle() }
                ForEach(ChartConfig.Overlay.allCases, id: \.self) { overlay in
                    toggle(overlay.rawValue, on: config.overlays.contains(overlay)) { c in
                        if let i = c.overlays.firstIndex(of: overlay) { c.overlays.remove(at: i) } else { c.overlays.append(overlay) }
                    }
                    .foregroundStyle(OverlayColor.color(overlay))
                }
                divider
                ForEach(ChartConfig.Study.allCases, id: \.self) { study in
                    toggle(study.rawValue, on: config.studies.contains(study)) { c in
                        if let i = c.studies.firstIndex(of: study) { c.studies.remove(at: i) } else { c.studies.append(study) }
                    }
                }
                divider
                Text("VS").font(.terminalLabel).foregroundStyle(Palette.muted)
                ForEach(config.compare, id: \.self) { symbol in
                    Button { update { $0.compare.removeAll { $0 == symbol } } } label: {
                        HStack(spacing: 3) { Text(symbol); Image(systemName: "xmark") }
                    }
                    .buttonStyle(TerminalButtonStyle(selected: true))
                    .help("Remove \(symbol) from comparison")
                }
                TextField("compare: MSFT, ^GSPC", text: $compareInput)
                    .textFieldStyle(.plain)
                    .font(.terminalSmall)
                    .frame(width: 150)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Palette.background, in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Palette.border))
                    .onSubmit(addCompare)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Palette.border).frame(width: 1, height: 16).padding(.horizontal, 4)
    }

    private func toggle(_ label: String, on: Bool, _ change: @escaping (inout ChartConfig) -> Void) -> some View {
        Button(label) { update(change) }
            .buttonStyle(TerminalButtonStyle(selected: on))
            .disabled(comparing)
            .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var rangeBar: some View {
        HStack(spacing: 4) {
            ForEach(Array(ChartRange.allCases.enumerated()), id: \.element) { index, range in
                Button(range.rawValue) { update { $0.range = range } }
                    .buttonStyle(TerminalButtonStyle(selected: effectiveRange == range))
                    .help("Range \(range.rawValue) — or type \(index + 1) ⏎")
            }
            Spacer()
        }
    }

    /// The range actually shown (Yahoo may cap it for fine intervals).
    private var effectiveRange: ChartRange {
        main.flatMap { ChartRange(rawValue: $0.range) } ?? config.range
    }

    private func update(_ change: (inout ChartConfig) -> Void) {
        var next = config
        change(&next)
        onChange(next)
    }

    private func addCompare() {
        let symbols = compareInput.uppercased()
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map(String.init)
        compareInput = ""
        guard !symbols.isEmpty else { return }
        update { c in
            for s in symbols where !c.compare.contains(s) { c.compare.append(s) }
        }
    }

    // MARK: Header

    private func header(_ bars: [Bar]) -> some View {
        let index = hovered.map { min(max($0, 0), bars.count - 1) } ?? bars.count - 1
        let bar = bars[index]
        let first = bars[0].c
        let change = bar.c - first
        let intraday = (main?.intervalSeconds ?? 86400) < 86400
        let live = lastTick.map { Date.now.timeIntervalSince($0) < 30 } ?? false
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(main?.security.typed ?? security).foregroundStyle(Palette.accent)
            Text(ChartConfig.Interval(rawValue: main?.interval ?? "")?.label ?? main?.interval ?? "")
                .font(.terminalSmall).foregroundStyle(Palette.muted)
            if live {
                HStack(spacing: 3) {
                    Circle().fill(Heat.up).frame(width: 6, height: 6)
                    Text("LIVE").font(.terminalLabel)
                }
                .foregroundStyle(Heat.up)
                .help("Last candle updates from the quote stream (~5 s; Yahoo data may be delayed for some exchanges)")
            }
            Text(Format.price(bar.c)).font(.title3.monospaced()).monospacedDigit()
            Text(Format.signed(change)).foregroundStyle(Palette.direction(change))
            Text(Format.percent(change / first * 100)).foregroundStyle(Palette.direction(change))
            Group {
                Text("O \(Format.price(bar.o))")
                Text("H \(Format.price(bar.h))")
                Text("L \(Format.price(bar.l))")
                Text("V \(Format.compact(bar.v))")
            }
            .font(.terminalSmall)
            .foregroundStyle(Palette.muted)
            Spacer()
            Text(bar.date.formatted(date: .abbreviated, time: intraday ? .shortened : .omitted))
                .foregroundStyle(Palette.muted)
        }
        .monospacedDigit()
    }

    // MARK: Charts

    /// TradingView-style candle colours.
    private enum Candle {
        static let up = Color(red: 0.149, green: 0.651, blue: 0.604)    // #26A69A
        static let down = Color(red: 0.937, green: 0.325, blue: 0.314)  // #EF5350
        static let halfWidth = 0.36                                     // body = 72% of a bar slot

        static func color(_ bar: Bar) -> Color { bar.c >= (bar.o ?? bar.c) ? up : down }
    }

    /// Bars are placed at x = index (no weekend gaps). The domain leaves half a slot on the
    /// left and a little air on the right, like TradingView.
    private func xDomain(_ count: Int) -> ClosedRange<Double> {
        -0.6...(Double(count) - 1 + max(4, Double(count) * 0.06))
    }

    @ViewBuilder
    private func charts(_ bars: [Bar], interval: String) -> some View {
        let closes = bars.map(\.c)
        let domain = xDomain(bars.count)
        let ticks = tickIndices(count: bars.count)
        let lowest = !config.volume && config.studies.isEmpty

        VStack(spacing: 4) {
            priceChart(bars, closes: closes)
                .chartXScale(domain: domain)
                .chartXAxis { xAxis(bars, ticks: ticks, labels: lowest) }
                .frame(minHeight: 180)
            if config.volume {
                Chart {
                    ForEach(bars.indices, id: \.self) { i in
                        RectangleMark(xStart: .value("x0", Double(i) - Candle.halfWidth),
                                      xEnd: .value("x1", Double(i) + Candle.halfWidth),
                                      yStart: .value("Zero", 0.0), yEnd: .value("Volume", bars[i].v ?? 0))
                            .foregroundStyle(Candle.color(bars[i]).opacity(0.5))
                    }
                    crosshairX
                }
                .chartXScale(domain: domain)
                .chartXAxis { xAxis(bars, ticks: ticks, labels: config.studies.isEmpty) }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { _ in
                        AxisGridLine().foregroundStyle(Palette.border)
                        AxisValueLabel(format: FloatingPointFormatStyle<Double>.number.notation(.compactName))
                    }
                }
                .frame(height: 64)
            }
            ForEach(config.studies, id: \.self) { study in
                studyChart(study, bars: bars, last: study == config.studies.last)
                    .chartXScale(domain: domain)
                    .chartXAxis { xAxis(bars, ticks: ticks, labels: study == config.studies.last) }
                    .frame(height: 80)
            }
        }
        .chartOverlay { proxy in hoverOverlay(proxy, count: bars.count) }
    }

    private func priceChart(_ bars: [Bar], closes: [Double]) -> some View {
        let candles = config.style == .candle
        let rising = closes.last! >= closes.first!
        let lineColor = rising ? Palette.up : Palette.down
        var low = bars.map { candles ? ($0.l ?? $0.c) : $0.c }.min()!
        var high = bars.map { candles ? ($0.h ?? $0.c) : $0.c }.max()!
        let overlays = overlaySeries(closes)
        for s in overlays { for (_, v) in s.points { low = min(low, v); high = max(high, v) } }
        let pad = max((high - low) * 0.06, high * 0.001)
        let minBody = (high - low) * 0.0015  // dojis stay visible
        let last = bars.last!
        let lastColor = candles ? Candle.color(last) : lineColor

        return Chart {
            if candles {
                ForEach(bars.indices, id: \.self) { i in
                    let b = bars[i]
                    let open = b.o ?? b.c
                    let color = Candle.color(b)
                    let mid = (open + b.c) / 2
                    let half = max(abs(b.c - open), minBody) / 2
                    RuleMark(x: .value("x", Double(i)),
                             yStart: .value("Low", b.l ?? min(open, b.c)), yEnd: .value("High", b.h ?? max(open, b.c)))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .foregroundStyle(color)
                    RectangleMark(xStart: .value("x0", Double(i) - Candle.halfWidth),
                                  xEnd: .value("x1", Double(i) + Candle.halfWidth),
                                  yStart: .value("Body low", mid - half), yEnd: .value("Body high", mid + half))
                        .foregroundStyle(color)
                }
            } else {
                ForEach(bars.indices, id: \.self) { i in
                    AreaMark(x: .value("x", Double(i)), yStart: .value("Floor", low - pad), yEnd: .value("Close", bars[i].c),
                             series: .value("Series", "area"))
                        .foregroundStyle(LinearGradient(colors: [lineColor.opacity(0.22), lineColor.opacity(0)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("x", Double(i)), y: .value("Close", bars[i].c), series: .value("Series", "price"))
                        .foregroundStyle(lineColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                }
            }
            ForEach(overlays) { series in
                ForEach(series.points, id: \.0) { i, v in
                    LineMark(x: .value("x", Double(i)), y: .value(series.name, v), series: .value("Series", series.name))
                        .foregroundStyle(series.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.2, dash: series.dashed ? [3, 3] : []))
                }
            }

            // Last price: dashed line across the pane, value tag on the right edge.
            RuleMark(y: .value("Last", last.c))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                .foregroundStyle(lastColor.opacity(0.8))
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    priceTag(last.c, color: lastColor)
                }

            // Crosshair.
            crosshairX
            if let hovered, hovered < bars.count {
                RuleMark(y: .value("Hover", bars[hovered].c))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Palette.muted.opacity(0.7))
                    .annotation(position: .overlay, alignment: .leading, spacing: 0) {
                        priceTag(bars[hovered].c, color: Palette.raised)
                    }
            }
        }
        .chartYScale(domain: (low - pad)...(high + pad))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine().foregroundStyle(Palette.border)
                AxisValueLabel()
            }
        }
        .chartLegend(.hidden)
        .accessibilityLabel("Price chart for \(security), \(config.range.rawValue)")
    }

    private func priceTag(_ value: Double, color: Color) -> some View {
        Text(Format.price(value))
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color, in: RoundedRectangle(cornerRadius: 2))
    }

    @ChartContentBuilder
    private var crosshairX: some ChartContent {
        if let hovered {
            RuleMark(x: .value("x", Double(hovered)))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(Palette.muted.opacity(0.7))
        }
    }

    @ViewBuilder
    private func studyChart(_ study: ChartConfig.Study, bars: [Bar], last: Bool) -> some View {
        let closes = bars.map(\.c)
        let highs = bars.map { $0.h ?? $0.c }, lows = bars.map { $0.l ?? $0.c }
        let at = hovered ?? (closes.count - 1)
        switch study {
        case .stoch:
            let s = Indicators.stochastic(high: highs, low: lows, close: closes)
            Chart {
                RuleMark(y: .value("Hi", 80)).foregroundStyle(Palette.muted.opacity(0.5)).lineStyle(StrokeStyle(dash: [3, 3]))
                RuleMark(y: .value("Lo", 20)).foregroundStyle(Palette.muted.opacity(0.5)).lineStyle(StrokeStyle(dash: [3, 3]))
                ForEach(points(s.k), id: \.0) { i, v in
                    LineMark(x: .value("x", Double(i)), y: .value("%K", v), series: .value("S", "k")).foregroundStyle(Color(red: 0.16, green: 0.47, blue: 1.0))
                }
                ForEach(points(s.d), id: \.0) { i, v in
                    LineMark(x: .value("x", Double(i)), y: .value("%D", v), series: .value("S", "d")).foregroundStyle(Palette.accent)
                }
                crosshairX
            }
            .chartYScale(domain: 0...100)
            .chartYAxis { AxisMarks(position: .trailing, values: [20, 80]) }
            .overlay(alignment: .topLeading) { studyLabel("STOCH 14,3,3", value: s.k[at]) }
        case .atr:
            single("ATR 14", Indicators.atr(high: highs, low: lows, close: closes), at: at, color: Color(red: 0.95, green: 0.55, blue: 0.25))
        case .obv:
            single("OBV", Indicators.obv(close: closes, volume: bars.map { $0.v ?? 0 }), at: at, color: Color(red: 0.30, green: 0.85, blue: 0.85))
        case .adx:
            Chart {
                RuleMark(y: .value("Trend", 25)).foregroundStyle(Palette.muted.opacity(0.5)).lineStyle(StrokeStyle(dash: [3, 3]))
                ForEach(points(Indicators.adx(high: highs, low: lows, close: closes)), id: \.0) { i, v in
                    LineMark(x: .value("x", Double(i)), y: .value("ADX", v)).foregroundStyle(Color(red: 0.95, green: 0.85, blue: 0.35))
                }
                crosshairX
            }
            .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
            .overlay(alignment: .topLeading) { studyLabel("ADX 14", value: Indicators.adx(high: highs, low: lows, close: closes)[at]) }
        case .rsi:
            let rsi = Indicators.rsi(closes)
            Chart {
                RectangleMark(yStart: .value("Lo", 30.0), yEnd: .value("Hi", 70.0))
                    .foregroundStyle(Color(red: 0.5, green: 0.4, blue: 0.9).opacity(0.07))
                RuleMark(y: .value("Overbought", 70)).foregroundStyle(Palette.muted.opacity(0.5)).lineStyle(StrokeStyle(dash: [3, 3]))
                RuleMark(y: .value("Oversold", 30)).foregroundStyle(Palette.muted.opacity(0.5)).lineStyle(StrokeStyle(dash: [3, 3]))
                ForEach(points(rsi), id: \.0) { i, v in
                    LineMark(x: .value("x", Double(i)), y: .value("RSI", v))
                        .foregroundStyle(Color(red: 0.62, green: 0.48, blue: 0.95))
                        .lineStyle(StrokeStyle(lineWidth: 1.3))
                }
                crosshairX
            }
            .chartYScale(domain: 0...100)
            .chartYAxis { AxisMarks(position: .trailing, values: [30, 70]) }
            .overlay(alignment: .topLeading) { studyLabel("RSI 14", value: rsi[hovered ?? (closes.count - 1)]) }
        case .macd:
            let m = Indicators.macd(closes)
            Chart {
                ForEach(points(m.histogram), id: \.0) { i, v in
                    RectangleMark(xStart: .value("x0", Double(i) - Candle.halfWidth),
                                  xEnd: .value("x1", Double(i) + Candle.halfWidth),
                                  yStart: .value("Zero", 0.0), yEnd: .value("Hist", v))
                        .foregroundStyle((v >= 0 ? Candle.up : Candle.down).opacity(0.55))
                }
                ForEach(points(m.macd), id: \.0) { i, v in
                    LineMark(x: .value("x", Double(i)), y: .value("MACD", v), series: .value("S", "macd"))
                        .foregroundStyle(Color(red: 0.16, green: 0.47, blue: 1.0))
                }
                ForEach(points(m.signal), id: \.0) { i, v in
                    LineMark(x: .value("x", Double(i)), y: .value("Signal", v), series: .value("S", "signal"))
                        .foregroundStyle(Palette.accent)
                }
                crosshairX
            }
            .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
            .overlay(alignment: .topLeading) { studyLabel("MACD 12/26/9", value: m.macd[hovered ?? (closes.count - 1)]) }
        }
    }

    private func single(_ title: String, _ values: [Double?], at: Int, color: Color) -> some View {
        Chart {
            ForEach(points(values), id: \.0) { i, v in
                LineMark(x: .value("x", Double(i)), y: .value(title, v)).foregroundStyle(color)
            }
            crosshairX
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: FloatingPointFormatStyle<Double>.number.notation(.compactName))
            }
        }
        .overlay(alignment: .topLeading) { studyLabel(title, value: values[at]) }
    }

    private func studyLabel(_ title: String, value: Double?) -> some View {
        Text("\(title)  \(Format.number(value))").font(.terminalLabel).foregroundStyle(Palette.muted).padding(4)
    }

    private func xAxis(_ bars: [Bar], ticks: [Double], labels: Bool) -> some AxisContent {
        AxisMarks(values: ticks) { value in
            AxisGridLine().foregroundStyle(Palette.border)
            if labels, let x = value.as(Double.self), Int(x) < bars.count {
                AxisValueLabel { Text(axisLabel(bars[Int(x)].date)) }
            }
        }
    }

    private func axisLabel(_ date: Date) -> String {
        let step = main?.intervalSeconds ?? 86400
        switch effectiveRange {
        case .d1: return date.formatted(date: .omitted, time: .shortened)
        case .d5 where step < 86400, .m1 where step < 3600:
            return date.formatted(.dateTime.weekday(.abbreviated).day().hour().minute())
        case .d5, .m1: return date.formatted(.dateTime.month(.abbreviated).day())
        case .m3, .m6, .ytd, .y1: return date.formatted(.dateTime.month(.abbreviated).day())
        default: return date.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
        }
    }

    private func tickIndices(count: Int) -> [Double] {
        let n = 7
        guard count > n else { return (0..<count).map(Double.init) }
        return (0..<n).map { Double($0 * (count - 1) / (n - 1)) }
    }

    private func hoverOverlay(_ proxy: ChartProxy, count: Int) -> some View {
        GeometryReader { geometry in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard let plot = proxy.plotFrame else { return }
                        let x = location.x - geometry[plot].origin.x
                        if let v: Double = proxy.value(atX: x) {
                            hovered = min(max(Int(v.rounded()), 0), count - 1)  // snap to the nearest bar
                        }
                    case .ended:
                        hovered = nil
                    }
                }
        }
    }

    // MARK: Data

    private struct OverlaySeries: Identifiable {
        let name: String
        let color: Color
        let dashed: Bool
        let points: [(Int, Double)]
        var id: String { name }
    }

    private func points(_ values: [Double?]) -> [(Int, Double)] {
        values.enumerated().compactMap { i, v in v.map { (i, $0) } }
    }

    private func overlaySeries(_ closes: [Double]) -> [OverlaySeries] {
        config.overlays.flatMap { overlay -> [OverlaySeries] in
            let color = OverlayColor.color(overlay)
            switch overlay {
            case .sma20: return [OverlaySeries(name: "SMA20", color: color, dashed: false, points: points(Indicators.sma(closes, period: 20)))]
            case .sma50: return [OverlaySeries(name: "SMA50", color: color, dashed: false, points: points(Indicators.sma(closes, period: 50)))]
            case .sma200: return [OverlaySeries(name: "SMA200", color: color, dashed: false, points: points(Indicators.sma(closes, period: 200)))]
            case .ema20: return [OverlaySeries(name: "EMA20", color: color, dashed: false, points: points(Indicators.ema(closes, period: 20)))]
            case .bollinger:
                let b = Indicators.bollinger(closes)
                return [OverlaySeries(name: "BB upper", color: color, dashed: true, points: points(b.upper)),
                        OverlaySeries(name: "BB mid", color: color.opacity(0.6), dashed: true, points: points(b.middle)),
                        OverlaySeries(name: "BB lower", color: color, dashed: true, points: points(b.lower))]
            }
        }
    }

    private func load() async {
        do {
            main = try await client.history(security, range: config.range, interval: config.interval)
        } catch {
            failure = error.localizedDescription
            onError(error)
            return
        }
        var loaded: [History] = []
        for symbol in config.compare {
            do { loaded.append(try await client.history(symbol, range: config.range)) }
            catch { onError(error) }
        }
        compares = loaded
        if !comparing { await streamLastBar() }
    }

    /// Keep the last candle live: update its close/high/low on each tick, and open a new candle
    /// when an intraday interval rolls over (only when the price actually moves, so closed
    /// markets don't grow flat bars).
    private func streamLastBar() async {
        guard let main, let step = main.intervalSeconds else { return }
        for await event in await client.subscribe(security) {
            guard case .tick(let quote) = event else { continue }
            var bars = liveBars ?? main.bars
            guard let last = bars.last else { continue }
            let price = quote.last
            if step < 86400, quote.asOf >= last.t + step, price != last.c {
                let start = last.t + ((quote.asOf - last.t) / step).rounded(.down) * step
                bars.append(Bar(t: start, o: price, h: price, l: price, c: price, v: 0))
            } else {
                bars[bars.count - 1] = Bar(t: last.t, o: last.o, h: max(last.h ?? price, price),
                                           l: min(last.l ?? price, price), c: price, v: last.v)
            }
            liveBars = bars
            lastTick = .now
        }
    }
}

enum OverlayColor {
    static func color(_ overlay: ChartConfig.Overlay) -> Color {
        switch overlay {
        case .sma20: Color(red: 0.35, green: 0.65, blue: 1.0)
        case .sma50: Palette.accent
        case .sma200: Color(red: 0.80, green: 0.45, blue: 1.0)
        case .ema20: Color(red: 0.30, green: 0.85, blue: 0.85)
        case .bollinger: Color(red: 0.70, green: 0.70, blue: 0.72)
        }
    }
}

/// Several securities rebased to % change from the first bar.
private struct CompareChart: View {
    let series: [History]
    let security: String

    private static let colors: [Color] = [
        Palette.accent, Color(red: 0.35, green: 0.65, blue: 1.0), Color(red: 0.80, green: 0.45, blue: 1.0),
        Color(red: 0.30, green: 0.85, blue: 0.85), Color(red: 1.0, green: 0.45, blue: 0.6), Palette.up,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                ForEach(Array(series.enumerated()), id: \.offset) { i, h in
                    let change = rebased(h).last?.1 ?? 0
                    HStack(spacing: 5) {
                        Circle().fill(Self.colors[i % Self.colors.count]).frame(width: 8, height: 8)
                        Text(h.security.typed)
                        Text(Format.percent(change)).foregroundStyle(Palette.direction(change))
                    }
                }
            }
            .monospacedDigit()
            Chart {
                RuleMark(y: .value("Zero", 0)).foregroundStyle(Palette.muted.opacity(0.4))
                ForEach(Array(series.enumerated()), id: \.offset) { i, h in
                    ForEach(rebased(h), id: \.0) { date, pct in
                        LineMark(x: .value("Date", date), y: .value("%", pct), series: .value("Security", h.security.typed))
                            .foregroundStyle(Self.colors[i % Self.colors.count])
                            .lineStyle(StrokeStyle(lineWidth: i == 0 ? 1.8 : 1.2))
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisGridLine().foregroundStyle(Palette.border)
                    AxisValueLabel { Text("\(value.as(Double.self).map { Format.number($0, digits: 0) } ?? "")%") }
                }
            }
            .chartLegend(.hidden)
            .accessibilityLabel("Comparison chart, percent change")
        }
    }

    private func rebased(_ h: History) -> [(Date, Double)] {
        guard let first = h.bars.first?.c, first != 0 else { return [] }
        return h.bars.map { ($0.date, ($0.c / first - 1) * 100) }
    }
}
