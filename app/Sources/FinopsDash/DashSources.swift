import FinopsCore
import Foundation

/// Which gateway service a terminal command shows, for dashboard `screen` and `news` widgets.
public enum DashSource {
    public struct Request: Sendable, Hashable {
        public let service: String
        public let params: [String: String]
    }

    /// Commands a screen widget can show, with a label for the builder's preset menu.
    public static let presets: [(label: String, command: String)] = [
        ("Crypto market", "CRYPTO"),
        ("Market heatmap", "HEAT 1D"),
        ("World markets", "MKT"),
        ("Top gainers", "MOVERS GAINERS"),
        ("Top losers", "MOVERS LOSERS"),
        ("Currency matrix", "FXM"),
        ("Central banks", "CBR"),
        ("Economy (FRED)", "ECON"),
        ("Economic calendar", "ECAL ECO TODAY"),
        ("Earnings calendar", "ECAL EARN WEEK"),
        ("ETF market", "ETF TOP"),
        ("Bitcoin order book", "BTC CRYPTO"),
        ("Performance (widget securities)", "PERF"),
        ("Correlation (widget securities)", "CORR 1Y"),
        ("Chart grid (widget securities)", "CHARTS 3M"),
    ]

    public static let newsPresets: [(label: String, command: String)] = [
        ("Crypto news", "NEWS CRYPTO"),
        ("Markets", "NEWS stock market"),
        ("Economy", "NEWS economy fed"),
        ("Bitcoin", "BTC CRYPTO NEWS"),
        ("Apple", "AAPL US EQ NEWS"),
    ]

    /// `securities` feeds the watchlist screens (PERF, CORR, CHARTS).
    public static func request(for command: String, securities: [String] = []) -> Request? {
        guard case .run(let security, let function, let args) = CommandParser.parse(command), let function else { return nil }
        let sec = security ?? ""
        let list = securities.joined(separator: ";")
        func first(_ allowed: [String], _ fallback: String) -> String { args.first { allowed.contains($0) } ?? fallback }
        switch function {
        case .crypto where sec.hasSuffix(" CRYPTO"): return Request(service: "crypto", params: ["security": sec])
        case .crypto: return Request(service: "crypto", params: ["quote": args.first ?? "USDT"])
        case .heat:
            let periods = ["1D", "1W", "1M", "3M", "YTD", "1Y"]
            return Request(service: "heatmap", params: ["period": first(periods, "1D"),
                                                        "sector": args.first { !periods.contains($0) } ?? ""])
        case .mkt: return Request(service: "market", params: [:])
        case .movers: return Request(service: "movers", params: ["kind": args.first ?? "GAINERS"])
        case .fxm: return Request(service: "fxmatrix", params: [:])
        case .cbr: return Request(service: "centralbanks", params: [:])
        case .econ: return Request(service: "econ", params: [:])
        case .wbi: return Request(service: "worldbank", params: ["indicator": args.first ?? "GDP"])
        case .ecal:
            let spans = ["TODAY", "WEEK", "2WEEKS"]
            return Request(service: "calendar", params: [
                "kind": args.contains("EARN") ? "EARN" : "ECO", "span": first(spans, "WEEK"),
                "region": args.first { !(["ECO", "EARN"] + spans).contains($0) } ?? "MAJOR"])
        case .etf where args.isEmpty && !sec.isEmpty: return Request(service: "etf", params: ["security": sec])
        case .etf: return Request(service: "etf", params: ["list": args.first ?? "TOP"])
        case .news where args.isEmpty && !sec.isEmpty: return Request(service: "news", params: ["security": sec])
        case .news: return Request(service: "news", params: ["query": args.joined(separator: " ")])
        case .perf: return Request(service: "perf", params: ["securities": list])
        case .corr: return Request(service: "corr", params: ["securities": list, "range": args.first ?? "1Y"])
        case .charts: return Request(service: "grid", params: ["securities": list, "range": args.first ?? "3M"])
        case .desc where !sec.isEmpty: return Request(service: "profile", params: ["security": sec])
        case .est where !sec.isEmpty: return Request(service: "estimates", params: ["security": sec])
        case .hold where !sec.isEmpty: return Request(service: "holders", params: ["security": sec])
        case .rels where !sec.isEmpty: return Request(service: "rels", params: ["security": sec])
        case .sent where !sec.isEmpty: return Request(service: "sentiment", params: ["security": sec])
        default: return nil
        }
    }
}

/// Bloomberg's own live streams (HLS, the ones bloomberg.com plays), so the Apple TV
/// can show them natively; tvOS has no web view for the YouTube embed.
public enum LiveChannel: String, CaseIterable, Identifiable, Sendable {
    case us, eu, originals
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .us: "Bloomberg TV (US)"
        case .eu: "Bloomberg TV (Europe)"
        case .originals: "Bloomberg Originals"
        }
    }

    public var url: URL {
        let file = switch self {
        case .us: "us"
        case .eu: "eu"
        case .originals: "phoenix-us"
        }
        return URL(string: "https://www.bloomberg.com/media-manifest/streams/\(file).m3u8")!
    }
}
