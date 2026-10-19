import Charts
import FinopsCore
import SwiftUI

/// Colour scales shared by the visual blocks.
public enum Heat {
    public static let up = Color(red: 0.149, green: 0.651, blue: 0.604)
    public static let down = Color(red: 0.937, green: 0.325, blue: 0.314)
    public static let neutral = Color(red: 0.20, green: 0.20, blue: 0.22)

    /// Red ← neutral → green, saturating at ±`range`.
    public static func diverging(_ value: Double?, range: Double) -> Color {
        guard let value, range > 0 else { return neutral }
        let t = min(abs(value) / range, 1)
        return mix(neutral, value >= 0 ? up : down, t)
    }

    public static func mix(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let ra = a.resolve(in: EnvironmentValues()), rb = b.resolve(in: EnvironmentValues())
        return Color(red: Double(ra.red + (rb.red - ra.red) * Float(t)),
                     green: Double(ra.green + (rb.green - ra.green) * Float(t)),
                     blue: Double(ra.blue + (rb.blue - ra.blue) * Float(t)))
    }

    /// A robust colour range: 90th percentile of |values|.
    public static func range(_ values: [Double]) -> Double {
        let mags = values.map(abs).sorted()
        guard !mags.isEmpty else { return 1 }
        return max(mags[min(mags.count - 1, Int(Double(mags.count) * 0.9))], 0.0001)
    }

    public static let palette: [Color] = [
        Palette.accent, Color(red: 0.35, green: 0.65, blue: 1.0), Color(red: 0.80, green: 0.45, blue: 1.0),
        Color(red: 0.30, green: 0.85, blue: 0.85), Color(red: 1.0, green: 0.45, blue: 0.6), up,
        Color(red: 0.95, green: 0.85, blue: 0.35), Color(red: 0.6, green: 0.6, blue: 0.65),
    ]
}

private func blockTitle(_ title: String?) -> some View {
    Group { if let title { SectionLabel(title: title) } }
}

// MARK: Treemap (squarified)

public struct TreemapBlockView: View {
    let block: GatewayDocument.TreemapBlock
    let run: (String) -> Void
    /// Terminal screens give treemaps room; dashboard tiles pass 0 to fill whatever they have.
    var minHeight: CGFloat = 420
    @Environment(\.viewportHeight) private var viewport
    public init(block: GatewayDocument.TreemapBlock, run: @escaping (String) -> Void, minHeight: CGFloat = 420) {
        self.block = block
        self.run = run
        self.minHeight = minHeight
    }

    @State private var hovered: String?

