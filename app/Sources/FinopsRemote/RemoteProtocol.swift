import Foundation

/// Bonjour service advertised by the Mac app for paired iPads.
public enum RemoteService {
    public static let type = "_finops._tcp"
}

/// Keypad actions that aren't plain commands.
public enum RemoteAction: String, Codable, Sendable, CaseIterable {
    case back, cancel, toggleLink
    case layout1, layout2, layout4
    case panel1, panel2, panel3, panel4
}

public struct RemotePanel: Codable, Sendable, Hashable {
    public var security: String?
    public var function: String
    public var args: [String]
    public var linked: Bool

    public init(security: String?, function: String, args: [String] = [], linked: Bool) {
        self.security = security
        self.function = function
        self.args = args
        self.linked = linked
    }
}

/// What the iPad keypad shows about the Mac workspace.
public struct RemoteState: Codable, Sendable, Equatable {
    public var macName: String
    public var panels: [RemotePanel]
    public var activePanel: Int
    public var layout: Int
    public var watchlistName: String
    public var watchlist: [String]
    public var message: String?

    public init(macName: String, panels: [RemotePanel], activePanel: Int, layout: Int,
                watchlistName: String, watchlist: [String], message: String?) {
        self.macName = macName
        self.panels = panels
        self.activePanel = activePanel
        self.layout = layout
        self.watchlistName = watchlistName
        self.watchlist = watchlist
        self.message = message
    }
}

/// Messages between the iPad and the Mac. They share the socket with the data
/// protocol (which the Mac relays to its gateway); `remote.*` types never reach the gateway.
public enum RemoteMessage: Sendable, Equatable {
    // iPad → Mac
    case pair(code: String, deviceID: String, deviceName: String)
    case auth(token: String, deviceID: String)
    case command(String)
    case action(RemoteAction)
    // Mac → iPad
    case paired(token: String, macName: String)
    case authOK(macName: String)
    case authFailed(reason: String)
    case state(RemoteState)

    private struct Wire: Codable {
        var t: String
        var code: String?
        var deviceID: String?
        var deviceName: String?
        var token: String?
        var macName: String?
        var reason: String?
        var cmd: String?
        var action: RemoteAction?
        var state: RemoteState?
    }

    public static func isRemote(_ data: Data) -> Bool {
        guard let wire = try? JSONDecoder().decode(TypeOnly.self, from: data) else { return false }
        return wire.t.hasPrefix("remote.")
    }

    private struct TypeOnly: Decodable { let t: String }

    public func encoded() -> Data {
        var w = Wire(t: "")
        switch self {
        case .pair(let code, let id, let name): w.t = "remote.pair"; w.code = code; w.deviceID = id; w.deviceName = name
        case .auth(let token, let id): w.t = "remote.auth"; w.token = token; w.deviceID = id
        case .command(let cmd): w.t = "remote.command"; w.cmd = cmd
        case .action(let action): w.t = "remote.action"; w.action = action
        case .paired(let token, let mac): w.t = "remote.paired"; w.token = token; w.macName = mac
        case .authOK(let mac): w.t = "remote.authOK"; w.macName = mac
        case .authFailed(let reason): w.t = "remote.authFailed"; w.reason = reason
        case .state(let state): w.t = "remote.state"; w.state = state
        }
        return (try? JSONEncoder().encode(w)) ?? Data()
    }

    public init?(_ data: Data) {
        guard let w = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        switch w.t {
        case "remote.pair":
            guard let code = w.code, let id = w.deviceID else { return nil }
            self = .pair(code: code, deviceID: id, deviceName: w.deviceName ?? "iPad")
        case "remote.auth":
            guard let token = w.token, let id = w.deviceID else { return nil }
            self = .auth(token: token, deviceID: id)
        case "remote.command":
            guard let cmd = w.cmd else { return nil }
            self = .command(cmd)
        case "remote.action":
            guard let action = w.action else { return nil }
            self = .action(action)
        case "remote.paired":
            guard let token = w.token else { return nil }
            self = .paired(token: token, macName: w.macName ?? "Mac")
        case "remote.authOK": self = .authOK(macName: w.macName ?? "Mac")
        case "remote.authFailed": self = .authFailed(reason: w.reason ?? "Not authorized")
        case "remote.state":
            guard let state = w.state else { return nil }
            self = .state(state)
        default: return nil
        }
    }
}
