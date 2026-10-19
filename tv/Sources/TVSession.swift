import FinopsCore
import FinopsRemote
import Foundation
import Observation
import UIKit

/// The Apple TV app's state: the paired Mac, its dashboards, and which one is on screen.
@MainActor
@Observable
final class TVSession {
    let browser = RemoteBrowser()
    let link: RemoteLink
    private(set) var connectedHost: RemoteHost?
    var index = 0
    var rotating: Bool {
        didSet { UserDefaults.standard.set(rotating, forKey: "tv.rotating") }
    }
    var rotateSeconds = 30
    private var autoConnectAttempted = false
    private var lastDisplayRequest: Date?

    private static let lastHostKey = "tv.lastHost"

    init() {
        link = RemoteLink(deviceID: Self.deviceID, deviceName: UIDevice.current.name)
        rotating = UserDefaults.standard.bool(forKey: "tv.rotating")
    }

    var isConnected: Bool {
        if case .connected = link.phase { return true }
        return false
    }

    var dashboards: [Dashboard] { link.dashboards }

    var current: Dashboard? {
        guard !dashboards.isEmpty else { return nil }
        return dashboards[min(max(index, 0), dashboards.count - 1)]
    }

    func connect(to host: RemoteHost, code: String? = nil) async {
        await link.connect(to: host, code: code)
        guard isConnected else { return }
        connectedHost = host
        UserDefaults.standard.set(host.name, forKey: Self.lastHostKey)
        if let saved = UserDefaults.standard.string(forKey: "tv.dashboard"),
           let i = dashboards.firstIndex(where: { $0.id.uuidString == saved }) {
            index = i
        }
    }

    func disconnect() {
        link.disconnect()
        connectedHost = nil
        autoConnectAttempted = true
    }

    func step(_ delta: Int) {
        guard !dashboards.isEmpty else { return }
        index = (index + delta + dashboards.count) % dashboards.count
        remember()
    }

    func show(_ id: UUID) {
        guard let i = dashboards.firstIndex(where: { $0.id == id }) else { return }
        index = i
        remember()
    }

    /// The Mac pressed "Show on TV".
    func handleDisplayRequest() {
        guard let request = link.displayRequest, request.at != lastDisplayRequest else { return }
        lastDisplayRequest = request.at
        show(request.id)
    }

    /// Reconnect to the last paired Mac as soon as it shows up on the network.
    func autoConnectIfPossible() async {
        guard !autoConnectAttempted, !isConnected,
              let name = UserDefaults.standard.string(forKey: Self.lastHostKey),
              let host = browser.hosts.first(where: { $0.name == name }),
              RemoteLink.hasToken(for: host) else { return }
        autoConnectAttempted = true
        await connect(to: host)
    }

    /// After a dropped connection, try again (the Mac may have restarted the app).
    func reconnectSoon() async {
        guard let host = connectedHost else { return }
        try? await Task.sleep(for: .seconds(5))
        if !isConnected { await connect(to: host) }
    }

    private func remember() {
        UserDefaults.standard.set(current?.id.uuidString, forKey: "tv.dashboard")
    }

    private static var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: "tv.deviceID") { return id }
        let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(id, forKey: "tv.deviceID")
        return id
    }
}
