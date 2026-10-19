import Charts
import FinopsCore
import SwiftUI

// MARK: Quotes

/// Big live prices, streamed (sub-second for crypto via Binance, ~5 s for Yahoo).
struct QuotesWidget: View {
    let widget: DashWidget
    let client: DataClient

    @State private var quotes: [String: Quote] = [:]

    var body: some View {
        let columns = max(1, min(widget.securities.count, widget.w >= 6 ? 3 : 2))
        let rows = Int(ceil(Double(widget.securities.count) / Double(columns)))
        GeometryReader { geo in
            let tileH = (geo.size.height - CGFloat(max(rows - 1, 0)) * 6) / CGFloat(max(rows, 1))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
                ForEach(widget.securities, id: \.self) { security in
                    tile(security, quote: quotes[security], height: tileH)
                }
            }
        }
        .task(id: widget.securities) {
            await withTaskGroup(of: Void.self) { group in
                for security in widget.securities {
                    group.addTask { await stream(security) }
                }
            }
        }
    }

    private func stream(_ security: String) async {
        for await event in await client.subscribe(security) {
            if case .tick(let quote) = event {
                await MainActor.run { quotes[security] = quote }
            }
        }
    }

    private func tile(_ security: String, quote: Quote?, height: CGFloat) -> some View {
        let big = min(max(height * 0.34, 14), 40)
        return VStack(alignment: .leading, spacing: 2) {
            Text(shortName(security)).font(.system(size: max(big * 0.42, 10), weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.muted).lineLimit(1)
            Text(quote.map { Format.price($0.last) } ?? "—")
                .font(.system(size: big, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.text).lineLimit(1).minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.2), value: quote?.last)
            Text(quote.map { Format.percent($0.changePct) } ?? " ")
                .font(.system(size: max(big * 0.45, 10), weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.direction(quote?.changePct))
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .padding(.horizontal, 8)
        .background(Palette.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
    }
}

// MARK: Chart

/// One security, TradingView-style, with a live last candle.
struct ChartWidget: View {
    let widget: DashWidget
    let client: DataClient

    @State private var bars: [Bar] = []
    @State private var step: Double?
    @State private var failure: String?

    private var security: String { widget.securities.first ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if let failure, bars.isEmpty {
                WidgetMessage(text: failure)
            } else if bars.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chart
            }
        }
        .task(id: "\(security)|\(widget.range)|\(widget.interval ?? "")") { await run() }
    }

    /// The bars on screen: the whole range, or only the last `hours`.
    private var shown: [Bar] {
        guard let hours = widget.hours, let last = bars.last else { return bars }
        let cutoff = last.t + (step ?? 0) - Double(hours) * 3600
        return bars.filter { $0.t >= cutoff }
    }

    private var header: some View {
        let bars = shown
        let first = bars.first?.o ?? bars.first?.c, last = bars.last?.c
        let change = first.flatMap { f in last.map { ($0 / f - 1) * 100 } }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(last.map(Format.price) ?? "—").font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.text)
            Text(Format.percent(change)).font(.terminalSmall).foregroundStyle(Palette.direction(change))
            Spacer()
            Text(widget.interval.map(Self.intervalLabel) ?? "")
                .font(.terminalSmall).foregroundStyle(Palette.muted)
            if !widget.overlays.isEmpty {
                Text(widget.overlays.joined(separator: " ")).font(.terminalSmall).foregroundStyle(Palette.muted)
            }
        }
    }

    private static func intervalLabel(_ raw: String) -> String {
        ["1MIN": "1m", "5MIN": "5m", "15MIN": "15m", "30MIN": "30m", "1H": "1h", "4H": "4h", "1DAY": "1D", "1WK": "1W"][raw] ?? raw
    }

    private var chart: some View {
        let all = bars
        let bars = shown
        // Overlays are computed on the full history so a 4-hour window still gets a real SMA50.
        let skip = all.count - bars.count
        let closes = bars.map(\.c)
        let lows = bars.compactMap(\.l) + closes, highs = bars.compactMap(\.h) + closes
        let lo = lows.min() ?? 0, hi = highs.max() ?? 1
        let pad = (hi - lo) * 0.06
        let up = (bars.last?.c ?? 0) >= (bars.first?.c ?? 0)
        let color = up ? Heat.up : Heat.down
        return Chart {
            switch widget.style {
            case .candle:
                ForEach(Array(bars.enumerated()), id: \.offset) { i, bar in
                    let rising = bar.c >= (bar.o ?? bar.c)
                    RuleMark(x: .value("i", Double(i)), yStart: .value("l", bar.l ?? bar.c), yEnd: .value("h", bar.h ?? bar.c))
                        .foregroundStyle(rising ? Heat.up : Heat.down).lineStyle(StrokeStyle(lineWidth: 1))
                    RectangleMark(xStart: .value("a", Double(i) - 0.36), xEnd: .value("b", Double(i) + 0.36),
                                  yStart: .value("o", bar.o ?? bar.c), yEnd: .value("c", bar.c))
                        .foregroundStyle(rising ? Heat.up : Heat.down)
                }
            default:
                ForEach(Array(bars.enumerated()), id: \.offset) { i, bar in
                    if widget.style == .area {
                        AreaMark(x: .value("i", Double(i)), yStart: .value("lo", lo - pad), yEnd: .value("c", bar.c))
                            .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                    }
                    LineMark(x: .value("i", Double(i)), y: .value("c", bar.c))
                        .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            ForEach(overlayLines(all.map(\.c), skip: skip), id: \.name) { line in
                ForEach(Array(line.values.enumerated()), id: \.offset) { i, value in
                    if let value {
                        LineMark(x: .value("i", Double(i)), y: .value(line.name, value), series: .value("s", line.name))
                            .foregroundStyle(line.color).lineStyle(StrokeStyle(lineWidth: 1))
                    }
                }
            }
            if let last = bars.last {
                RuleMark(y: .value("last", last.c)).foregroundStyle(color.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
            }
        }
        .chartYScale(domain: (lo - pad)...(hi + pad))
        .chartXScale(domain: -0.5...(Double(bars.count) - 0.5))
        .chartXAxis {
            AxisMarks(values: Self.ticks(count: bars.count)) { value in
                AxisGridLine().foregroundStyle(Palette.border.opacity(0.5))
                AxisValueLabel {
                    if let i = value.as(Double.self), let bar = bars[safe: Int(i)] {
                        Text(Self.timeLabel(bar.date, step: step ?? 86400)).font(.terminalSmall)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Palette.border)
                AxisValueLabel { if let v = value.as(Double.self) { Text(Format.price(v)).font(.terminalSmall) } }
            }
        }
    }

    /// About four evenly spaced time labels.
    private static func ticks(count: Int) -> [Double] {
        guard count > 1 else { return [] }
        let stride = max(count / 4, 1)
        return Swift.stride(from: stride / 2, to: count, by: stride).map(Double.init)
    }

    private static func timeLabel(_ date: Date, step: Double) -> String {
        step < 86400 ? date.formatted(date: .omitted, time: .shortened) : date.formatted(.dateTime.month(.abbreviated).day())
    }

    private struct OverlayLine { let name: String; let color: Color; let values: [Double?] }

    private func overlayLines(_ closes: [Double], skip: Int) -> [OverlayLine] {
        widget.overlays.compactMap { name -> OverlayLine? in
            switch name {
            case "SMA20": OverlayLine(name: name, color: Color(red: 0.35, green: 0.65, blue: 1.0), values: Indicators.sma(closes, period: 20))
            case "SMA50": OverlayLine(name: name, color: Palette.accent, values: Indicators.sma(closes, period: 50))
            case "SMA200": OverlayLine(name: name, color: Color(red: 0.8, green: 0.45, blue: 1.0), values: Indicators.sma(closes, period: 200))
            case "EMA20": OverlayLine(name: name, color: Color(red: 0.3, green: 0.85, blue: 0.85), values: Indicators.ema(closes, period: 20))
            default: nil
            }
        }
        .map { OverlayLine(name: $0.name, color: $0.color, values: Array($0.values.dropFirst(skip))) }
    }

    private func run() async {
        // With a time window, load a few days so the window is full even after a quiet session.
        let range = widget.hours != nil ? .d5 : (ChartRange(rawValue: widget.range) ?? .d1)
        let interval = widget.interval.flatMap(ChartConfig.Interval.init(rawValue:))
        // Reload the history every 5 minutes; the stream keeps the last candle live in between.
        while !Task.isCancelled {
            do {
                let history = try await client.history(security, range: range, interval: interval)
                bars = history.bars
                step = history.intervalSeconds
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await streamLastBar() }
                group.addTask { try? await Task.sleep(for: .seconds(300)) }
                await group.next()
                group.cancelAll()
            }
        }
    }

    private func streamLastBar() async {
        for await event in await client.subscribe(security) {
            guard case .tick(let quote) = event else { continue }
            await MainActor.run {
                guard let last = bars.last, let step else { return }
                let price = quote.last
                if step < 86400, quote.asOf >= last.t + step, price != last.c {
                    let start = last.t + ((quote.asOf - last.t) / step).rounded(.down) * step
                    bars.append(Bar(t: start, o: price, h: price, l: price, c: price, v: 0))
                    if bars.count > 2000 { bars.removeFirst() }
                } else {
                    bars[bars.count - 1] = Bar(t: last.t, o: last.o, h: max(last.h ?? price, price),
                                               l: min(last.l ?? price, price), c: price, v: last.v)
                }
            }
        }
    }
}

// MARK: Compare

/// Several securities rebased to % change from the start of the range.
struct CompareWidget: View {
    let widget: DashWidget
    let client: DataClient

    @State private var series: [(name: String, points: [(Date, Double)])] = []

    private static let colors: [Color] = [Palette.accent, Color(red: 0.35, green: 0.65, blue: 1.0),
                                          Color(red: 0.8, green: 0.45, blue: 1.0), Color(red: 0.3, green: 0.85, blue: 0.85),
                                          Color(red: 1.0, green: 0.45, blue: 0.6), Heat.up]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                ForEach(Array(series.enumerated()), id: \.offset) { i, s in
                    HStack(spacing: 4) {
                        Circle().fill(Self.colors[i % Self.colors.count]).frame(width: 7, height: 7)
                        Text(s.name).font(.terminalSmall).foregroundStyle(Palette.text)
                        Text(Format.percent(s.points.last?.1)).font(.terminalSmall)
                            .foregroundStyle(Palette.direction(s.points.last?.1))
                    }
                }
            }
            Chart {
                ForEach(Array(series.enumerated()), id: \.offset) { i, s in
                    ForEach(Array(s.points.enumerated()), id: \.offset) { _, point in
                        LineMark(x: .value("t", point.0), y: .value("%", point.1), series: .value("s", s.name))
                            .foregroundStyle(Self.colors[i % Self.colors.count])
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
                RuleMark(y: .value("0", 0)).foregroundStyle(Palette.muted.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Palette.border)
                    AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))%").font(.terminalSmall) } }
                }
            }
        }
        .task(id: "\(widget.securities)|\(widget.range)") {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    private func load() async {
        let range = ChartRange(rawValue: widget.range) ?? .m1
        var loaded: [(String, [(Date, Double)])] = []
        for security in widget.securities {
            guard let history = try? await client.history(security, range: range),
                  let base = history.bars.first?.c, base != 0 else { continue }
            loaded.append((shortName(security), history.bars.map { ($0.date, ($0.c / base - 1) * 100) }))
        }
        series = loaded.map { (name: $0.0, points: $0.1) }
    }
}

