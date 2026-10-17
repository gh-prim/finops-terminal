import FinopsCore
import Foundation
import Network
import Observation

/// A Mac advertising finops-terminal on the local network.
public struct RemoteHost: Identifiable, Hashable, Sendable {
    public let name: String
    public let host: String
    public let port: UInt16
    private let explicitURL: URL?
    public var id: String { name }

    /// A Mac found over Bonjour (plain ws:// on the LAN).
    public init(name: String, host: String, port: UInt16) {
        self.name = name
        self.host = host
        self.port = port
        explicitURL = nil
    }

    /// The finops backend, e.g. wss://finops-backend.<tailnet>.ts.net/ws
    public static func backend(_ url: URL) -> RemoteHost {
        RemoteHost(name: "backend:\(url.host() ?? url.absoluteString)", host: url.host() ?? "", port: UInt16(url.port ?? 443), url: url)
    }

    private init(name: String, host: String, port: UInt16, url: URL) {
        self.name = name
        self.host = host
        self.port = port
        explicitURL = url
    }

    public var isBackend: Bool { explicitURL != nil }

    public var url: URL? { explicitURL ?? URL(string: "ws://\(host):\(port)") }

    /// Normalise what a user types ("finops-backend.x.ts.net", "https://…") into a wss://…/ws URL.
    public static func backendURL(from text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "wss://" + s }
        s = s.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://")
        guard var components = URLComponents(string: s), components.host?.isEmpty == false else { return nil }
        if components.path.isEmpty || components.path == "/" { components.path = "/ws" }
        return components.url
    }
}

/// iPad side: discovers Macs over Bonjour.
@MainActor
@Observable
public final class RemoteBrowser {
    public private(set) var hosts: [RemoteHost] = []
    public private(set) var status = "idle"
    @ObservationIgnored private var browser: NWBrowser?

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteService.type, domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready: self?.status = "searching"
                case .failed(let error): self?.status = "failed: \(error.localizedDescription)"
                case .waiting(let error): self?.status = "waiting: \(error.localizedDescription)"
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                self?.hosts = results.compactMap { result in
                    guard case .service(let name, _, _, _) = result.endpoint,
                          case .bonjour(let txt) = result.metadata,
                          let host = txt["host"], let port = txt["port"].flatMap(UInt16.init) else { return nil }
                    return RemoteHost(name: name, host: host, port: port)
                }
                .sorted { $0.name < $1.name }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }
}

/// iPad side: an authenticated connection to one Mac. The same socket carries
/// the data protocol (relayed to the Mac's gateway) and the keypad messages.
@MainActor
@Observable
public final class RemoteLink {
    public enum Phase: Equatable {
        case idle, connecting, connected(macName: String), failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var state: RemoteState?
    public private(set) var client: DataClient?
    @ObservationIgnored private var listenTask: Task<Void, Never>?

    public let deviceID: String
    public let deviceName: String

    public init(deviceID: String, deviceName: String) {
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    public static func hasToken(for host: RemoteHost) -> Bool {
        RemoteKeychain.get("token:\(host.name)") != nil
    }

    public static func forgetToken(for host: RemoteHost) {
        RemoteKeychain.set(nil, for: "token:\(host.name)")
    }

    /// The auth message this device would send to `host`, if it has a stored token.
    public func authHello(for host: RemoteHost) -> Data? {
        RemoteKeychain.get("token:\(host.name)").map { RemoteMessage.auth(token: $0, deviceID: deviceID).encoded() }
    }

    /// Connect with the stored token, or pair with `code` when given.
    public func connect(to host: RemoteHost, code: String? = nil) async {
        disconnect()
        guard let url = host.url else {
            phase = .failed("Invalid address for \(host.name)")
            return
        }
        let token = RemoteKeychain.get("token:\(host.name)")
        let hello: RemoteMessage
        if let code {
            hello = .pair(code: code, deviceID: deviceID, deviceName: deviceName)
        } else if let token {
            hello = .auth(token: token, deviceID: deviceID)
        } else {
            phase = .failed("Enter the pairing code shown on the Mac")
            return
        }

        phase = .connecting
        let client = DataClient(url: url)
        await client.start(hello: hello.encoded())

        // Wait for the Mac's verdict, then keep listening for state updates.
        let verdict = AsyncStream<Verdict>.makeStream()
        listenTask = Task { [weak self] in
            for await data in client.unhandled {
                guard let message = RemoteMessage(data) else { continue }
                switch message {
                case .paired(let token, let mac):
                    RemoteKeychain.set(token, for: "token:\(host.name)")
                    verdict.continuation.yield(.ok(mac))
                case .authOK(let mac):
                    verdict.continuation.yield(.ok(mac))
                case .authFailed(let reason):
                    if code == nil { RemoteKeychain.set(nil, for: "token:\(host.name)") }
                    verdict.continuation.yield(.failed(reason))
                case .state(let state):
                    self?.state = state
                default:
                    break
                }
            }
            verdict.continuation.yield(.failed("Connection to \(host.name) closed"))
            if case .connected = self?.phase { self?.phase = .failed("Connection to \(host.name) lost") }
        }

        let timeout = Task {
            try? await Task.sleep(for: .seconds(8))
            verdict.continuation.yield(.failed("\(host.name) didn't answer. Is finops-terminal open on the Mac?"))
        }
        var iterator = verdict.stream.makeAsyncIterator()
        let result = await iterator.next() ?? .failed("No answer")
        timeout.cancel()
        switch result {
        case .ok(let mac):
            self.client = client
            phase = .connected(macName: mac)
        case .failed(let reason):
            listenTask?.cancel()
            await client.close()
            phase = .failed(reason)
        }
    }

    public func disconnect() {
        listenTask?.cancel()
        listenTask = nil
        if let client { Task { await client.close() } }
        client = nil
        state = nil
        phase = .idle
    }

    public func send(_ command: String) {
        send(.command(command))
    }

    public func send(_ action: RemoteAction) {
        send(.action(action))
    }

    private func send(_ message: RemoteMessage) {
        guard let client else { return }
        Task { try? await client.sendRaw(message.encoded()) }
    }
}

private enum Verdict: Sendable {
    case ok(String)
    case failed(String)
}
