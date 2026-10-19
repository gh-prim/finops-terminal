import AVFoundation
import FinopsCore
import SwiftUI

// MARK: Terminal screen

/// Any terminal screen (CRYPTO, HEAT, MKT, ECAL…), or one block of it, refreshed in place.
struct ScreenWidget: View {
    let widget: DashWidget
    let client: DataClient

    @State private var document: GatewayDocument?
    @State private var failure: String?

    var body: some View {
        Group {
            if let document {
                let blocks = DashBlocks.pick(document.blocks, part: widget.part)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(blocks) { DashBlockView(block: $0) }
                }
            } else if let failure {
                WidgetMessage(text: failure)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(widget.command ?? "")|\(widget.securities)") {
            guard let request = DashSource.request(for: widget.command ?? "", securities: widget.securities) else {
                failure = "Unsupported command: \(widget.command ?? "none")"
                return
            }
            while !Task.isCancelled {
                do {
                    document = try await client.document(request.service, request.params)
                    failure = nil
                } catch {
                    failure = error.localizedDescription
                }
                try? await Task.sleep(for: .seconds(max(document?.refresh ?? 60, 5)))
            }
        }
    }
}

public enum DashBlocks {
    /// Blocks a dashboard can show (navigation buttons and long text make no sense on a wall).
    public static func displayable(_ blocks: [GatewayDocument.Block]) -> [GatewayDocument.Block] {
        blocks.filter {
            switch $0 {
            case .choices, .text, .unknown: false
            default: true
            }
        }
    }

    public static func title(of block: GatewayDocument.Block) -> String {
        switch block {
        case .table(let b): b.title ?? "Table"
        case .kv(let b): b.title ?? "Figures"
        case .treemap(let b): b.title ?? "Treemap"
        case .matrix(let b): b.title ?? "Matrix"
        case .scatter(let b): b.title ?? "Scatter"
        case .graph(let b): b.title ?? "Graph"
        case .bars(let b): b.title ?? "Bars"
        case .series(let b): b.title ?? "Series"
        case .donut(let b): b.title ?? "Donut"
        case .sparkgrid(let b): b.title ?? "Small charts"
        case .map(let b): b.title ?? "Map"
        case .text(let b): b.title ?? "Text"
        case .choices: "Choices"
        case .unknown: "Unknown"
        }
    }

    /// `part` names one block; nil shows the screen's main block (its first chart, else its
    /// first table), since a whole terminal screen is too tall for a tile; `all` stacks everything.
    public static let all = "ALL"

    static func pick(_ blocks: [GatewayDocument.Block], part: String?) -> [GatewayDocument.Block] {
        let shown = displayable(blocks)
        if part == all { return shown }
        if let part, !part.isEmpty, let match = shown.first(where: { $0.id == part || title(of: $0) == part }) {
            return [match]
        }
        return primary(shown).map { [$0] } ?? []
    }

    static func primary(_ blocks: [GatewayDocument.Block]) -> GatewayDocument.Block? {
        blocks.first {
            switch $0 {
            case .table, .kv: false
            default: true
            }
        } ?? blocks.first
    }
}

/// A document block sized for a wall: tables show as many rows as fit, no scrolling.
struct DashBlockView: View {
    let block: GatewayDocument.Block

    var body: some View {
        switch block {
        case .table(let table): DashTable(table: table)
        case .kv(let kv): DashKV(block: kv)
        case .treemap(let b): TreemapBlockView(block: b, run: { _ in }, minHeight: 0).frame(maxHeight: .infinity)
        case .matrix(let b): MatrixBlockView(block: b, run: { _ in })
        case .scatter(let b): ScatterBlockView(block: b, run: { _ in })
        case .graph(let b): GraphBlockView(block: b, run: { _ in })
        case .bars(let b): BarsBlockView(block: b, run: { _ in })
        case .series(let b): SeriesBlockView(block: b)
        case .donut(let b): DonutBlockView(block: b)
        case .sparkgrid(let b): SparkGridBlockView(block: b, run: { _ in })
        case .map(let b): MapBlockView(block: b, run: { _ in }, height: nil)
        default: EmptyView()
        }
    }
}

