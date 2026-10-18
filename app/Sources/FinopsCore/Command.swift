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
    case rv = "RV"
    case rels = "RELS"
    case dcf = "DCF"
    case sent = "SENT"
    // Market screens
    case mkt = "MKT"
    case movers = "MOVERS"
    case scrn = "SCRN"
    case econ = "ECON"
    case curve = "CURVE"
    case heat = "HEAT"
    case fxm = "FXM"
    case wbi = "WBI"
    case cbr = "CBR"
    case ecal = "ECAL"
    case etf = "ETF"
    case crypto = "CRYPTO"
    case tv = "TV"
    // Tools
    case port = "PORT"
    case alert = "ALERT"
    case perf = "PERF"
    case charts = "CHARTS"
    case corr = "CORR"
    case quant = "QUANT"
    case read = "READ"
    case help = "HELP"

    public enum Group: String, CaseIterable, Sendable {
        case security = "Security"
        case market = "Markets"
        case tools = "Tools"
    }

    public var group: Group {
        switch self {
        case .quote, .chart, .desc, .news, .fin, .est, .evt, .hold, .file, .opt, .rv, .rels, .dcf, .sent: .security
        case .mkt, .movers, .scrn, .econ, .curve, .heat, .fxm, .wbi, .cbr, .ecal, .etf, .crypto, .tv: .market
        case .port, .alert, .perf, .charts, .corr, .quant, .read, .help: .tools
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
        case .rv: ["RV"]
        case .rels: ["RELS"]
        case .dcf: ["DCF"]
        case .sent: ["SENT"]
        case .heat: ["HEAT", "IMAP"]
        case .fxm: ["FXM", "FXC"]
        case .wbi: ["WBI"]
        case .cbr: ["CBR"]
        case .ecal: ["ECAL"]
        case .etf: ["ETF"]
        case .crypto: ["CRYPTO", "CRYP", "XBT"]
        case .tv: ["TV", "BTV"]
        case .perf: ["PERF"]
        case .charts: ["CHARTS"]
        case .corr: ["CORR"]
        case .quant: ["QUANT", "CALC"]
        case .read: ["READ", "WEB"]
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
        case .rv: "Relative value"
        case .rels: "Relationships"
        case .dcf: "DCF valuation"
        case .sent: "Sentiment"
        case .heat: "Market heatmap"
        case .fxm: "Currency matrix"
        case .wbi: "World Bank"
        case .cbr: "Central banks"
        case .ecal: "Economic calendar"
        case .etf: "ETFs"
        case .crypto: "Crypto"
        case .tv: "Live TV"
        case .perf: "Performance"
        case .charts: "Chart grid"
        case .corr: "Correlation"
        case .quant: "Quant calculators"
        case .read: "Reader"
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
        case .rv: "Valuation scatter vs industry peers. Args: X Y among PE FPE EVEBITDA PS PB GROWTH MARGIN ROE RET1Y"
        case .rels: "Relationship graph: industry peers, institutional holders, funds"
        case .dcf: "Discounted cash flow from SEC filings. Args: W<wacc%> G<growth%> T<terminal%>"
        case .sent: "Headline sentiment score from recent news"
        case .heat: "Treemap of the largest US companies. Args: 1D 1W 1M 3M YTD 1Y, sector"
        case .fxm: "Cross-rate matrix of major currencies, with 1-day moves"
        case .wbi: "World Bank indicators by country. Args: GDP CPI UNEMP DEBT CA GDPPC SIZE"
        case .cbr: "Central bank policy rates (FRED)"
        case .ecal: "Economic releases (actual/expected/previous) and earnings. Args: ECO|EARN, TODAY|WEEK|2WEEKS, region"
        case .etf: "ETF market (TOP, PERFORMERS), or <etf> ETF for holdings, sectors, costs"
        case .crypto: "Live crypto market from Binance (USDT USDC EUR BTC), or <coin> CRYPTO for order book and trades"
        case .tv: "Live business TV (Bloomberg on YouTube). Args: BLOOMBERG, BLOOMBERG-LIVE or a YouTube video ID"
        case .perf: "Watchlist performance heat table (1D … 1Y, volatility)"
        case .charts: "Small-multiple charts of the watchlist. Args: 5D 1M 3M 1Y"
        case .corr: "Correlation matrix of the watchlist. Args: 3M 6M 1Y 2Y 5Y"
        case .quant: "CFA-style calculators: time value, bonds, Black–Scholes options"
        case .read: "Read an article or web page in the terminal: READ <link>. News headlines open here"
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
        case .rv: "circle.grid.cross"
        case .rels: "point.3.connected.trianglepath.dotted"
        case .dcf: "function"
        case .sent: "face.smiling"
        case .heat: "square.grid.3x3.fill"
        case .fxm: "dollarsign.arrow.circlepath"
        case .wbi: "globe.europe.africa"
        case .cbr: "building.columns.circle"
        case .ecal: "calendar.badge.clock"
        case .etf: "chart.pie"
        case .crypto: "bitcoinsign.circle"
        case .tv: "play.tv"
        case .perf: "tablecells.badge.ellipsis"
        case .charts: "square.grid.2x2"
        case .corr: "circle.hexagongrid"
        case .quant: "x.squareroot"
        case .read: "doc.richtext"
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
        let original = input.split(whereSeparator: \.isWhitespace).map(String.init)
        let tokens = original.map { $0.uppercased() }
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
            var security = tokens[..<index].joined(separator: " ")
            var function = FunctionID.matching(tokens[index])
            var argsStart = index + 1
            // After a coin, CRYPTO is its asset class: "BTC CRYPTO" opens the coin (order book),
            // "BTC CRYPTO CHART" charts it, "ETH EUR CRYPTO Q" quotes the EUR pair.
            if function == .crypto, index > 0 {
                security += " CRYPTO"
                if index + 1 < tokens.count, let verb = FunctionID.matching(tokens[index + 1]) {
                    function = verb
                    argsStart = index + 2
                }
            }
            // Video IDs and links are case-sensitive.
            let args = [.tv, .read].contains(function) ? Array(original[argsStart...]) : Array(tokens[argsStart...])
            return .run(security: security.isEmpty ? nil : security, function: function, args: args)
        }
        return .run(security: tokens.joined(separator: " "), function: nil, args: [])
    }
}
