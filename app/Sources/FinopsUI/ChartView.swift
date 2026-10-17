import Charts
import FinopsCore
import SwiftUI

struct ChartView: View {
    let client: DataClient
    let security: String
    let range: ChartRange
    let onError: (Error) -> Void

    @State private var history: History?
    @State private var failure: String?
    @State private var hovered: Bar?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let failure {
                StatusMessage(title: "Couldn't chart \(security)", detail: failure, isError: true)
            } else if let history, let first = history.bars.first, let last = history.bars.last {
                header(history, first: first, last: last)
                chart(history.bars, rising: last.c >= first.c)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(16)
        .task { await load() }
    }

    private func header(_ history: History, first: Bar, last: Bar) -> some View {
        let shown = hovered ?? last
        let change = shown.c - first.c
        return HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(history.security.typed).foregroundStyle(Palette.accent)
            Text(range.rawValue).foregroundStyle(Palette.muted)
            Text(Format.price(shown.c)).font(.title2.monospaced()).monospacedDigit()
            Text(Format.signed(change)).foregroundStyle(Palette.direction(change)).monospacedDigit()
            Text(Format.percent(change / first.c * 100)).foregroundStyle(Palette.direction(change)).monospacedDigit()
            Spacer()
            Text(shown.date.formatted(date: .abbreviated, time: history.interval.hasSuffix("m") || history.interval.hasSuffix("h") ? .shortened : .omitted))
                .foregroundStyle(Palette.muted)
        }
    }

    private func chart(_ bars: [Bar], rising: Bool) -> some View {
        let color = rising ? Palette.up : Palette.down
        let closes = bars.map(\.c)
        let low = closes.min() ?? 0
        let high = closes.max() ?? 1
        let pad = max((high - low) * 0.05, high * 0.001)

        return Chart {
            ForEach(bars) { bar in
                AreaMark(x: .value("Date", bar.date), yStart: .value("Floor", low - pad), yEnd: .value("Close", bar.c))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.25), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Date", bar.date), y: .value("Close", bar.c))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            if let hovered {
                RuleMark(x: .value("Date", hovered.date)).foregroundStyle(.secondary.opacity(0.5))
                PointMark(x: .value("Date", hovered.date), y: .value("Close", hovered.c)).foregroundStyle(color)
            }
        }
        .chartYScale(domain: (low - pad)...(high + pad))
        .chartYAxis { AxisMarks(position: .trailing) }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plot = proxy.plotFrame else { return }
                            let x = location.x - geometry[plot].origin.x
                            guard let date: Date = proxy.value(atX: x) else { return }
                            hovered = nearest(bars, to: date)
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
        .accessibilityLabel("Price chart for \(security), \(range.rawValue)")
    }

    private func nearest(_ bars: [Bar], to date: Date) -> Bar? {
        let t = date.timeIntervalSince1970
        var lo = 0, hi = bars.count - 1
        guard hi >= 0 else { return nil }
        while lo < hi {
            let mid = (lo + hi) / 2
            if bars[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(bars[lo - 1].t - t) < abs(bars[lo].t - t) { return bars[lo - 1] }
        return bars[lo]
    }

    private func load() async {
        do {
            history = try await client.history(security, range: range)
        } catch {
            failure = error.localizedDescription
            onError(error)
        }
    }
}
