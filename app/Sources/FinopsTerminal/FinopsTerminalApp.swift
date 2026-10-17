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
            SettingsView(model: model)
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

    func boot(_ model: TerminalModel) async {
        guard client == nil else { return }
        do {
            let url = try await gateway.start()
            let client = DataClient(url: url)
            await client.start()
            self.client = client
            model.notify = { title, body in
                Notifier.post(title: title, body: body)
                NSSound.beep()
            }
            model.connected(to: client)
            await model.pushSettings()
            startRemote(model: model, gatewayURL: url)
        } catch {
            model.failed(error.localizedDescription)
        }
    }

    // MARK: iPad remote

    private func startRemote(model: TerminalModel, gatewayURL: URL) {
        remote.gatewayURL = gatewayURL
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
        remote.start(hostName: Self.bonjourHostName)
        observeState()
    }

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
