import FinopsCore
import Foundation
import Observation

public enum ConnectionState: Equatable, Sendable {
    case starting
    case ready
    case failed(String)
}

/// What one panel shows. `args` is the single source of truth for options, so a
/// button click and a typed command produce exactly the same state.
public struct PanelState: Equatable, Sendable {
    public var security: String?
    public var function: FunctionID
    public var args: [String]

    public static let help = PanelState(security: nil, function: .help, args: [])

    public var chart: ChartConfig { ChartConfig(args: args) }
}

@MainActor
@Observable
public final class PanelModel: Identifiable {
    public let id = UUID()
    public internal(set) var state: PanelState
    public var linked = true
    var backStack: [PanelState] = []

    init(_ state: PanelState) {
        self.state = state
    }

    public var canGoBack: Bool { !backStack.isEmpty }

    func show(_ next: PanelState) {
        guard next != state else { return }
        backStack.append(state)
        if backStack.count > 50 { backStack.removeFirst() }
        state = next
    }
}

public enum Layout: Int, CaseIterable, Sendable {
    case single = 1, split = 2, grid = 4

    public var systemImage: String {
        switch self {
        case .single: "rectangle"
        case .split: "rectangle.split.2x1"
        case .grid: "square.grid.2x2"
        }
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
    public private(set) var panels: [PanelModel]
    public private(set) var activePanelID: UUID
    public private(set) var layout: Layout = .single
    public private(set) var message: String?
    public var commandText = ""

    public private(set) var watchlists: [Watchlist]
    public var currentWatchlistID: UUID { didSet { defaults.set(currentWatchlistID.uuidString, forKey: "currentWatchlist") } }
    public private(set) var positions: [Position]
    public private(set) var alerts: [PriceAlert]
    public let quotes = QuoteBoard()

    /// Set by the app to deliver system notifications for triggered alerts.
    @ObservationIgnored public var notify: ((String, String) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let watchlistStore: Persisted<[Watchlist]>
    @ObservationIgnored private let positionStore: Persisted<[Position]>
    @ObservationIgnored private let alertStore: Persisted<[PriceAlert]>

    public static let defaultSecurities = [
        "SPX IDX", "NDX IDX", "AAPL US EQ", "MSFT US EQ", "NVDA US EQ", "EURUSD FX", "CL1 CMD", "BTC CRYPTO",
    ]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        watchlistStore = Persisted(key: "watchlists.v2", defaults: defaults)
        positionStore = Persisted(key: "positions.v1", defaults: defaults)
        alertStore = Persisted(key: "alerts.v1", defaults: defaults)

        var lists = watchlistStore.load() ?? []
        if lists.isEmpty {
            let legacy = defaults.stringArray(forKey: "watchlist") ?? Self.defaultSecurities
            lists = [Watchlist(id: UUID(), name: "Main", securities: legacy)]
        }
        watchlists = lists
        currentWatchlistID = defaults.string(forKey: "currentWatchlist").flatMap(UUID.init(uuidString:))
            .flatMap { id in lists.contains { $0.id == id } ? id : nil } ?? lists[0].id
        positions = positionStore.load() ?? []
        alerts = alertStore.load() ?? []

        let first = PanelModel(PanelState(security: lists[0].securities.first, function: .chart, args: []))
        panels = [first]
        activePanelID = first.id
        if first.state.security == nil { first.state = .help }

        quotes.onTick = { [weak self] security, quote in self?.checkAlerts(security, quote) }
    }

    // MARK: Connection

    public func connected(to client: DataClient) {
        self.client = client
        connection = .ready
        quotes.setClient(client)
        trackQuotes()
    }

    public func failed(_ reason: String) {
        connection = .failed(reason)
    }

    // MARK: Panels

    public var activePanel: PanelModel {
        panels.first { $0.id == activePanelID } ?? panels[0]
    }

    /// The active panel's state (kept for the single-panel call sites).
    public var panel: PanelState { activePanel.state }

    public func activate(_ panel: PanelModel) {
        activePanelID = panel.id
    }

    public func setLayout(_ layout: Layout) {
        self.layout = layout
        let defaultsForNew: [FunctionID] = [.chart, .news, .desc, .fin]
        while panels.count < layout.rawValue {
            let security = activePanel.state.security
            let function = defaultsForNew[panels.count % defaultsForNew.count]
            panels.append(PanelModel(security == nil ? .help : PanelState(security: security, function: function, args: [])))
        }
        if panels.count > layout.rawValue {
            panels.removeLast(panels.count - layout.rawValue)
        }
        if !panels.contains(where: { $0.id == activePanelID }) { activePanelID = panels[0].id }
    }

    public func close(_ panel: PanelModel) {
        guard panels.count > 1 else { return }
        panels.removeAll { $0.id == panel.id }
        layout = panels.count >= 3 ? .grid : (panels.count == 2 ? .split : .single)
        if activePanelID == panel.id { activePanelID = panels[0].id }
    }

    public func back(_ panel: PanelModel? = nil) {
        let panel = panel ?? activePanel
        guard let previous = panel.backStack.popLast() else { return }
        panel.state = previous
        message = nil
    }

    // MARK: Navigation (shared by clicks and typed commands)

    public func load(_ security: String, in panel: PanelModel? = nil) {
        apply(.run(security: security, function: nil, args: []), to: panel ?? activePanel)
    }

    public func open(_ function: FunctionID, in panel: PanelModel? = nil) {
        let panel = panel ?? activePanel
        activate(panel)
        apply(.run(security: nil, function: function, args: function == panel.state.function ? panel.state.args : []),
              to: panel)
    }

    /// Replace a panel's args (toolbar toggles, range buttons).
    public func setArgs(_ args: [String], in panel: PanelModel? = nil) {
        let panel = panel ?? activePanel
        var next = panel.state
        next.args = args
        panel.show(next)
        message = nil
    }

    /// Run a command string as if typed, e.g. from a table row or a choice button.
    public func run(_ text: String, in panel: PanelModel? = nil) {
        let panel = panel ?? activePanel
        activate(panel)
        apply(CommandParser.parse(text), to: panel)
    }

    /// The command line (GO key) runs in the active panel.
    public func submit() {
        let text = commandText
        commandText = ""
        message = nil
        apply(CommandParser.parse(text), to: activePanel)
    }

    public func cancel() {
        commandText = ""
        message = nil
    }

    public func report(_ error: Error) {
        message = error.localizedDescription
    }

    public func clearMessage() {
        message = nil
    }

    private func apply(_ command: Command, to panel: PanelModel) {
        message = nil
        switch command {
        case .empty:
            return
        case .action(let number):
            guard let action = actions(for: panel).first(where: { $0.number == number }) else {
                message = "No action \(number) on this screen"
                return
            }
            panel.show(action.state)
        case .watch(let security):
            guard let security = security ?? panel.state.security else {
                message = "Load a security first, e.g. AAPL US EQ WATCH"
                return
            }
            addToWatchlist(security)
            message = "Added \(security) to \(currentWatchlist.name)"
        case .run(let security, let function, var args):
            var next = panel.state
            if let security { next.security = security }
            if let function {
                next.function = function
            } else if security != nil {
                // A security alone keeps the screen when it's about a security; else opens QUOTE.
                if !next.function.needsSecurity { next.function = .quote }
                args = [.opt, .news].contains(next.function) ? [] : next.args
            }
            next.args = args

            if next.function.needsSecurity || next.function == .alert && !args.isEmpty
                || next.function == .port && args.first == "ADD", next.security == nil {
                message = "\(next.function.rawValue) needs a security, e.g. AAPL US EQ \(next.function.rawValue)"
                return
            }
            if !handleToolArgs(&next) { return }
            if next.function == .chart {
                let unknown = ChartConfig.unknownTokens(in: next.args)
                if !unknown.isEmpty {
                    message = "Unknown chart option \(unknown.joined(separator: " ")). See HELP."
                    return
                }
            }
            let securityChanged = next.security != panel.state.security
            panel.show(next)
            if securityChanged, panel.linked, let security = next.security {
                for other in panels where other.id != panel.id && other.linked && other.state.function.needsSecurity {
                    var s = other.state
                    s.security = security
                    if s.function == .opt { s.args = [] }
                    other.show(s)
                }
            }
        }
    }

    /// PORT ADD / ALERT > 350 create records, then show the list. Returns false on error.
    private func handleToolArgs(_ state: inout PanelState) -> Bool {
        switch state.function {
        case .alert where !state.args.isEmpty:
            let joined = state.args.joined()
            guard let op = joined.first, op == ">" || op == "<", let price = Double(joined.dropFirst()),
                  let security = state.security else {
                message = "Use: <security> ALERT > 350  or  ALERT < 120"
                return false
            }
            addAlert(security: security, above: op == ">", price: price)
            message = "Alert set: \(security) \(op) \(Format.price(price))"
            state.args = []
        case .port where state.args.first == "ADD":
            guard let security = state.security, state.args.count >= 2, let qty = Double(state.args[1]) else {
                message = "Use: <security> PORT ADD <quantity> [cost per share]"
                return false
            }
            let cost = state.args.count >= 3 ? Double(state.args[2]) : nil
            addPosition(security: security, quantity: qty, cost: cost ?? quotes.quotes[security]?.last ?? 0)
            message = "Added \(Format.number(qty)) \(security) to portfolio"
            state.args = []
        case .port where state.args.first == "DEL" || state.args.first == "REMOVE":
            if let security = state.security {
                positions.removeAll { $0.security == security }
                positionStore.save(positions)
                trackQuotes()
            }
            state.args = []
        default:
            break
        }
        return true
    }

    /// Numbered actions: typing the number + Enter runs one.
    public func actions(for panel: PanelModel) -> [NumberedAction] {
        let state = panel.state
        switch state.function {
        case .chart:
            return ChartRange.allCases.enumerated().map { index, range in
                var config = state.chart
                config.range = range
                return NumberedAction(number: index + 1, label: range.rawValue,
                                      state: PanelState(security: state.security, function: .chart, args: config.args))
            }
        case .quote:
            return [.chart, .desc, .news, .fin].enumerated().map { index, function in
                NumberedAction(number: index + 1, label: function.rawValue,
                               state: PanelState(security: state.security, function: function, args: []))
            }
        default:
            return []
        }
    }

    // MARK: Watchlists

    public var currentWatchlist: Watchlist {
        watchlists.first { $0.id == currentWatchlistID } ?? watchlists[0]
    }

    public var watchlist: [String] { currentWatchlist.securities }

    public func isWatched(_ security: String) -> Bool {
        currentWatchlist.securities.contains(security.uppercased())
    }

    public func addToWatchlist(_ security: String) {
        mutateCurrentWatchlist { list in
            let key = security.uppercased()
            if !list.securities.contains(key) { list.securities.append(key) }
        }
    }

    public func removeFromWatchlist(_ security: String) {
        mutateCurrentWatchlist { $0.securities.removeAll { $0 == security.uppercased() } }
    }

    public func moveInWatchlist(from source: IndexSet, to destination: Int) {
        mutateCurrentWatchlist { $0.securities.move(fromOffsets: source, toOffset: destination) }
    }

    public func createWatchlist(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let list = Watchlist(id: UUID(), name: trimmed, securities: [])
        watchlists.append(list)
        currentWatchlistID = list.id
        watchlistStore.save(watchlists)
    }

    public func renameCurrentWatchlist(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        mutateCurrentWatchlist { $0.name = trimmed }
    }

    public func deleteCurrentWatchlist() {
        guard watchlists.count > 1 else { return }
        watchlists.removeAll { $0.id == currentWatchlistID }
        currentWatchlistID = watchlists[0].id
        watchlistStore.save(watchlists)
    }

    private func mutateCurrentWatchlist(_ change: (inout Watchlist) -> Void) {
        guard let index = watchlists.firstIndex(where: { $0.id == currentWatchlistID }) else { return }
        change(&watchlists[index])
        watchlistStore.save(watchlists)
    }

    // MARK: Portfolio

    public func addPosition(security: String, quantity: Double, cost: Double) {
        let key = security.uppercased()
        if let index = positions.firstIndex(where: { $0.security == key }) {
            // Merge into an average cost.
            let p = positions[index]
            let total = p.quantity + quantity
            positions[index].cost = total == 0 ? 0 : (p.cost * p.quantity + cost * quantity) / total
            positions[index].quantity = total
        } else {
            positions.append(Position(id: UUID(), security: key, quantity: quantity, cost: cost))
        }
        positionStore.save(positions)
        trackQuotes()
    }

    public func removePosition(_ position: Position) {
        positions.removeAll { $0.id == position.id }
        positionStore.save(positions)
        trackQuotes()
    }

    // MARK: Alerts

    public func addAlert(security: String, above: Bool, price: Double) {
        alerts.append(PriceAlert(id: UUID(), security: security.uppercased(), above: above, price: price,
                                 created: .now, triggeredAt: nil))
        alertStore.save(alerts)
        trackQuotes()
    }

    public func removeAlert(_ alert: PriceAlert) {
        alerts.removeAll { $0.id == alert.id }
        alertStore.save(alerts)
        trackQuotes()
    }

    public func rearm(_ alert: PriceAlert) {
        guard let index = alerts.firstIndex(where: { $0.id == alert.id }) else { return }
        alerts[index].triggeredAt = nil
        alertStore.save(alerts)
        trackQuotes()
    }

    private func checkAlerts(_ security: String, _ quote: Quote) {
        var changed = false
        for index in alerts.indices where alerts[index].security == security && alerts[index].triggeredAt == nil {
            if alerts[index].isHit(by: quote.last) {
                alerts[index].triggeredAt = .now
                changed = true
                let text = "\(security) \(alerts[index].condition) — last \(Format.price(quote.last))"
                message = "🔔 \(text)"
                notify?("Price alert", text)
            }
        }
        if changed {
            alertStore.save(alerts)
            trackQuotes()
        }
    }

    private func trackQuotes() {
        quotes.track(Set(positions.map(\.security)), for: "portfolio")
        quotes.track(Set(alerts.filter { $0.triggeredAt == nil }.map(\.security)), for: "alerts")
    }
}