struct DashTable: View {
    let table: GatewayDocument.TableBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let title = table.title { SectionLabel(title: title) }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    ForEach(Array(table.columns.enumerated()), id: \.offset) { _, column in
                        Text(column.label).font(.terminalLabel).foregroundStyle(Palette.muted)
                            .gridColumnAlignment(Format.isNumeric(column.kind) ? .trailing : .leading)
                    }
                }
                ForEach(Array(table.rows.prefix(40).enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { i, value in
                            let kind = i > 0 ? (row.kind ?? table.columns[safe: i]?.kind ?? .text) : (table.columns.first?.kind ?? .text)
                            Text(Format.value(value, kind: kind))
                                .font(.terminalSmall)
                                .foregroundStyle(i == 0 ? Palette.accent : Format.color(value, kind: kind))
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}

struct DashKV: View {
    let block: GatewayDocument.KVBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let title = block.title { SectionLabel(title: title) }
            ForEach(block.items, id: \.self) { item in
                HStack {
                    Text(item.label).foregroundStyle(Palette.muted)
                    Spacer()
                    Text(Format.value(item.value, kind: item.kind)).foregroundStyle(Format.color(item.value, kind: item.kind))
                }
                .font(.terminalSmall)
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: Headlines

/// Headlines from a NEWS command, paging through when they don't all fit.
struct NewsWidget: View {
    let widget: DashWidget
    let client: DataClient

    @State private var rows: [GatewayDocument.Row] = []
    @State private var page = 0

    var body: some View {
        GeometryReader { geo in
            let perPage = max(Int(geo.size.height / 44), 1)
            let pages = max(Int(ceil(Double(rows.count) / Double(perPage))), 1)
            let shown = rows.dropFirst((page % pages) * perPage).prefix(perPage)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.cells[safe: 1]?.string ?? "")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.text).lineLimit(2)
                        Text([row.cells[safe: 2]?.string, row.cells.first.map { Format.value($0, kind: .datetime) }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.terminalSmall).foregroundStyle(Palette.muted)
                    }
                }
            }
            .animation(.easeInOut, value: page)
        }
        .task(id: widget.command) {
            let request = DashSource.request(for: widget.command ?? "NEWS CRYPTO") ?? .init(service: "news", params: ["query": "CRYPTO"])
            var lastLoad = Date.distantPast
            while !Task.isCancelled {
                if Date.now.timeIntervalSince(lastLoad) > 120,
                   let document = try? await client.document(request.service, request.params) {
                    lastLoad = .now
                    rows = document.blocks.compactMap { if case .table(let t) = $0 { t.rows } else { nil } }.flatMap { $0 }
                }
                try? await Task.sleep(for: .seconds(12))
                page += 1
            }
        }
    }
}

// MARK: Live TV

/// Bloomberg's live HLS stream, played natively (works on tvOS, which has no web view).
struct VideoWidget: View {
    let widget: DashWidget

    @State private var player: AVPlayer?

    private var channel: LiveChannel { LiveChannel(rawValue: widget.channel ?? "us") ?? .us }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            if let player { PlayerLayerView(player: player) }
            Text(channel.title.uppercased())
                .font(.terminalLabel).tracking(1).foregroundStyle(Palette.accent)
                .padding(6).background(.black.opacity(0.5)).padding(6)
        }
        .task(id: "\(channel.rawValue)|\(widget.muted)") {
            let player = AVPlayer(url: channel.url)
            player.isMuted = widget.muted
            player.play()
            self.player = player
        }
        .onDisappear { player?.pause() }
    }
}

#if os(macOS)
import AppKit

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVPlayerLayer)?.player = player
    }
}
#else
import UIKit

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        view.playerLayer.player = player
    }
}
#endif

// MARK: Clocks & text

/// Market clocks with open/closed status (regular sessions, weekdays).
struct ClockWidget: View {
    private struct Market { let code: String; let zone: String; let open: Int; let close: Int }  // minutes after midnight, local

    private static let markets = [
        Market(code: "NEW YORK", zone: "America/New_York", open: 570, close: 960),
        Market(code: "LONDON", zone: "Europe/London", open: 480, close: 990),
        Market(code: "PARIS", zone: "Europe/Paris", open: 540, close: 1050),
        Market(code: "TOKYO", zone: "Asia/Tokyo", open: 540, close: 930),
        Market(code: "HONG KONG", zone: "Asia/Hong_Kong", open: 570, close: 960),
        Market(code: "SYDNEY", zone: "Australia/Sydney", open: 600, close: 960),
    ]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 0) {
                ForEach(Self.markets, id: \.code) { market in
                    let (time, open) = status(market, at: context.date)
                    VStack(spacing: 1) {
                        HStack(spacing: 4) {
                            Circle().fill(open ? Palette.up : Palette.muted.opacity(0.5)).frame(width: 6, height: 6)
                            Text(market.code).font(.terminalLabel).tracking(1).foregroundStyle(Palette.muted)
                        }
                        Text(time).font(.system(size: 20, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.text)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func status(_ market: Market, at date: Date) -> (String, Bool) {
        guard let zone = TimeZone(identifier: market.zone) else { return ("—", false) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let weekday = parts.weekday ?? 1
        let open = (2...6).contains(weekday) && minutes >= market.open && minutes < market.close
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.dateFormat = "HH:mm:ss"
        return (formatter.string(from: date), open)
    }
}

struct TextWidget: View {
    let widget: DashWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(widget.text ?? widget.title ?? "")
                .font(.system(size: 26, weight: .bold, design: .monospaced))
                .foregroundStyle(Palette.accent)
                .minimumScaleFactor(0.4)
            if let subtitle = widget.title, widget.text != nil, !subtitle.isEmpty {
                Text(subtitle).font(.terminalSmall).foregroundStyle(Palette.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