    public var body: some View {
        let range = Heat.range(block.groups.flatMap { $0.items.compactMap(\.value) })
        VStack(alignment: .leading, spacing: 6) {
            blockTitle(block.title)
            GeometryReader { geo in
                let groupRects = Squarify.layout(block.groups.map { $0.items.reduce(0) { $0 + max($1.weight, 0) } },
                                                 in: CGRect(origin: .zero, size: geo.size))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(block.groups.enumerated()), id: \.offset) { gi, group in
                        let g = groupRects[gi].insetBy(dx: 1, dy: 1)
                        let header: CGFloat = g.height > 40 && g.width > 60 ? 14 : 0
                        let content = CGRect(x: g.minX, y: g.minY + header, width: g.width, height: max(g.height - header, 0))
                        let rects = Squarify.layout(group.items.map { max($0.weight, 0) }, in: content)
                        if header > 0 {
                            Text(group.label.uppercased())
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(Palette.muted)
                                .lineLimit(1)
                                .frame(width: g.width, height: header, alignment: .leading)
                                .offset(x: g.minX + 2, y: g.minY)
                        }
                        ForEach(Array(group.items.enumerated()), id: \.offset) { ii, item in
                            tile(item, rect: rects[ii].insetBy(dx: 0.5, dy: 0.5), range: range)
                        }
                    }
                }
            }
            .frame(minHeight: minHeight > 0 ? max(minHeight, viewport * 0.72) : 0)
            legend(range)
        }
    }

    private func tile(_ item: GatewayDocument.TreemapBlock.Item, rect: CGRect, range: Double) -> some View {
        let big = rect.width > 46 && rect.height > 26
        return ZStack {
            Rectangle().fill(Heat.diverging(item.value, range: range))
            if hovered == item.label { Rectangle().stroke(Palette.accent, lineWidth: 2) }
            if big {
                VStack(spacing: 1) {
                    Text(item.label).font(.system(size: min(16, max(9, rect.width / 7)), weight: .bold, design: .monospaced))
                    Text(Format.percent(item.value)).font(.system(size: min(12, max(8, rect.width / 9)), design: .monospaced))
                }
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(2)
            }
        }
        .frame(width: max(rect.width, 0), height: max(rect.height, 0))
        .offset(x: rect.minX, y: rect.minY)
        .contentShape(Rectangle())
        #if !os(tvOS)
        .onHover { hovered = $0 ? item.label : (hovered == item.label ? nil : hovered) }
        #endif
        .onTapGesture { if let cmd = item.cmd { run(cmd) } }
        .help("\(item.label) · \(item.detail ?? "") · \(Format.percent(item.value))")
        .accessibilityElement()
        .accessibilityLabel("\(item.label), \(Format.percent(item.value))")
        .accessibilityAddTraits(.isButton)
    }

    private func legend(_ range: Double) -> some View {
        HStack(spacing: 2) {
            ForEach([-1.0, -0.5, -0.2, 0, 0.2, 0.5, 1.0], id: \.self) { t in
                Text(Format.percent(t * range))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 16)
                    .background(Heat.diverging(t * range, range: range))
            }
        }
    }
}

/// Squarified treemap layout (Bruls, Huizing, van Wijk 2000). Returns one rect per weight, in input order.
public enum Squarify {
    public static func layout(_ weights: [Double], in rect: CGRect) -> [CGRect] {
        var out = [CGRect](repeating: .zero, count: weights.count)
        let total = weights.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return out }
        let scale = Double(rect.width * rect.height) / total
        var order = weights.indices.sorted { weights[$0] > weights[$1] }.map { (index: $0, area: weights[$0] * scale) }
        var free = rect
        while !order.isEmpty {
            let side = Double(min(free.width, free.height))
            var row: [(index: Int, area: Double)] = []
            while let next = order.first {
                let candidate = row + [next]
                if row.isEmpty || worst(candidate, side) <= worst(row, side) {
                    row = candidate
                    order.removeFirst()
                } else { break }
            }
            let rowArea = row.reduce(0) { $0 + $1.area }
            let thickness = CGFloat(rowArea / side)
            var offset: CGFloat = 0
            for item in row {
                let length = CGFloat(item.area) / max(thickness, 0.0001)
                if free.width >= free.height {
                    out[item.index] = CGRect(x: free.minX, y: free.minY + offset, width: thickness, height: length)
                } else {
                    out[item.index] = CGRect(x: free.minX + offset, y: free.minY, width: length, height: thickness)
                }
                offset += length
            }
            if free.width >= free.height {
                free = CGRect(x: free.minX + thickness, y: free.minY, width: free.width - thickness, height: free.height)
            } else {
                free = CGRect(x: free.minX, y: free.minY + thickness, width: free.width, height: free.height - thickness)
            }
        }
        return out
    }

    private static func worst(_ row: [(index: Int, area: Double)], _ side: Double) -> Double {
        let s = row.reduce(0) { $0 + $1.area }
        guard s > 0, let mx = row.map(\.area).max(), let mn = row.map(\.area).min(), mn > 0 else { return .infinity }
        return max(side * side * mx / (s * s), s * s / (side * side * mn))
    }
}

// MARK: Heat matrix

public struct MatrixBlockView: View {
    let block: GatewayDocument.MatrixBlock
    let run: (String) -> Void
    public init(block: GatewayDocument.MatrixBlock, run: @escaping (String) -> Void) {
        self.block = block
        self.run = run
    }


