import Charts
import FinopsCore
import SwiftUI

/// ECON <series> [range] [YOY]: one FRED series as a chart.
struct EconSeriesView: View {
    let client: DataClient
    let id: String
    let range: String
    let yoy: Bool
    let run: (String) -> Void

    @State private var data: EconSeries?
    @State private var failure: String?
    @State private var hovered: EconSeries.Observation?

    private static let ranges = ["1Y", "2Y", "5Y", "10Y", "20Y", "MAX"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Button { run("ECON") } label: { Label("Dashboard", systemImage: "chevron.left") }
                    .buttonStyle(TerminalButtonStyle())
                Spacer().frame(width: 10)
                ForEach(Self.ranges, id: \.self) { r in
                    Button(r) { run(command(range: r, yoy: yoy)) }
                        .buttonStyle(TerminalButtonStyle(selected: r == range))
                }
                Spacer().frame(width: 10)
                Button("YoY %") { run(command(range: range, yoy: !yoy)) }
                    .buttonStyle(TerminalButtonStyle(selected: yoy))
                    .help("Show % change from a year ago")
                Spacer()
            }
            if let failure {
                StatusMessage(title: "Couldn't load \(id)", detail: failure, isError: true)
                Spacer()
            } else if let data, let last = data.observations.last {
                let shown = hovered ?? last
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(data.series.id).foregroundStyle(Palette.accent)
                        Text(data.series.title).foregroundStyle(Palette.text).lineLimit(1)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(Format.number(shown.v)).font(.title3.monospaced()).monospacedDigit()
                        Text(data.series.units).foregroundStyle(Palette.muted)
                        Spacer()
                        Text(shown.date.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(Palette.muted)
                    }
                }
                chart(data)
                if !data.series.notes.isEmpty {
                    Text(data.series.notes).font(.terminalSmall).foregroundStyle(Palette.muted).lineLimit(3)
                }
                Text("\(data.series.frequency) · updated \(data.series.lastUpdated) · Source: \(data.source)")
                    .font(.terminalSmall).foregroundStyle(Palette.muted)
            } else {
                ProgressView().controlSize(.small)
                Spacer()
            }
        }
        .padding(12)
        .task { await load() }
    }

    private func command(range: String, yoy: Bool) -> String {
        "ECON \(id) \(range)" + (yoy ? " YOY" : "")
    }

    private func chart(_ data: EconSeries) -> some View {
        let values = data.observations.map(\.v)
        let low = values.min() ?? 0, high = values.max() ?? 1
        let pad = max((high - low) * 0.06, abs(high) * 0.001 + 0.01)
        return Chart {
            if low < 0 && high > 0 {
                RuleMark(y: .value("Zero", 0)).foregroundStyle(Palette.muted.opacity(0.5))
            }
            ForEach(data.observations) { o in
                AreaMark(x: .value("Date", o.date), yStart: .value("Floor", low - pad), yEnd: .value("Value", o.v))
                    .foregroundStyle(LinearGradient(colors: [Palette.accent.opacity(0.2), .clear], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Date", o.date), y: .value("Value", o.v)).foregroundStyle(Palette.accent)
            }
            if let hovered {
                RuleMark(x: .value("Date", hovered.date)).foregroundStyle(Palette.muted.opacity(0.5))
            }
        }
        .chartYScale(domain: (low - pad)...(high + pad))
        .chartYAxis { AxisMarks(position: .trailing) }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let location) = phase, let plot = proxy.plotFrame,
                              let date: Date = proxy.value(atX: location.x - geometry[plot].origin.x) else {
                            hovered = nil
                            return
                        }
                        hovered = data.observations.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                    }
            }
        }
        .accessibilityLabel("\(data.series.title) chart")
    }

    private func load() async {
        do { data = try await client.econSeries(id, range: range, yoy: yoy) }
        catch { failure = error.localizedDescription }
    }
}

/// CURVE: US Treasury yield curve now vs 1M, 6M and 1Y ago.
struct CurveView: View {
    let client: DataClient

    @State private var data: YieldCurves?
    @State private var failure: String?

    private static let colors: [Color] = [Palette.accent, Color(red: 0.35, green: 0.65, blue: 1.0),
                                          Color(red: 0.80, green: 0.45, blue: 1.0), Palette.muted]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("US Treasury yield curve").font(.system(size: 14, weight: .semibold, design: .monospaced))
                if let failure {
                    StatusMessage(title: "Couldn't load the curve", detail: failure, isError: true)
                } else if let data, let latest = data.curves.first {
                    legend(data)
                    chart(data).frame(height: 300)
                    table(data, latest: latest)
                    Text("Constant-maturity yields, %. Source: \(data.source)").font(.terminalSmall).foregroundStyle(Palette.muted)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(14)
        }
        .task {
            do { data = try await client.yieldCurves() } catch { failure = error.localizedDescription }
        }
    }

    private func legend(_ data: YieldCurves) -> some View {
        HStack(spacing: 14) {
            ForEach(Array(data.curves.enumerated()), id: \.offset) { i, curve in
                HStack(spacing: 5) {
                    Circle().fill(Self.colors[i % Self.colors.count]).frame(width: 8, height: 8)
                    Text("\(curve.label) (\(Format.date(curve.date)))").font(.terminalSmall)
                }
            }
        }
    }

    private func chart(_ data: YieldCurves) -> some View {
        let tenors = data.curves.first?.points.map(\.tenor) ?? []
        return Chart {
            ForEach(Array(data.curves.enumerated()), id: \.offset) { i, curve in
                ForEach(curve.points, id: \.tenor) { p in
                    LineMark(x: .value("Tenor", p.tenor), y: .value("Yield", p.yield), series: .value("Curve", curve.label))
                        .foregroundStyle(Self.colors[i % Self.colors.count])
                        .lineStyle(StrokeStyle(lineWidth: i == 0 ? 2 : 1.2, dash: i == 0 ? [] : [4, 3]))
                    PointMark(x: .value("Tenor", p.tenor), y: .value("Yield", p.yield))
                        .foregroundStyle(Self.colors[i % Self.colors.count])
                        .symbolSize(i == 0 ? 30 : 12)
                }
            }
        }
        .chartXScale(domain: tenors)
        .chartYAxis {
            AxisMarks(position: .trailing) { v in
                AxisGridLine().foregroundStyle(Palette.border)
                AxisValueLabel { Text("\(v.as(Double.self).map { Format.number($0) } ?? "")%") }
            }
        }
        .chartLegend(.hidden)
        .accessibilityLabel("Yield curve chart")
    }

    private func table(_ data: YieldCurves, latest: YieldCurves.Curve) -> some View {
        let yearAgo = data.curves.last
        return Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 4) {
            GridRow {
                Text("Tenor").gridColumnAlignment(.leading)
                ForEach(data.curves) { Text($0.label) }
                Text("Δ 1Y (bp)")
            }
            .font(.terminalLabel).foregroundStyle(Palette.muted)
            ForEach(latest.points, id: \.tenor) { p in
                GridRow {
                    Text(p.tenor).foregroundStyle(Palette.accent)
                    ForEach(data.curves) { c in
                        Text(Format.number(c.points.first { $0.tenor == p.tenor }?.yield))
                    }
                    let old = yearAgo?.points.first { $0.tenor == p.tenor }?.yield
                    let bp = old.map { (p.yield - $0) * 100 }
                    Text(Format.signed(bp, digits: 0)).foregroundStyle(Palette.direction(bp))
                }
                .monospacedDigit()
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(10)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 4))
    }
}
