import FinopsCore
import SwiftUI

/// Renders a dashboard on its logical 1200 × 675 canvas (16:9). Hosts scale it:
/// ×1.6 on a 1080p Apple TV, down to fit in the Mac builder's preview.
public struct DashboardView: View {
    public static let canvas = CGSize(width: 1200, height: 675)
    public static let gap: CGFloat = 6
    /// Ticker band thickness: a single line across, or a narrow column on a side.
    public static let bandThickness: (horizontal: CGFloat, vertical: CGFloat) = (28, 170)

    let dashboard: Dashboard
    let client: DataClient?
    var selection: UUID?
    var onSelect: ((UUID) -> Void)?

    public init(dashboard: Dashboard, client: DataClient?, selection: UUID? = nil, onSelect: ((UUID) -> Void)? = nil) {
        self.dashboard = dashboard
        self.client = client
        self.selection = selection
        self.onSelect = onSelect
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            Palette.background
            if let band = dashboard.band, let client {
                let frame = Self.bandFrame(dashboard)
                TickerWidget(widget: band, client: client)
                    .frame(width: frame.width, height: frame.height)
                    .background(Palette.surface)
                    .overlay(alignment: Self.innerEdge(dashboard.edge)) {
                        Rectangle().fill(Palette.accent.opacity(0.6))
                            .frame(width: dashboard.edge.isVertical ? 1 : nil, height: dashboard.edge.isVertical ? nil : 1)
                    }
                    .clipped()
                    .offset(x: frame.minX, y: frame.minY)
            }
            ForEach(dashboard.widgets) { widget in
                let frame = Self.frame(of: widget, in: dashboard)
                WidgetView(widget: widget, client: client)
                    // Fixed tile: content never pushes the tile bigger or spills onto neighbours.
                    .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                    .clipped()
                    .overlay {
                        if selection == widget.id {
                            RoundedRectangle(cornerRadius: 4).stroke(Palette.selection, lineWidth: 2)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect?(widget.id) }
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .topLeading)
        .clipped()
    }

    /// The area the widget grid fills: the canvas minus the ticker band, if any.
    public static func gridArea(_ dashboard: Dashboard) -> CGRect {
        let full = CGRect(origin: .zero, size: canvas)
        guard dashboard.band != nil else { return full }
        let (h, v) = bandThickness
        switch dashboard.edge {
        case .bottom: return CGRect(x: 0, y: 0, width: full.width, height: full.height - h)
        case .top: return CGRect(x: 0, y: h, width: full.width, height: full.height - h)
        case .left: return CGRect(x: v, y: 0, width: full.width - v, height: full.height)
        case .right: return CGRect(x: 0, y: 0, width: full.width - v, height: full.height)
        }
    }

    public static func bandFrame(_ dashboard: Dashboard) -> CGRect {
        let (h, v) = bandThickness
        switch dashboard.edge {
        case .bottom: return CGRect(x: 0, y: canvas.height - h, width: canvas.width, height: h)
        case .top: return CGRect(x: 0, y: 0, width: canvas.width, height: h)
        case .left: return CGRect(x: 0, y: 0, width: v, height: canvas.height)
        case .right: return CGRect(x: canvas.width - v, y: 0, width: v, height: canvas.height)
        }
    }

    private static func innerEdge(_ edge: Dashboard.BandEdge) -> Alignment {
        switch edge {
        case .bottom: .top
        case .top: .bottom
        case .left: .trailing
        case .right: .leading
        }
    }

    /// Where a widget sits on the canvas.
    public static func frame(of widget: DashWidget, in dashboard: Dashboard) -> CGRect {
        let area = gridArea(dashboard)
        let cellW = (area.width - gap) / CGFloat(max(dashboard.columns, 1))
        let cellH = (area.height - gap) / CGFloat(max(dashboard.rows, 1))
        return CGRect(x: area.minX + gap + CGFloat(widget.x) * cellW, y: area.minY + gap + CGFloat(widget.y) * cellH,
                      width: max(CGFloat(widget.w) * cellW - gap, 10), height: max(CGFloat(widget.h) * cellH - gap, 10))
    }
}

/// One widget: panel chrome plus its kind's content.
public struct WidgetView: View {
    let widget: DashWidget
    let client: DataClient?

    public init(widget: DashWidget, client: DataClient?) {
        self.widget = widget
        self.client = client
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsTitle {
                Text(title.uppercased())
                    .font(.terminalLabel).tracking(1)
                    .foregroundStyle(Palette.accent)
                    .lineLimit(1)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Self.bare.contains(widget.kind) ? 0 : 8)
        .background(widget.kind == .carousel ? Color.clear : Palette.surface, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(widget.kind == .carousel ? Color.clear : Palette.border))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// Kinds drawn edge to edge (a slideshow's slides bring their own panel).
    private static let bare: Set<DashWidget.Kind> = [.video, .ticker, .carousel]

    private var showsTitle: Bool { ![.video, .clock, .text, .ticker, .carousel].contains(widget.kind) }

    private var title: String {
        if let title = widget.title, !title.isEmpty { return title }
        switch widget.kind {
        case .chart, .quotes, .compare, .diagram:
            let list = widget.securities.prefix(3).joined(separator: ", ")
            return list.isEmpty ? widget.kind.title : "\(list) · \(widget.range)"
        case .screen, .news: return widget.command ?? widget.kind.title
        default: return widget.kind.title
        }
    }

    @ViewBuilder
    private var content: some View {
        if let client {
            switch widget.kind {
            case .quotes: QuotesWidget(widget: widget, client: client)
            case .ticker: TickerWidget(widget: widget, client: client)
            case .carousel: CarouselWidget(widget: widget, client: client)
            case .chart: ChartWidget(widget: widget, client: client)
            case .compare: CompareWidget(widget: widget, client: client)
            case .diagram: DiagramWidget(widget: widget, client: client)
            case .screen: ScreenWidget(widget: widget, client: client)
            case .news: NewsWidget(widget: widget, client: client)
            case .video: VideoWidget(widget: widget)
            case .clock: ClockWidget()
            case .text: TextWidget(widget: widget)
            }
        } else {
            switch widget.kind {
            case .video: VideoWidget(widget: widget)
            case .clock: ClockWidget()
            case .text: TextWidget(widget: widget)
            case .carousel: CarouselWidget(widget: widget, client: nil)
            default: WidgetMessage(text: "Waiting for data…")
            }
        }
    }
}

struct WidgetMessage: View {
    let text: String
    var body: some View {
        Text(text).font(.terminalSmall).foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Short display name for a typed security ("AAPL US EQ" -> "AAPL", "ETH EUR CRYPTO" -> "ETH/EUR").
func shortName(_ typed: String) -> String {
    let classes: Set<String> = ["EQ", "ETF", "FX", "CMD", "IDX", "CRYPTO", "FUT", "GOV", "CORP"]
    var tokens = typed.split(separator: " ").map(String.init)
    let isCrypto = tokens.last == "CRYPTO"
    if let last = tokens.last, classes.contains(last), tokens.count > 1 { tokens.removeLast() }
    if isCrypto { return tokens.joined(separator: "/") }
    return tokens.first ?? typed
}