// MARK: Diagram

/// A builder-made diagram: one value per security, drawn as bars, columns, donut, treemap or tiles.
struct DiagramWidget: View {
    let widget: DashWidget
    let client: DataClient

    @State private var values: [(name: String, value: Double)] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if values.isEmpty {
                if loaded { WidgetMessage(text: "No data for these securities") }
                else { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else {
                diagram
            }
        }
        .task(id: "\(widget.securities)|\(widget.range)|\(widget.metric)") {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(widget.metric == .change ? 120 : 30))
            }
        }
    }

    private var isChange: Bool { widget.metric == .change }

    private func label(_ v: Double) -> String {
        switch widget.metric {
        case .change: Format.percent(v)
        case .price: Format.price(v)
        case .volume, .marketCap: Format.compact(v)
        }
    }

    private func color(_ v: Double, index: Int) -> Color {
        isChange ? Palette.direction(v) : Heat.palette[index % Heat.palette.count]
    }

    @ViewBuilder
    private var diagram: some View {
        let sorted = values.sorted { $0.value > $1.value }
        switch widget.style {
        case .columns:
            Chart(Array(sorted.enumerated()), id: \.offset) { i, item in
                BarMark(x: .value("name", item.name), y: .value("v", item.value))
                    .foregroundStyle(color(item.value, index: i))
                    .annotation(position: item.value >= 0 ? .top : .bottom) {
                        Text(label(item.value)).font(.terminalSmall).foregroundStyle(Palette.text)
                    }
            }
            .chartYAxis(.hidden)
            .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.terminalSmall) } }
        case .donut:
            HStack(spacing: 12) {
                Chart(Array(sorted.enumerated()), id: \.offset) { i, item in
                    SectorMark(angle: .value("v", abs(item.value)), innerRadius: .ratio(0.6), angularInset: 1)
                        .foregroundStyle(Heat.palette[i % Heat.palette.count])
                }
                VStack(alignment: .leading, spacing: 3) {
                    let total = sorted.map { abs($0.value) }.reduce(0, +)
                    ForEach(Array(sorted.enumerated()), id: \.offset) { i, item in
                        HStack(spacing: 5) {
                            Circle().fill(Heat.palette[i % Heat.palette.count]).frame(width: 7, height: 7)
                            Text(item.name).font(.terminalSmall).foregroundStyle(Palette.text)
                            Spacer()
                            Text(total > 0 ? String(format: "%.0f%%", abs(item.value) / total * 100) : "")
                                .font(.terminalSmall).foregroundStyle(Palette.muted)
                        }
                    }
                }
                .frame(maxWidth: 160)
            }
        case .treemap:
            GeometryReader { geo in
                let rects = Squarify.layout(sorted.map { max(abs($0.value), 0.0001) }, in: CGRect(origin: .zero, size: geo.size))
                let range = Heat.range(sorted.map(\.value))
                ForEach(Array(zip(sorted, rects).enumerated()), id: \.offset) { i, pair in
                    let (item, rect) = pair
                    tile(item, fill: isChange ? Heat.diverging(item.value, range: range) : Heat.palette[i % Heat.palette.count])
                        .frame(width: max(rect.width - 2, 1), height: max(rect.height - 2, 1))
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
        case .tiles:
            let range = Heat.range(sorted.map(\.value))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 4)], spacing: 4) {
                ForEach(Array(sorted.enumerated()), id: \.offset) { i, item in
                    tile(item, fill: isChange ? Heat.diverging(item.value, range: range) : Heat.palette[i % Heat.palette.count])
                        .frame(height: 56)
                }
            }
        default:  // bars
            Chart(Array(sorted.enumerated()), id: \.offset) { i, item in
                BarMark(x: .value("v", item.value), y: .value("name", item.name))
                    .foregroundStyle(color(item.value, index: i))
                    .annotation(position: item.value >= 0 ? .trailing : .leading) {
                        Text(label(item.value)).font(.terminalSmall).foregroundStyle(Palette.text)
                    }
            }
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks { _ in AxisValueLabel().font(.terminalSmall) } }
        }
    }

    private func tile(_ item: (name: String, value: Double), fill: Color) -> some View {
        VStack(spacing: 2) {
            Text(item.name).font(.system(size: 13, weight: .semibold, design: .monospaced))
            Text(label(item.value)).font(.terminalSmall)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(fill, in: RoundedRectangle(cornerRadius: 2))
    }

    private func load() async {
        var out: [(String, Double)] = []
        for security in widget.securities {
            let name = shortName(security)
            switch widget.metric {
            case .change:
                let range = ChartRange(rawValue: widget.range) ?? .d1
                if let bars = try? await client.history(security, range: range).bars,
                   let first = bars.first?.c, let last = bars.last?.c, first != 0 {
                    out.append((name, (last / first - 1) * 100))
                }
            case .price, .volume, .marketCap:
                guard let quote = try? await client.refData(security).quote else { continue }
                let value = widget.metric == .price ? quote.last : widget.metric == .volume ? quote.volume : quote.marketCap
                if let value { out.append((name, value)) }
            }
        }
        values = out.map { (name: $0.0, value: $0.1) }
        loaded = true
    }
}
