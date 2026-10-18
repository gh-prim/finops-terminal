import AppKit
import FinopsCore
import FinopsRemote
import FinopsUI
import SwiftUI
import SystemConfiguration

@main
struct FinopsTerminalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = TerminalModel()

    var body: some Scene {
        Window("finops-terminal", id: "terminal") {
            TerminalView(model: model, accessory: AnyView(MacToolbarAccessory(server: delegate.remote)))
                .frame(minWidth: 900, minHeight: 560)
                .task { await delegate.boot(model) }
        }
        .commands { TerminalCommands() }

        Settings {
            TabView {
                SettingsView(model: model)
                    .tabItem { Label("Providers", systemImage: "key") }
                BackendSettingsView(delegate: delegate, model: model)
                    .tabItem { Label("Backend", systemImage: "server.rack") }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let gateway = GatewayProcess()
    private var client: DataClient?
    let remote = RemoteServer(macName: Host.current().localizedName ?? "Mac")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when running the bare SwiftPM executable (no Info.plist).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        remote.stop()
        gateway.stop()
    }

    // MARK: Data source: backend first, local sidecar as fallback

    let backendLink = RemoteLink(deviceID: AppDelegate.deviceID, deviceName: Host.current().localizedName ?? "Mac")
    private(set) var localGatewayURL: URL?
    private var watchdog: Task<Void, Never>?

    static var backendHost: RemoteHost? {
        UserDefaults.standard.string(forKey: "backend.url").flatMap(RemoteHost.backendURL(from:)).map(RemoteHost.backend)
    }

    private static var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: "mac.deviceID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "mac.deviceID")
        return id
    }

    func boot(_ model: TerminalModel) async {
        guard client == nil else { return }
        model.notify = { title, body in
            Notifier.post(title: title, body: body)
            NSSound.beep()
        }
        // Touch ID before touching stored credentials (backend token, API keys).
        let hasSecrets = Self.backendHost.map(RemoteLink.hasToken(for:)) ?? false || AppSettings.hasFredApiKey
        if hasSecrets, !(await SecretsGate.unlock()) {
            model.show(message: "Credentials locked — using local data without the backend. Reopen Settings → Backend to retry.")
            await useLocal(model, unlockedSecrets: false)
            return
        }
        if let host = Self.backendHost, RemoteLink.hasToken(for: host), await useBackend(host, model: model) {
            return
        }
        await useLocal(model)
        if let host = Self.backendHost, RemoteLink.hasToken(for: host), case .failed(let reason) = backendLink.phase {
            model.show(message: "Backend unreachable (\(reason)) — using local data")
        }
    }

    /// Connect to the backend (pairing with `code` when given). Returns true on success.
    @discardableResult
    func useBackend(_ host: RemoteHost, code: String? = nil, model: TerminalModel) async -> Bool {
        guard await SecretsGate.unlock() else { return false }
        await backendLink.connect(to: host, code: code)
        guard case .connected = backendLink.phase, let client = backendLink.client, let url = host.url else { return false }
        self.client = client
        model.connected(to: client, source: "backend")
        await model.pushSettings()  // keys saved on this Mac also reach the backend (until it restarts; .env persists)
        startRemote(model: model, gatewayURL: url, hello: backendLink.authHello(for: host))
        gateway.stop()  // the backend replaces the local sidecar
        localGatewayURL = nil
        watchBackend(host, model: model)
        return true
    }

    /// `fromWatchdog`: the backend dropped; keep the watchdog alive so it can switch back.
    func useLocal(_ model: TerminalModel, fromWatchdog: Bool = false, unlockedSecrets: Bool = true) async {
        if !fromWatchdog { watchdog?.cancel() }
        backendLink.disconnect()
        if localGatewayURL != nil, model.dataSource == "local" { return }  // already on the local sidecar
        do {
            let url = try await gateway.start()
            let client = DataClient(url: url)
            await client.start()
            self.client = client
            localGatewayURL = url
            model.connected(to: client, source: "local")
            if unlockedSecrets { await model.pushSettings() }
            startRemote(model: model, gatewayURL: url, hello: nil)
        } catch {
            model.failed(error.localizedDescription)
        }
    }

    /// If the backend connection drops, fall back to local data and retry the backend every minute.
    private func watchBackend(_ host: RemoteHost, model: TerminalModel) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, case .failed(let reason) = self.backendLink.phase else { continue }
                model.show(message: "Backend lost (\(reason)) — switched to local data")
                await self.useLocal(model, fromWatchdog: true)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    if await self.useBackend(host, model: model) {
                        model.show(message: "Backend back — using backend data")
                        return
                    }
                }
            }
        }
    }

    // MARK: iPad remote

    private func startRemote(model: TerminalModel, gatewayURL: URL, hello: Data?) {
        // iPads on the LAN are relayed to whatever this Mac uses (backend or local sidecar).
        remote.gatewayURL = gatewayURL
        remote.gatewayHello = hello
        remote.onCommand = { model.run($0) }
        remote.onAction = { action in
            switch action {
            case .back: model.back()
            case .cancel: model.cancel()
            case .toggleLink: model.activePanel.linked.toggle()
            case .layout1: model.setLayout(.single)
            case .layout2: model.setLayout(.split)
            case .layout4: model.setLayout(.grid)
            case .panel1, .panel2, .panel3, .panel4:
                let index = [RemoteAction.panel1, .panel2, .panel3, .panel4].firstIndex(of: action)!
                if index < model.panels.count { model.activate(model.panels[index]) }
            }
        }
        let macName = Host.current().localizedName ?? "Mac"
        remote.stateProvider = {
            RemoteState(
                macName: macName,
                panels: model.panels.map {
                    RemotePanel(security: $0.state.security, function: $0.state.function.rawValue,
                                args: $0.state.args, linked: $0.linked)
                },
                activePanel: model.panels.firstIndex { $0.id == model.activePanelID } ?? 0,
                layout: model.layout.rawValue,
                watchlistName: model.currentWatchlist.name,
                watchlist: model.watchlist,
                message: model.message
            )
        }
        guard !remoteStarted else { return }
        remoteStarted = true
        remote.start(hostName: Self.bonjourHostName)
        observeState()
    }

    private var remoteStarted = false

    /// Re-broadcast the workspace state to iPads whenever anything it reads changes.
    private func observeState() {
        withObservationTracking {
            _ = remote.stateProvider?()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.remote.broadcastState()
                self?.observeState()
            }
        }
    }

    private static var bonjourHostName: String {
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String? { return "\(local).local" }
        return ProcessInfo.processInfo.hostName
    }
}