    public var body: some View {
        let values = block.values.flatMap { $0.compactMap { $0 } }
        let range = block.scale == "correlation" ? 1.0 : Heat.range(values.map { $0 - block.center })
        VStack(alignment: .leading, spacing: 6) {
            blockTitle(block.title)
            ScrollView(.horizontal) {
                Grid(horizontalSpacing: 1, verticalSpacing: 1) {
                    GridRow {
                        Text("")
                        ForEach(block.cols, id: \.self) { col in
                            Text(col).font(.terminalLabel).foregroundStyle(Palette.muted)
                                .frame(minWidth: 70)
                        }
                    }
                    ForEach(Array(block.rows.enumerated()), id: \.offset) { r, label in
                        GridRow {
                            Button(label) { if let cmd = block.rowCmds?[r] { run(cmd) } }
                                .buttonStyle(.plain)
                                .foregroundStyle(block.rowCmds?[r] != nil ? Palette.accent : Palette.text)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                                .frame(minWidth: 110, alignment: .leading)
                            ForEach(Array(block.cols.enumerated()), id: \.offset) { c, _ in
                                let value = r < block.values.count && c < block.values[r].count ? block.values[r][c] : nil
                                Text(value.map { Format.value(.number($0), kind: block.kind) } ?? "—")
                                    .font(.system(size: 12, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(block.scale == "none" ? Palette.text : .white)
                                    .frame(minWidth: 70, minHeight: 24)
                                    .background(block.scale == "none" ? Palette.surface
                                                : Heat.diverging(value.map { $0 - block.center }, range: range))
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: Scatter

public struct ScatterBlockView: View {
    let block: GatewayDocument.ScatterBlock
    let run: (String) -> Void
    public init(block: GatewayDocument.ScatterBlock, run: @escaping (String) -> Void) {
        self.block = block
        self.run = run
    }

    @State private var hovered: GatewayDocument.ScatterBlock.Point?
    @Environment(\.viewportHeight) private var viewport

    public var body: some View {
        let maxSize = block.points.compactMap(\.size).max() ?? 1
        VStack(alignment: .leading, spacing: 6) {
            blockTitle(block.title)
            Chart(block.points, id: \.label) { p in
                PointMark(x: .value(block.xLabel, p.x), y: .value(block.yLabel, p.y))
                    .symbolSize(40 + 900 * ((p.size ?? maxSize / 4) / maxSize))
                    .foregroundStyle(p.highlight == true ? Palette.accent : Color(red: 0.35, green: 0.65, blue: 1.0).opacity(0.75))
                    .annotation(position: .top, spacing: 2) {
                        Text(p.label).font(.system(size: 10, weight: p.highlight == true ? .bold : .regular, design: .monospaced))
                            .foregroundStyle(p.highlight == true ? Palette.accent : Palette.muted)
                    }
            }
            .chartXAxisLabel(block.xLabel)
            .chartYAxisLabel(block.yLabel)
            .chartXAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Palette.border); AxisValueLabel() } }
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(Palette.border); AxisValueLabel() } }
            #if os(tvOS)
            .frame(height: max(380, viewport * 0.62))
            #else
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            if let p = nearest(proxy, geo, location), let cmd = p.cmd { run(cmd) }
                        }
                        .onContinuousHover { phase in
                            if case .active(let location) = phase { hovered = nearest(proxy, geo, location) } else { hovered = nil }
                        }
                }
            }
            .frame(height: max(380, viewport * 0.62))
            #endif
            if let hovered {
                Text("\(hovered.label)  \(block.xLabel) \(Format.value(.number(hovered.x), kind: block.xKind))  ·  \(block.yLabel) \(Format.value(.number(hovered.y), kind: block.yKind))")
                    .font(.terminalSmall).foregroundStyle(Palette.accent)
            }
        }
    }

    private func nearest(_ proxy: ChartProxy, _ geo: GeometryProxy, _ location: CGPoint) -> GatewayDocument.ScatterBlock.Point? {
        guard let plot = proxy.plotFrame else { return nil }
        let origin = geo[plot].origin
        return block.points.min { a, b in
            dist(proxy, a, location, origin) < dist(proxy, b, location, origin)
        }.flatMap { dist(proxy, $0, location, origin) < 40 ? $0 : nil }
    }

    private func dist(_ proxy: ChartProxy, _ p: GatewayDocument.ScatterBlock.Point, _ l: CGPoint, _ o: CGPoint) -> CGFloat {
        guard let pos = proxy.position(for: (x: p.x, y: p.y)) else { return .infinity }
        return hypot(pos.x + o.x - l.x, pos.y + o.y - l.y)
    }
}

// MARK: Relationship graph (hub and spoke)

public struct GraphBlockView: View {
    let block: GatewayDocument.GraphBlock
    let run: (String) -> Void
    public init(block: GatewayDocument.GraphBlock, run: @escaping (String) -> Void) {
        self.block = block
        self.run = run
    }


    private let nodeSize = CGSize(width: 190, height: 34)

    public var body: some View {
        let left = block.groups.first { $0.side == "left" }
        let right = block.groups.first { $0.side == "right" }
        let bottom = block.groups.first { $0.side == "bottom" }
        let rows = max(left?.nodes.count ?? 0, right?.nodes.count ?? 0, 6)
        let height = CGFloat(rows) * (nodeSize.height + 6) + 40 + (bottom == nil ? 0 : nodeSize.height + 70)
        VStack(alignment: .leading, spacing: 6) {
            blockTitle(block.title)
            GeometryReader { geo in
                let w = geo.size.width
                let sideHeight = CGFloat(rows) * (nodeSize.height + 6) + 20
                let center = CGPoint(x: w / 2, y: sideHeight / 2 + 10)
                let leftPts = column(left?.nodes.count ?? 0, x: nodeSize.width / 2 + 4, height: sideHeight)
                let rightPts = column(right?.nodes.count ?? 0, x: w - nodeSize.width / 2 - 4, height: sideHeight)
                let bottomPts = rowPoints(bottom?.nodes.count ?? 0, y: sideHeight + 50 + nodeSize.height / 2, width: w)
                ZStack(alignment: .topLeading) {
                    Path { path in
                        for p in leftPts + rightPts + bottomPts {
                            path.move(to: center)
                            path.addLine(to: p)
                        }
                    }
                    .stroke(Color(red: 0.35, green: 0.65, blue: 1.0).opacity(0.35), lineWidth: 1)
                    HStack {
                        Text(left?.title.uppercased() ?? "")
                        Spacer()
                        Text(right?.title.uppercased() ?? "")
                    }
                    .font(.terminalLabel)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .frame(width: w)
                    groupLabel(bottom?.title, at: CGPoint(x: w / 2, y: sideHeight + 22))
                    ForEach(Array((left?.nodes ?? []).enumerated()), id: \.offset) { i, n in node(n).position(leftPts[i]) }
                    ForEach(Array((right?.nodes ?? []).enumerated()), id: \.offset) { i, n in node(n).position(rightPts[i]) }
                    ForEach(Array((bottom?.nodes ?? []).enumerated()), id: \.offset) { i, n in node(n, width: min(nodeSize.width, w / CGFloat(max(bottomPts.count, 1)) - 6)).position(bottomPts[i]) }
                    centerBox.position(center)
                }
            }
            .frame(height: height)
        }
    }

    private func column(_ n: Int, x: CGFloat, height: CGFloat) -> [CGPoint] {
        guard n > 0 else { return [] }
        let step = (height - 20) / CGFloat(n)
        return (0..<n).map { CGPoint(x: x, y: 26 + step * (CGFloat($0) + 0.5)) }
    }

    private func rowPoints(_ n: Int, y: CGFloat, width: CGFloat) -> [CGPoint] {
        guard n > 0 else { return [] }
        let step = width / CGFloat(n)
        return (0..<n).map { CGPoint(x: step * (CGFloat($0) + 0.5), y: y) }
    }

    private func groupLabel(_ text: String?, at p: CGPoint) -> some View {
        Text(text?.uppercased() ?? "").font(.terminalLabel).foregroundStyle(Palette.muted)
            .fixedSize().position(p)
    }

    private var centerBox: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(block.center.label).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(.white)
            if let detail = block.center.detail { Text(detail).font(.terminalSmall).foregroundStyle(.white.opacity(0.85)) }
            ForEach(block.center.lines ?? [], id: \.self) { Text($0).font(.terminalSmall).foregroundStyle(.white.opacity(0.85)) }
        }
        .padding(10)
        .frame(width: 230, alignment: .leading)
        .background(Heat.up.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.4)))
    }

    private func node(_ n: GatewayDocument.GraphBlock.Node, width: CGFloat? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(n.label).font(.system(size: 11, weight: .bold, design: .monospaced)).lineLimit(1)
            HStack(spacing: 4) {
                if let detail = n.detail { Text(detail).lineLimit(1) }
                Spacer(minLength: 0)
                if let v = n.value { Text(Format.percent(v)) }
            }
            .font(.system(size: 9, design: .monospaced))
            .opacity(0.9)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .frame(width: width ?? nodeSize.width, height: nodeSize.height, alignment: .leading)
        .background(Heat.diverging(n.value, range: 3), in: RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.15)))
        .contentShape(Rectangle())
        .onTapGesture { if let cmd = n.cmd { run(cmd) } }
        .help(n.cmd ?? n.label)
    }
}

