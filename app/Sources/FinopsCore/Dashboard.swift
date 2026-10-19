import Foundation

/// A wall-screen layout built on the Mac and shown on the Apple TV.
/// Widgets sit on a grid of `columns` × `rows` cells over a 16:9 canvas.
public struct Dashboard: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var columns: Int
    public var rows: Int
    public var widgets: [DashWidget]

    public init(id: UUID = UUID(), name: String, columns: Int = 12, rows: Int = 8, widgets: [DashWidget] = []) {
        self.id = id
        self.name = name
        self.columns = columns
        self.rows = rows
        self.widgets = widgets
    }

    /// First free spot for a w × h widget (top-left first), or the bottom-left corner if full.
    public func freeSlot(w: Int, h: Int) -> (x: Int, y: Int) {
        findSlot(w: w, h: h) ?? (0, max(0, rows - h))
    }

    public func findSlot(w: Int, h: Int) -> (x: Int, y: Int)? {
        for y in 0...max(0, rows - h) {
            for x in 0...max(0, columns - w) {
                let candidate = DashWidget(kind: .text, x: x, y: y, w: w, h: h)
                if !widgets.contains(where: { $0.overlaps(candidate) }) { return (x, y) }
            }
        }
        return nil
    }

    /// Free the bottom row for a full-width band (a ticker tape): widgets touching it lose a row.
    public mutating func makeRoomAtBottom() {
        for i in widgets.indices where widgets[i].y + widgets[i].h == rows {
            if widgets[i].h > 1 { widgets[i].h -= 1 } else { widgets[i].y = max(0, widgets[i].y - 1) }
        }
    }
}

