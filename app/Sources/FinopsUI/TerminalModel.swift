import FinopsCore
import Foundation
import Observation

public enum ConnectionState: Equatable, Sendable {
    case starting
    case ready
    case failed(String)
}

/// What the main panel shows: the loaded security, the mounted function and its args.
public struct PanelState: Equatable, Sendable {
    public var security: String?
    public var function: FunctionID
    public var args: [String]

    public static let initial = PanelState(security: nil, function: .help, args: [])

    public var chartRange: ChartRange {
        args.first.flatMap(ChartRange.init(rawValue:)) ?? .y1
    }
}

public struct NumberedAction: Identifiable, Sendable {
    public let number: Int
    public let label: String
    public let state: PanelState
    public var id: Int { number }
}

@MainActor
@Observable
public final class TerminalModel {
    public private(set) var connection: ConnectionState = .starting
    public private(set) var client: DataClient?
    public private(set) var panel: PanelState = .initial
    public private(set) var message: String?
    public private(set) var watchlist: [String]
    public var commandText = ""

    private var backStack: [PanelState] = []
    private let defaults: UserDefaults
    private static let watchlistKey = "watchlist"
    public static let defaultWatchlist = [
        "SPX IDX", "NDX IDX", "AAPL US EQ", "MSFT US EQ", "NVDA US EQ",
        "EURUSD FX", "CL1 CMD", "BTC CRYPTO",
    ]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        watchlist = defaults.stringArray(forKey: Self.watchlistKey) ?? Self.defaultWatchlist
        if let first = watchlist.first {
            panel = PanelState(security: first, function: .chart, args: [])
        }
    }

    public func connected(to client: DataClient) {
        self.client = client
        connection = .ready
    }

    public func failed(_ reason: String) {
        connection = .failed(reason)
    }

    public var canGoBack: Bool { !backStack.isEmpty }

    // MARK: Direct manipulation (clicks)

    /// Load a security, keeping the current function (QUOTE when coming from HELP).
    public func load(_ security: String) {
        var next = panel
        next.security = security
        if next.function == .help { next.function = .quote }
        show(next)
    }

    public func open(_ function: FunctionID) {
        var next = panel
        next.function = function
        if function != panel.function { next.args = [] }
        show(next)
    }

    public func setRange(_ range: ChartRange) {
        var next = panel
        next.function = .chart
        next.args = [range.rawValue]
        show(next)
    }

    public func back() {
        guard let previous = backStack.popLast() else { return }
        panel = previous
        message = nil
    }

    public func report(_ error: Error) {
        message = error.localizedDescription
    }

    // MARK: Watchlist

    public func isWatched(_ security: String) -> Bool {
        watchlist.contains(security.uppercased())
    }

    public func addToWatchlist(_ security: String) {
        let key = security.uppercased()
        guard !watchlist.contains(key) else { return }
        watchlist.append(key)
        defaults.set(watchlist, forKey: Self.watchlistKey)
    }

    public func removeFromWatchlist(_ security: String) {
        watchlist.removeAll { $0 == security.uppercased() }
        defaults.set(watchlist, forKey: Self.watchlistKey)
    }

    // MARK: Command line (optional)

    /// Run whatever is on the command line (the GO key).
    public func submit() {
        let command = CommandParser.parse(commandText)
        commandText = ""
        message = nil

        switch command {
        case .empty:
            return
        case .action(let number):
            guard let action = actions.first(where: { $0.number == number }) else {
                message = "No action \(number) on this screen"
                return
            }
            show(action.state)
        case .run(let security, let function, let args):
            var next = panel
            if let security { next.security = security }
            if let function {
                next.function = function
                next.args = args
            } else if security != nil {
                if next.function == .help { next.function = .quote }
                next.args = panel.function == next.function ? panel.args : []
            }
            if next.function.needsSecurity, next.security == nil {
                message = "\(next.function.rawValue) needs a security, e.g. AAPL US EQ \(next.function.rawValue)"
                return
            }
            if next.function == .chart, let range = next.args.first, ChartRange(rawValue: range) == nil {
                message = "Unknown range \(range). Use \(ChartRange.allCases.map(\.rawValue).joined(separator: " "))"
                return
            }
            show(next)
        }
    }

    /// Clear the command line (the CANCEL key).
    public func cancel() {
        commandText = ""
        message = nil
    }

    /// Numbered actions for the current screen; typing the number + Enter runs one.
    public var actions: [NumberedAction] {
        switch panel.function {
        case .chart:
            ChartRange.allCases.enumerated().map { index, range in
                var state = panel
                state.args = [range.rawValue]
                return NumberedAction(number: index + 1, label: range.rawValue, state: state)
            }
        case .quote:
            [NumberedAction(number: 1, label: "Chart", state: PanelState(security: panel.security, function: .chart, args: []))]
        case .help:
            []
        }
    }

    private func show(_ state: PanelState) {
        message = nil
        guard state != panel else { return }
        backStack.append(panel)
        if backStack.count > 50 { backStack.removeFirst() }
        panel = state
    }
}