// MARK: Bars, series, donut, small multiples

public struct BarsBlockView: View {
    let block: GatewayDocument.BarsBlock
    let run: (String) -> Void
    public init(block: GatewayDocument.BarsBlock, run: @escaping (String) -> Void) {
        self.block = block
        self.run = run
    }


    public var body: some View {
        let maxAbs = max(block.items.map { abs($0.value) }.max() ?? 1, 0.0001)
        let hasNegative = block.items.contains { $0.value < 0 }
        VStack(alignment: .leading, spacing: 4) {
            blockTitle(block.title)
            ForEach(Array(block.items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 8) {
                    Text(item.label).lineLimit(1).frame(width: 220, alignment: .leading)
                        .foregroundStyle(item.cmd != nil ? Palette.accent : Palette.text)
                    GeometryReader { geo in
                        let half = hasNegative ? geo.size.width / 2 : 0
                        let length = CGFloat(abs(item.value) / maxAbs) * (geo.size.width - half)
                        Rectangle()
                            .fill(item.value >= 0 ? Heat.up : Heat.down)
                            .frame(width: max(length, 1), height: 12)
                            .offset(x: item.value >= 0 ? half : half - length, y: (geo.size.height - 12) / 2)
                    }
                    .frame(height: 18)
                    Text(Format.value(.number(item.value), kind: block.kind)).monospacedDigit().frame(width: 90, alignment: .trailing)
                }
                .font(.system(size: 12, design: .monospaced))
                .contentShape(Rectangle())
                .onTapGesture { if let cmd = item.cmd { run(cmd) } }
            }
        }
    }
}

