import AppKit
import FinopsCore
import FinopsUI
import SwiftUI
import UserNotifications

@main
struct FinopsTerminalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = TerminalModel()

    var body: some Scene {
        Window("finops-terminal", id: "terminal") {
            TerminalView(model: model)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when running the bare SwiftPM executable (no Info.plist).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        gateway.stop()
    }

    private static func postNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        NSSound.beep()
    }

    func boot(_ model: TerminalModel) async {
        guard client == nil else { return }
        do {
            let url = try await gateway.start()
            let client = DataClient(url: url)
            await client.start()
            self.client = client
            model.notify = { title, body in Self.postNotification(title: title, body: body) }
            model.connected(to: client)
            await model.pushSettings()
        } catch {
            model.failed(error.localizedDescription)
        }
    }
}
