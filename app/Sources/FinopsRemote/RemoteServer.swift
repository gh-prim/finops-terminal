import FinopsCore
import Foundation
import Network
import Observation

/// Mac side: advertises `_finops._tcp` on the local network, pairs iPads with a
/// 6-digit code, relays their data-protocol messages to the local gateway, and
/// hands keypad commands/actions to the app.
@MainActor
@Observable
public final class RemoteServer {
    public private(set) var pairingCode: PairingCode?
    public private(set) var devices: [PairedDevice]
    public private(set) var connected: [String] = []      // names of authenticated iPads
    public private(set) var status = "stopped"
    public private(set) var port: UInt16?

    /// Upstream gateway WebSocket (with its token) used to relay data requests.
    @ObservationIgnored public var gatewayURL: URL?
    /// First message on each upstream socket (device auth when the upstream is the backend).
    @ObservationIgnored public var gatewayHello: Data?
    @ObservationIgnored public var onCommand: ((String) -> Void)?
    @ObservationIgnored public var onAction: ((RemoteAction) -> Void)?
    @ObservationIgnored public var stateProvider: (() -> RemoteState)?
    @ObservationIgnored public var dashboardsProvider: (() -> [Dashboard])?

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var peers: [ObjectIdentifier: Peer] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let macName: String
    private static let devicesKey = "remote.pairedDevices"

    public init(macName: String, defaults: UserDefaults = .standard) {
        self.macName = macName
        self.defaults = defaults
        devices = (defaults.data(forKey: Self.devicesKey)).flatMap { try? JSONDecoder().decode([PairedDevice].self, from: $0) } ?? []
    }

    // MARK: Lifecycle

