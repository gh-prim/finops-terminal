import FinopsCore
import FinopsRemote
import FinopsUI
import Foundation
import Observation
import UIKit

/// Everything the iPad app holds: Mac discovery, the authenticated link, and a
/// local terminal workspace fed by the Mac's data gateway.
@MainActor
@Observable
final class PadSession {
    enum Mode: String, CaseIterable, Identifiable {
        case keypad = "Keypad"
        case terminal = "Terminal"
        var id: String { rawValue }
    }

    let browser = RemoteBrowser()
    let link: RemoteLink
    private(set) var model = TerminalModel()
    var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "pad.mode") }
    }
    private(set) var connectedHost: RemoteHost?
    private var autoConnectAttempted = false

    private static let lastHostKey = "pad.lastHost"
    private static let backendURLKey = "pad.backendURL"

    init() {
        link = RemoteLink(deviceID: Self.deviceID, deviceName: UIDevice.current.name)
        mode = UserDefaults.standard.string(forKey: "pad.mode").flatMap(Mode.init(rawValue:)) ?? .keypad
    }

    var isConnected: Bool {
        if case .connected = link.phase { return true }
        return false
    }

    func connect(to host: RemoteHost, code: String? = nil) async {
        await link.connect(to: host, code: code)
        guard isConnected, let client = link.client else { return }
        connectedHost = host
        UserDefaults.standard.set(host.name, forKey: Self.lastHostKey)
        if host.isBackend {
            UserDefaults.standard.set(host.url?.absoluteString, forKey: Self.backendURLKey)
        }
        let model = TerminalModel()
        model.notify = { title, body in Notifier.post(title: title, body: body) }
        model.connected(to: client, source: host.isBackend ? "backend" : "Mac")
        self.model = model
    }

    var isBackend: Bool { connectedHost?.isBackend ?? false }

    /// Saved backend address (wss://…/ws), if any.
    var backendURL: String {
        get { UserDefaults.standard.string(forKey: Self.backendURLKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.backendURLKey) }
    }

    func disconnect() {
        link.disconnect()
        connectedHost = nil
        autoConnectAttempted = true  // don't immediately reconnect after a manual disconnect
    }

    /// Reconnect to the last paired Mac as soon as it shows up on the network.
    func autoConnectIfPossible() async {
        guard !autoConnectAttempted, !isConnected,
              let name = UserDefaults.standard.string(forKey: Self.lastHostKey) else { return }
        let backend = RemoteHost.backendURL(from: backendURL).map(RemoteHost.backend)
        guard let host = backend?.name == name ? backend : browser.hosts.first(where: { $0.name == name }),
              RemoteLink.hasToken(for: host) else { return }
        autoConnectAttempted = true
        await connect(to: host)
    }

    private static var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: "pad.deviceID") { return id }
        let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(id, forKey: "pad.deviceID")
        return id
    }
}