public struct SeriesBlockView: View {
    let block: GatewayDocument.SeriesBlock
    @Environment(\.viewportHeight) private var viewport
    public init(block: GatewayDocument.SeriesBlock) {
        self.block = block
    }


    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            blockTitle(block.title)
            HStack(spacing: 12) {
                ForEach(Array(block.lines.enumerated()), id: \.offset) { i, line in
                    HStack(spacing: 4) {
                        Circle().fill(Heat.palette[i % Heat.palette.count]).frame(width: 7, height: 7)
                        Text(line.label).font(.terminalSmall)
                    }
                }
            }
            Chart {
                ForEach(Array(block.lines.enumerated()), id: \.offset) { i, line in
                    ForEach(Array(line.points.enumerated()), id: \.offset) { _, p in
                        if block.xKind == "number" {
                            LineMark(x: .value("X", p[0]), y: .value("Value", p[1]), series: .value("Line", line.label))
                                .foregroundStyle(Heat.palette[i % Heat.palette.count])
                                .lineStyle(StrokeStyle(lineWidth: i == 0 ? 1.8 : 1.2))
                        } else {
                            LineMark(x: .value("Date", Date(timeIntervalSince1970: p[0])), y: .value("Value", p[1]),
                                     series: .value("Line", line.label))
                                .foregroundStyle(Heat.palette[i % Heat.palette.count])
                                .lineStyle(StrokeStyle(lineWidth: i == 0 ? 1.8 : 1.2))
                        }
                    }
                }
                if block.xKind == "number" {
                    RuleMark(x: .value("Event", 0.0)).foregroundStyle(Palette.accent.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    RuleMark(y: .value("Zero", 0.0)).foregroundStyle(Palette.muted.opacity(0.5))
                }
            }
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing) { v in
                    AxisGridLine().foregroundStyle(Palette.border)
                    AxisValueLabel { Text(v.as(Double.self).map { Format.value(.number($0), kind: block.kind) } ?? "") }
                }
            }
            .frame(height: max(240, viewport * 0.4))
        }
    }
}