/// One tile on a dashboard. Settings are flat so the builder's inspector and the
/// wire format stay simple; each kind reads the fields it needs.
public struct DashWidget: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case quotes, ticker, chart, compare, diagram, screen, news, video, clock, text, carousel
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .quotes: "Live quotes"
            case .ticker: "Ticker tape"
            case .carousel: "Slideshow"
            case .chart: "Chart"
            case .compare: "Comparison chart"
            case .diagram: "Diagram"
            case .screen: "Terminal screen"
            case .news: "Headlines"
            case .video: "Live TV"
            case .clock: "World clocks"
            case .text: "Title / note"
            }
        }

        public var systemImage: String {
            switch self {
            case .quotes: "dollarsign.square"
            case .ticker: "text.line.first.and.arrowtriangle.forward"
            case .carousel: "rectangle.stack"
            case .chart: "chart.xyaxis.line"
            case .compare: "chart.line.uptrend.xyaxis"
            case .diagram: "chart.bar.xaxis"
            case .screen: "rectangle.grid.2x2"
            case .news: "newspaper"
            case .video: "play.tv"
            case .clock: "clock"
            case .text: "textformat"
            }
        }

        /// Default footprint in grid cells.
        public var defaultSize: (w: Int, h: Int) {
            switch self {
            case .quotes: (4, 2)
            case .ticker: (12, 1)
            case .carousel: (6, 4)
            case .chart, .compare, .diagram: (4, 3)
            case .screen: (6, 4)
            case .news: (4, 4)
            case .video: (6, 4)
            case .clock: (6, 1)
            case .text: (4, 1)
            }
        }
    }

    public enum Style: String, Codable, Sendable, CaseIterable, Identifiable {
        // chart
        case area, line, candle
        // diagram
        case bars, columns, donut, treemap, tiles
        public var id: String { rawValue }

        public static let chartStyles: [Style] = [.area, .line, .candle]
        public static let diagramStyles: [Style] = [.bars, .columns, .donut, .treemap, .tiles]
    }

    /// What a diagram measures for each security.
    public enum Metric: String, Codable, Sendable, CaseIterable, Identifiable {
        case change, price, volume, marketCap
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .change: "% change over the range"
            case .price: "Last price"
            case .volume: "Volume"
            case .marketCap: "Market cap"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    public var title: String?
    public var x: Int
    public var y: Int
    public var w: Int
    public var h: Int
    /// Typed securities, e.g. "AAPL US EQ", "BTC CRYPTO" (quotes, chart, compare, diagram, news).
    public var securities: [String]
    public var range: String          // ChartRange raw value
    public var interval: String?      // ChartConfig.Interval raw value
    public var style: Style
    public var metric: Metric
    public var overlays: [String]     // ChartConfig.Overlay raw values (SMA20, BB…)
    /// Terminal command for `screen` (e.g. "CRYPTO", "HEAT 1D") and `news` (e.g. "NEWS CRYPTO").
    public var command: String?
    public var channel: String?       // video channel id
    public var muted: Bool
    public var text: String?          // text widget body
    /// For `screen`: the id or title of the single block to show (nil = the main block).
    public var part: String?
    /// For `carousel`: the widgets it cycles through (their position fields are ignored).
    public var slides: [DashWidget]
    /// For `carousel`: seconds per slide.
    public var seconds: Int
    /// For `ticker`: scroll speed, 1 (slow) to 3 (fast).
    public var speed: Int

    public init(id: UUID = UUID(), kind: Kind, title: String? = nil, x: Int = 0, y: Int = 0, w: Int? = nil, h: Int? = nil,
                securities: [String] = [], range: String = "1D", interval: String? = nil, style: Style? = nil,
                metric: Metric = .change, overlays: [String] = [], command: String? = nil, channel: String? = nil,
                muted: Bool = true, text: String? = nil, part: String? = nil, slides: [DashWidget] = [],
                seconds: Int = 15, speed: Int = 2) {
        self.id = id
        self.kind = kind
        self.title = title
        self.x = x
        self.y = y
        self.w = w ?? kind.defaultSize.w
        self.h = h ?? kind.defaultSize.h
        self.securities = securities
        self.range = range
        self.interval = interval
        self.style = style ?? (kind == .diagram ? .bars : .area)
        self.metric = metric
        self.overlays = overlays
        self.command = command
        self.channel = channel
        self.muted = muted
        self.text = text
        self.part = part
        self.slides = slides
        self.seconds = seconds
        self.speed = speed
    }

    /// A ready-to-show widget of `kind` with sensible content.
    public static func starter(_ kind: Kind) -> DashWidget {
        switch kind {
        case .quotes: DashWidget(kind: .quotes, securities: ["SPX IDX", "NDX IDX", "BTC CRYPTO", "EURUSD FX"])
        case .ticker: DashWidget(kind: .ticker, securities: tickerTape)
        case .carousel: DashWidget(kind: .carousel, slides: [
            DashWidget(kind: .chart, securities: ["BTC CRYPTO"], range: "1D", interval: "5MIN"),
            DashWidget(kind: .chart, securities: ["ETH CRYPTO"], range: "1D", interval: "5MIN"),
            DashWidget(kind: .screen, title: "Market heatmap", command: "HEAT 1D"),
        ])
        case .chart: DashWidget(kind: .chart, securities: ["BTC CRYPTO"], range: "1D", interval: "5MIN")
        case .compare: DashWidget(kind: .compare, securities: ["SPX IDX", "NDX IDX", "BTC CRYPTO"], range: "1M")
        case .diagram: DashWidget(kind: .diagram, title: "Megacaps, 1 month",
                                  securities: ["AAPL US EQ", "MSFT US EQ", "NVDA US EQ", "AMZN US EQ", "GOOGL US EQ", "META US EQ"],
                                  range: "1M", style: .bars)
        case .screen: DashWidget(kind: .screen, command: "CRYPTO")
        case .news: DashWidget(kind: .news, command: "NEWS CRYPTO")
        case .video: DashWidget(kind: .video, channel: "us")
        case .clock: DashWidget(kind: .clock)
        case .text: DashWidget(kind: .text, text: "Markets")
        }
    }

    /// A Wall Street-style tape: indices, megacaps, rates, FX, commodities, crypto.
    public static let tickerTape = ["SPX IDX", "NDX IDX", "INDU IDX", "CAC IDX", "DAX IDX", "UKX IDX", "NKY IDX",
                                    "AAPL US EQ", "MSFT US EQ", "NVDA US EQ", "AMZN US EQ", "TSLA US EQ",
                                    "EURUSD FX", "USDJPY FX", "CL1 CMD", "GC1 CMD", "BTC CRYPTO", "ETH CRYPTO", "SOL CRYPTO"]

    public func overlaps(_ other: DashWidget) -> Bool {
        x < other.x + other.w && other.x < x + w && y < other.y + other.h && other.y < y + h
    }

    // Tolerant decoding: missing fields fall back to defaults, so older files keep loading.
    private enum CodingKeys: String, CodingKey {
        case id, kind, title, x, y, w, h, securities, range, interval, style, metric, overlays, command, channel, muted, text, part
        case slides, seconds, speed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(), kind: kind,
            title: try c.decodeIfPresent(String.self, forKey: .title),
            x: try c.decodeIfPresent(Int.self, forKey: .x) ?? 0, y: try c.decodeIfPresent(Int.self, forKey: .y) ?? 0,
            w: try c.decodeIfPresent(Int.self, forKey: .w), h: try c.decodeIfPresent(Int.self, forKey: .h),
            securities: try c.decodeIfPresent([String].self, forKey: .securities) ?? [],
            range: try c.decodeIfPresent(String.self, forKey: .range) ?? "1D",
            interval: try c.decodeIfPresent(String.self, forKey: .interval),
            style: try c.decodeIfPresent(Style.self, forKey: .style),
            metric: try c.decodeIfPresent(Metric.self, forKey: .metric) ?? .change,
            overlays: try c.decodeIfPresent([String].self, forKey: .overlays) ?? [],
            command: try c.decodeIfPresent(String.self, forKey: .command),
            channel: try c.decodeIfPresent(String.self, forKey: .channel),
            muted: try c.decodeIfPresent(Bool.self, forKey: .muted) ?? true,
            text: try c.decodeIfPresent(String.self, forKey: .text),
            part: try c.decodeIfPresent(String.self, forKey: .part),
            slides: try c.decodeIfPresent([DashWidget].self, forKey: .slides) ?? [],
            seconds: try c.decodeIfPresent(Int.self, forKey: .seconds) ?? 15,
            speed: try c.decodeIfPresent(Int.self, forKey: .speed) ?? 2)
    }
}

