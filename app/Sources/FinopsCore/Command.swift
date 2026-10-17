import Foundation

/// Every screen in the terminal. The raw value is the canonical command.
public enum FunctionID: String, CaseIterable, Sendable, Hashable, Codable {
    // Security screens
    case quote = "QUOTE"
    case chart = "CHART"
    case desc = "DESC"
    case news = "NEWS"
    case fin = "FIN"
    case est = "EST"
    case evt = "EVT"
    case hold = "HOLD"
    case file = "FILE"
    case opt = "OPT"
    // Market screens
    case mkt = "MKT"
    case movers = "MOVERS"
    case scrn = "SCRN"
    case econ = "ECON"
    case curve = "CURVE"
    // Tools
    case port = "PORT"
    case alert = "ALERT"
    case help = "HELP"

    public enum Group: String, CaseIterable, Sendable {
        case security = "Security"
        case market = "Markets"
        case tools = "Tools"
    }

    public var group: Group {
        switch self {
        case .quote, .chart, .desc, .news, .fin, .est, .evt, .hold, .file, .opt: .security
        case .mkt, .movers, .scrn, .econ, .curve: .market
        case .port, .alert, .help: .tools
        }
    }

    public var aliases: [String] {
        switch self {
        case .quote: ["QUOTE", "Q"]
        case .chart: ["CHART", "CH", "GP"]
        case .desc: ["DESC", "DES"]
        case .news: ["NEWS", "N"]
        case .fin: ["FIN", "FA"]
        case .est: ["EST", "ANR"]
        case .evt: ["EVT", "DIV", "ERN"]
        case .hold: ["HOLD", "HDS"]
        case .file: ["FILE", "FILINGS"]
        case .opt: ["OPT", "OMON"]
        case .mkt: ["MKT", "WEI"]
        case .movers: ["MOVERS", "MOST"]
        case .scrn: ["SCRN", "EQS"]
        case .econ: ["ECON"]
        case .curve: ["CURVE"]
        case .port: ["PORT"]
        case .alert: ["ALERT"]
        case .help: ["HELP", "?"]
        }
    }

    public var title: String {
        switch self {
        case .quote: "Quote"
        case .chart: "Chart"
        case .desc: "Description"
        case .news: "News"
        case .fin: "Financials"
        case .est: "Estimates"
        case .evt: "Events"
        case .hold: "Holders"
        case .file: "Filings"
        case .opt: "Options"
        case .mkt: "World markets"
        case .movers: "Movers"
        case .scrn: "Screener"
        case .econ: "Economy"
        case .curve: "Yield curve"
        case .port: "Portfolio"
        case .alert: "Alerts"
        case .help: "Help"
        }
    }

    public var summary: String {
        switch self {
        case .quote: "Live quote and day statistics"
        case .chart: "Chart. Args: range, LINE|CANDLE, VOL, SMA20 SMA50 SMA200 EMA20 BB RSI MACD, VS <securities>"
        case .desc: "Company profile, valuation, margins, dividend"
        case .news: "Headlines for the security, or NEWS <words> for any topic"
        case .fin: "Financial statements from SEC filings. Args: A|Q, IS|BS|CF"
        case .est: "Analyst ratings, price targets, EPS and revenue estimates"
        case .evt: "Earnings dates and history, dividends, splits"
        case .hold: "Institutional, fund and insider holders"
        case .file: "SEC filings. Args: ALL|10-K|10-Q|8-K|INSIDER|PROXY"
        case .opt: "Option chain. Args: expiry (YYYY-MM-DD)"
        case .mkt: "Indices, rates, currencies, commodities, crypto"
        case .movers: "Top movers. Args: GAINERS|LOSERS|ACTIVE|SMALLCAP|SHORTED|UNDERVALUED|GROWTH"
        case .scrn: "Equity screener. Args: filters like MCAP>10B PE<20 SECTOR=TECHNOLOGY"
        case .econ: "Macro dashboard (FRED). ECON <series> [range] [YOY], ECON SEARCH <words>"
        case .curve: "US Treasury yield curve vs 1M, 6M and 1Y ago"
        case .port: "Portfolio with live P&L. <security> PORT ADD <qty> <cost>"
        case .alert: "Price alerts. <security> ALERT > <price> or ALERT < <price>"
        case .help: "All functions and keys"
        }
    }

    public var needsSecurity: Bool { group == .security && self != .news }

    public var systemImage: String {
        switch self {
        case .quote: "dollarsign"
        case .chart: "chart.xyaxis.line"
        case .desc: "building.2"
        case .news: "newspaper"
        case .fin: "tablecells"
        case .est: "target"
        case .evt: "calendar"
        case .hold: "person.3"
        case .file: "doc.text"
        case .opt: "square.stack.3d.up"
        case .mkt: "globe"
        case .movers: "arrow.up.arrow.down"
        case .scrn: "line.3.horizontal.decrease.circle"
        case .econ: "building.columns"
        case .curve: "chart.line.uptrend.xyaxis"
        case .port: "briefcase"
        case .alert: "bell"
        case .help: "questionmark.circle"
        }
    }

    public static func matching(_ token: String) -> FunctionID? {
        allCases.first { $0.aliases.contains(token) }
    }
}

/// What the user typed on the command line, before anything is resolved.
public enum Command: Equatable, Sendable {
    /// `[security] [function] [args…]`. Missing parts keep the panel's current value.
    case run(security: String?, function: FunctionID?, args: [String])
    /// A bare number: trigger the numbered action on the current screen.
    case action(Int)
    /// `<security> WATCH`: add to the current watchlist.
    case watch(security: String?)
    case empty
}

public enum CommandParser {
    public static func parse(_ input: String) -> Command {
        let tokens = input.uppercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return .empty }

        if tokens.count == 1, let n = Int(tokens[0]), n > 0 {
            return .action(n)
        }

        if tokens.last == "WATCH" {
            let security = tokens.dropLast().joined(separator: " ")
            return .watch(security: security.isEmpty ? nil : security)
        }

        // Noun first, then verb: everything before the first function alias is the security.
        if let index = tokens.firstIndex(where: { FunctionID.matching($0) != nil }) {
            let security = tokens[..<index].joined(separator: " ")
            return .run(
                security: security.isEmpty ? nil : security,
                function: FunctionID.matching(tokens[index]),
                args: Array(tokens[(index + 1)...])
            )
        }
        return .run(security: tokens.joined(separator: " "), function: nil, args: [])
    }
}