    public func start(hostName: String, preferredPort: UInt16? = 52817) {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        parameters.includePeerToPeer = true

        let listener: NWListener
        do {
            let port = preferredPort.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
            listener = try NWListener(using: parameters, on: port)
        } catch {
            status = "failed: \(error.localizedDescription)"
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = listener.port?.rawValue
                    self.status = "listening"
                    if let port = self.port {
                        // The iPad builds ws://host:port from the TXT record.
                        let txt = NWTXTRecord(["port": String(port), "host": hostName])
                        listener.service = NWListener.Service(name: self.macName, type: RemoteService.type, txtRecord: txt)
                    }
                case .failed(let error):
                    // Preferred port taken (e.g. another copy of the app): retry on any free port.
                    if preferredPort != nil {
                        listener.cancel()
                        self.listener = nil
                        self.start(hostName: hostName, preferredPort: nil)
                    } else {
                        self.status = "failed: \(error.localizedDescription)"
                    }
                case .cancelled:
                    self.status = "stopped"
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for peer in peers.values { peer.close() }
        peers.removeAll()
        connected = []
    }

    // MARK: Pairing

    @discardableResult
    public func beginPairing() -> PairingCode {
        let code = PairingCode.generate()
        pairingCode = code
        return code
    }

    public func endPairing() {
        pairingCode = nil
    }

    public func revoke(_ device: PairedDevice) {
        devices.removeAll { $0.id == device.id }
        saveDevices()
        for peer in peers.values where peer.deviceID == device.id { peer.close() }
    }

    private func saveDevices() {
        defaults.set(try? JSONEncoder().encode(devices), forKey: Self.devicesKey)
    }

    // MARK: State push

    public func broadcastState() {
        guard let state = stateProvider?() else { return }
        let data = RemoteMessage.state(state).encoded()
        for peer in peers.values where peer.authenticated { peer.send(data) }
    }

    /// Push the dashboards to every connected device; `display` makes TVs switch to that one.
    public func broadcastDashboards(display: UUID? = nil) {
        guard let dashboards = dashboardsProvider?() else { return }
        let data = RemoteMessage.dashboards(dashboards, display: display).encoded()
        for peer in peers.values where peer.authenticated { peer.send(data) }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let peer = Peer(connection: connection)
        peers[ObjectIdentifier(peer)] = peer
        connection.stateUpdateHandler = { [weak self, weak peer] state in
            MainActor.assumeIsolated {
                guard let self, let peer else { return }
                switch state {
                case .failed, .cancelled: self.drop(peer)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive(peer)
    }

    private func drop(_ peer: Peer) {
        peer.close()
        peers[ObjectIdentifier(peer)] = nil
        refreshConnected()
    }

    private func refreshConnected() {
        connected = peers.values.filter(\.authenticated).compactMap(\.deviceName).sorted()
    }

    private func receive(_ peer: Peer) {
        peer.connection.receiveMessage { [weak self, weak peer] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self, let peer else { return }
                if let data, !data.isEmpty { self.handle(data, from: peer) }
                if error == nil, !peer.closed { self.receive(peer) } else { self.drop(peer) }
            }
        }
    }

    private func handle(_ data: Data, from peer: Peer) {
        if RemoteMessage.isRemote(data) {
            guard let message = RemoteMessage(data) else { return }
            handle(message, from: peer)
        } else if peer.authenticated {
            peer.forwardUpstream(data)
        }
    }

    private func handle(_ message: RemoteMessage, from peer: Peer) {
        switch message {
        case .pair(let code, let deviceID, let deviceName):
            guard var current = pairingCode, current.isValid() else {
                peer.send(RemoteMessage.authFailed(reason: "No pairing in progress. On the Mac, open Pair iPad… to get a code.").encoded())
                return
            }
            guard code == current.code else {
                current.failedAttempts += 1
                pairingCode = current.isValid() ? current : nil
                peer.send(RemoteMessage.authFailed(reason: "Wrong code").encoded())
                return
            }
            let token = PairingCrypto.newToken()
            devices.removeAll { $0.id == deviceID }
            devices.append(PairedDevice(id: deviceID, name: deviceName, tokenHash: PairingCrypto.hash(token), pairedAt: .now))
            saveDevices()
            pairingCode = nil
            authenticate(peer, deviceID: deviceID, name: deviceName)
            peer.send(RemoteMessage.paired(token: token, macName: macName).encoded())
            broadcastState()
        case .auth(let token, let deviceID):
            guard let device = devices.first(where: { $0.id == deviceID }),
                  PairingCrypto.matches(token, hash: device.tokenHash) else {
                peer.send(RemoteMessage.authFailed(reason: "This iPad is no longer paired. Pair it again.").encoded())
                return
            }
            authenticate(peer, deviceID: deviceID, name: device.name)
            peer.send(RemoteMessage.authOK(macName: macName).encoded())
            broadcastState()
        case .command(let command):
            guard peer.authenticated else { return }
            onCommand?(command)
        case .action(let action):
            guard peer.authenticated else { return }
            onAction?(action)
        case .paired, .authOK, .authFailed, .state, .dashboards:
            break  // Mac → device only
        }
    }

    private func authenticate(_ peer: Peer, deviceID: String, name: String) {
        peer.deviceID = deviceID
        peer.deviceName = name
        peer.authenticated = true
        if let gatewayURL { peer.openUpstream(gatewayURL, hello: gatewayHello) }
        refreshConnected()
        if let dashboards = dashboardsProvider?() {
            peer.send(RemoteMessage.dashboards(dashboards, display: nil).encoded())
        }
    }
}

/// One iPad connection plus its relay socket to the gateway.
@MainActor
private final class Peer {
    let connection: NWConnection
    var deviceID: String?
    var deviceName: String?
    var authenticated = false
    private(set) var closed = false
    private var upstream: URLSessionWebSocketTask?
    private var upstreamTask: Task<Void, Never>?

    init(connection: NWConnection) {
        self.connection = connection
    }

    func send(_ data: Data) {
        guard !closed else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    func openUpstream(_ url: URL, hello: Data?) {
        guard upstream == nil else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        upstream = task
        if let hello { task.send(.string(String(decoding: hello, as: UTF8.self))) { _ in } }
        upstreamTask = Task { [weak self] in
            while let message = try? await task.receive() {
                guard let self, !self.closed else { return }
                switch message {
                case .string(let text):
                    // The backend's auth reply is for the Mac, not the iPad.
                    if hello != nil, RemoteMessage.isRemote(Data(text.utf8)) { continue }
                    self.send(Data(text.utf8))
                case .data(let data): self.send(data)
                @unknown default: break
                }
            }
            self?.close()
        }
    }

    func forwardUpstream(_ data: Data) {
        upstream?.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    func close() {
        guard !closed else { return }
        closed = true
        upstreamTask?.cancel()
        upstream?.cancel(with: .goingAway, reason: nil)
        connection.cancel()
    }
}