// MARK: Toolbar: iPad pairing + Settings

struct MacToolbarAccessory: View {
    let server: RemoteServer
    @State private var showPairing = false

    private let amber = Color(red: 1.0, green: 0.66, blue: 0.10)

    var body: some View {
        HStack(spacing: 10) {
            Button { showPairing = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "ipad.landscape")
                    if !server.connected.isEmpty {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                    }
                }
            }
            .buttonStyle(.borderless)
            .help(server.connected.isEmpty ? "Pair an iPad" : "iPad connected: \(server.connected.joined(separator: ", "))")
            .accessibilityLabel(server.connected.isEmpty ? "Pair iPad" : "iPad connected")
            .sheet(isPresented: $showPairing) { PairingView(server: server) }

            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Settings (⌘,)")
                .accessibilityLabel("Settings")
        }
        .foregroundStyle(amber)
    }
}

struct PairingView: View {
    let server: RemoteServer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pair an iPad").font(.title2.bold())
            Text("Open finops on the iPad (same Wi-Fi), pick this Mac, and enter the code.")
                .foregroundStyle(.secondary)

            if let code = server.pairingCode, code.isValid() {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(code.code.map(String.init).joined(separator: " "))
                            .font(.system(size: 44, weight: .bold, design: .monospaced))
                            .textSelection(.enabled)
                        let left = max(0, Int(code.expires.timeIntervalSince(context.date)))
                        Text(left > 0 ? "Expires in \(left / 60):\(String(format: "%02d", left % 60))" : "Expired")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Button("Show pairing code") { server.beginPairing() }
                    .keyboardShortcut(.defaultAction)
            }

            Divider()
            LabeledContent("Server", value: server.status + (server.port.map { " · port \($0)" } ?? ""))
            LabeledContent("Connected", value: server.connected.isEmpty ? "—" : server.connected.joined(separator: ", "))

            if !server.devices.isEmpty {
                Text("Paired iPads").font(.headline)
                ForEach(server.devices) { device in
                    HStack {
                        Text(device.name)
                        Text("paired \(device.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Revoke", role: .destructive) { server.revoke(device) }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") {
                    server.endPairing()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