public extension Dashboard {
    /// The layout new installs start with.
    static var starter: Dashboard {
        Dashboard(name: "Markets", widgets: [
            DashWidget(kind: .clock, x: 0, y: 0, w: 12, h: 1),
            DashWidget(kind: .video, x: 0, y: 1, w: 6, h: 4, channel: "us"),
            DashWidget(kind: .quotes, x: 6, y: 1, w: 6, h: 2,
                       securities: ["SPX IDX", "NDX IDX", "CAC IDX", "EURUSD FX", "BTC CRYPTO", "ETH CRYPTO"]),
            DashWidget(kind: .chart, x: 6, y: 3, w: 6, h: 2, securities: ["BTC CRYPTO"], range: "1D", interval: "5MIN"),
            DashWidget(kind: .screen, title: "Crypto market", x: 0, y: 5, w: 4, h: 2, command: "CRYPTO"),
            DashWidget(kind: .compare, x: 4, y: 5, w: 4, h: 2, securities: ["SPX IDX", "NDX IDX", "CAC IDX"], range: "1M"),
            DashWidget(kind: .news, x: 8, y: 5, w: 4, h: 2, command: "NEWS CRYPTO"),
            DashWidget(kind: .ticker, x: 0, y: 7, w: 12, h: 1, securities: DashWidget.tickerTape),
        ])
    }
}