public struct DonutBlockView: View {
    let block: GatewayDocument.DonutBlock
    public init(block: GatewayDocument.DonutBlock) {
        self.block = block
    }


    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            blockTitle(block.title)
            HStack(alignment: .center, spacing: 24) {
                Chart(Array(block.items.enumerated()), id: \.offset) { i, item in
                    SectorMark(angle: .value("Share", item.value), innerRadius: .ratio(0.6), angularInset: 1)
                        .foregroundStyle(Heat.palette[i % Heat.palette.count])
                }
                .frame(width: 200, height: 200)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(block.items.enumerated()), id: \.offset) { i, item in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(Heat.palette[i % Heat.palette.count]).frame(width: 10, height: 10)
                            Text(item.label).frame(width: 180, alignment: .leading)
                            Text(Format.value(.number(item.value), kind: block.kind)).monospacedDigit()
                        }
                        .font(.system(size: 12, design: .monospaced))
                    }
                }
            }
        }
    }
}

public struct SparkGridBlockView: View {
    let block: GatewayDocument.SparkGridBlock
    let run: (String) -> Void
    public init(block: GatewayDocument.SparkGridBlock, run: @escaping (String) -> Void) {
        self.block = block
        self.run = run
    }


    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            blockTitle(block.title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8)], spacing: 8) {
                ForEach(block.items, id: \.label) { item in
                    let color = (item.change ?? 0) >= 0 ? Heat.up : Heat.down
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.label).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Palette.accent)
                            Spacer()
                            Text(item.detail ?? "").monospacedDigit()
                            Text(Format.percent(item.change)).foregroundStyle(color).monospacedDigit()
                        }
                        .font(.system(size: 11, design: .monospaced))
                        Chart(Array(item.points.enumerated()), id: \.offset) { i, v in
                            AreaMark(x: .value("i", i), yStart: .value("min", item.points.min() ?? 0), yEnd: .value("v", v))
                                .foregroundStyle(LinearGradient(colors: [color.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                            LineMark(x: .value("i", i), y: .value("v", v)).foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.2))
                        }
                        .chartXAxis(.hidden)
                        .chartYAxis(.hidden)
                        .chartYScale(domain: (item.points.min() ?? 0)...(item.points.max() ?? 1))
                        .frame(height: 90)
                    }
                    .padding(8)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.border))
                    .contentShape(Rectangle())
                    .onTapGesture { if let cmd = item.cmd { run(cmd) } }
                    .help(item.cmd ?? item.label)
                }
            }
        }
    }
}
