import Foundation

public enum FunctionID: String, CaseIterable, Sendable, Hashable {
    case quote = "QUOTE"
    case chart = "CHART"
    case help = "HELP"

    public var aliases: [String] {
        switch self {
        case .quote: ["QUOTE", "Q"]
        case .chart: ["CHART", "CH"]
        case .help: ["HELP", "?"]
        }
    }

    public var title: String {
        switch self {
        case .quote: "Quote"
        case .chart: "Chart"
        case .help: "Help"
        }
    }

    public var summary: String {
        switch self {
        case .quote: "Live quote and day statistics"
        case .chart: "Price chart. Args: range (1D 5D 1M 3M 6M YTD 1Y 2Y 5Y 10Y MAX)"
        case .help: "List commands and syntax"
        }
    }

    public var needsSecurity: Bool { self != .help }

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
    case empty
}

public enum CommandParser {
    public static func parse(_ input: String) -> Command {
        let tokens = input.uppercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return .empty }

        if tokens.count == 1, let n = Int(tokens[0]), n > 0 {
            return .action(n)
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
