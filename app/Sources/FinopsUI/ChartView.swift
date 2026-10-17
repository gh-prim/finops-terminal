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
                    header(main.bars)
                    charts(main.bars, interval: main.interval)
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
                    .buttonStyle(TerminalButtonStyle(selected: config.range == range))
                    .help("Range \(range.rawValue) — or type \(index + 1) ⏎")
            }
            Spacer()
        }
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
        let intraday = (main?.interval ?? "").hasSuffix("m") || (main?.interval ?? "").hasSuffix("h")
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(main?.security.typed ?? security).foregroundStyle(Palette.accent)
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

    @ViewBuilder
    private func charts(_ bars: [Bar], interval: String) -> some View {
        let closes = bars.map(\.c)
        let domain = 0...(bars.count - 1)
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
                        BarMark(x: .value("i", i), y: .value("Volume", bars[i].v ?? 0), width: .ratio(0.8))
                            .foregroundStyle((bars[i].c >= (bars[i].o ?? bars[i].c) ? Palette.up : Palette.down).opacity(0.6))
                    }
                    hoverRule
                }
                .chartXScale(domain: domain)
                .chartXAxis { xAxis(bars, ticks: ticks, labels: config.studies.isEmpty) }
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { _ in AxisValueLabel(format: FloatingPointFormatStyle<Double>.number.notation(.compactName)) } }
                .frame(height: 60)
            }
            ForEach(config.studies, id: \.self) { study in
                studyChart(study, closes: closes, last: study == config.studies.last)
                    .chartXScale(domain: domain)
                    .chartXAxis { xAxis(bars, ticks: ticks, labels: study == config.studies.last) }
                    .frame(height: 80)
            }
        }
        .chartOverlay { proxy in hoverOverlay(proxy, count: bars.count) }
    }

    private func priceChart(_ bars: [Bar], closes: [Double]) -> some View {
        let rising = closes.last! >= closes.first!
        let color = rising ? Palette.up : Palette.down
        let lows = bars.map { config.style == .candle ? ($0.l ?? $0.c) : $0.c }
        let highs = bars.map { config.style == .candle ? ($0.h ?? $0.c) : $0.c }
        var low = lows.min()!, high = highs.max()!
        let overlays = overlaySeries(closes)
        for s in overlays { for (_, v) in s.points { low = min(low, v); high = max(high, v) } }
        let pad = max((high - low) * 0.05, high * 0.001)

        return Chart {
            if config.style == .candle {
                ForEach(bars.indices, id: \.self) { i in
                    let b = bars[i]
                    let up = b.c >= (b.o ?? b.c)
                    RuleMark(x: .value("i", i), yStart: .value("Low", b.l ?? b.c), yEnd: .value("High", b.h ?? b.c))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .foregroundStyle(up ? Palette.up : Palette.down)
                    RectangleMark(x: .value("i", i), yStart: .value("Open", b.o ?? b.c), yEnd: .value("Close", b.c),
                                  width: .ratio(0.7))
                        .foregroundStyle(up ? Palette.up : Palette.down)
                }
            } else {
                ForEach(bars.indices, id: \.self) { i in
                    AreaMark(x: .value("i", i), yStart: .value("Floor", low - pad), yEnd: .value("Close", bars[i].c),
                             series: .value("Series", "area"))
                        .foregroundStyle(LinearGradient(colors: [color.opacity(0.22), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("i", i), y: .value("Close", bars[i].c), series: .value("Series", "price"))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1.4))
                }
            }
            ForEach(overlays) { series in
                ForEach(series.points, id: \.0) { i, v in
                    LineMark(x: .value("i", i), y: .value(series.name, v), series: .value("Series", series.name))
                        .foregroundStyle(series.color)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: series.dashed ? [3, 3] : []))
                }
            }
            hoverRule
            if let hovered, hovered < bars.count {
                PointMark(x: .value("i", hovered), y: .value("Close", bars[hovered].c))
                    .foregroundStyle(color).symbolSize(30)
            }
        }
        .chartYScale(domain: (low - pad)...(high + pad))
        .chartYAxis { AxisMarks(position: .trailing) }
        .chartLegend(.hidden)
        .accessibilityLabel("Price chart for \(security), \(config.range.rawValue)")
    }

    @ChartContentBuilder
    private var hoverRule: some ChartContent {
        if let hovered {
            RuleMark(x: .value("i", hovered)).foregroundStyle(Palette.muted.opacity(0.5))
        }
    }

    @ViewBuilder
    private func studyChart(_ study: ChartConfig.Study, closes: [Double], last: Bool) -> some View {
        switch study {
        case .rsi:
            let rsi = Indicators.rsi(closes)
            Chart {
                RuleMark(y: .value("Overbought", 70)).foregroundStyle(Palette.down.opacity(0.4)).lineStyle(StrokeStyle(dash: [3, 3]))
                RuleMark(y: .value("Oversold", 30)).foregroundStyle(Palette.up.opacity(0.4)).lineStyle(StrokeStyle(dash: [3, 3]))
                ForEach(points(rsi), id: \.0) { i, v in
                    LineMark(x: .value("i", i), y: .value("RSI", v)).foregroundStyle(Palette.accent)
                }
                hoverRule
            }
            .chartYScale(domain: 0...100)
            .chartYAxis { AxisMarks(position: .trailing, values: [30, 70]) }
            .overlay(alignment: .topLeading) { studyLabel("RSI 14", value: rsi[hovered ?? (closes.count - 1)]) }
        case .macd:
            let m = Indicators.macd(closes)
            Chart {
                ForEach(points(m.histogram), id: \.0) { i, v in
                    BarMark(x: .value("i", i), y: .value("Hist", v), width: .ratio(0.8))
                        .foregroundStyle((v >= 0 ? Palette.up : Palette.down).opacity(0.5))
                }
                ForEach(points(m.macd), id: \.0) { i, v in
                    LineMark(x: .value("i", i), y: .value("MACD", v), series: .value("S", "macd")).foregroundStyle(Palette.accent)
                }
                ForEach(points(m.signal), id: \.0) { i, v in
                    LineMark(x: .value("i", i), y: .value("Signal", v), series: .value("S", "signal")).foregroundStyle(Palette.selection)
                }
                hoverRule
            }
            .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
            .overlay(alignment: .topLeading) { studyLabel("MACD 12/26/9", value: m.macd[hovered ?? (closes.count - 1)]) }
        }
    }

    private func studyLabel(_ title: String, value: Double?) -> some View {
        Text("\(title)  \(Format.number(value))").font(.terminalLabel).foregroundStyle(Palette.muted).padding(4)
    }

    private func xAxis(_ bars: [Bar], ticks: [Int], labels: Bool) -> some AxisContent {
        AxisMarks(values: ticks) { value in
            AxisGridLine().foregroundStyle(Palette.border)
            if labels, let i = value.as(Int.self), i < bars.count {
                AxisValueLabel { Text(axisLabel(bars[i].date)) }
            }
        }
    }

    private func axisLabel(_ date: Date) -> String {
        switch config.range {
        case .d1: date.formatted(date: .omitted, time: .shortened)
        case .d5, .m1: date.formatted(.dateTime.month(.abbreviated).day())
        case .m3, .m6, .ytd, .y1: date.formatted(.dateTime.month(.abbreviated))
        default: date.formatted(.dateTime.year())
        }
    }

    private func tickIndices(count: Int) -> [Int] {
        let n = 6
        guard count > n else { return Array(0..<count) }
        return (0..<n).map { $0 * (count - 1) / (n - 1) }
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
                            hovered = min(max(Int(v.rounded()), 0), count - 1)
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
            main = try await client.history(security, range: config.range)
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
