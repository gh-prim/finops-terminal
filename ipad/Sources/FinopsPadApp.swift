import FinopsRemote
import FinopsUI
import SwiftUI

@main
struct FinopsPadApp: App {
    @State private var session = PadSession()

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    let session: PadSession

    var body: some View {
        Group {
            if session.isConnected {
                ConnectedView(session: session)
            } else {
                ConnectView(session: session)
            }
        }
        .background(Pad.background.ignoresSafeArea())
        .task {
            session.browser.start()
        }
        .onChange(of: session.browser.hosts) {
            Task { await session.autoConnectIfPossible() }
        }
    }
}

/// Connected: mode switch on top, then the keypad or the full terminal.
struct ConnectedView: View {
    @Bindable var session: PadSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Mode", selection: $session.mode) {
                    ForEach(PadSession.Mode.allCases) { mode in
                        Label(mode.rawValue, systemImage: mode == .keypad ? "keyboard" : "rectangle.split.3x1")
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                Spacer()
                if case .connected(let mac) = session.link.phase {
                    Label(mac, systemImage: "laptopcomputer")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Pad.muted)
                }
                Button("Disconnect", role: .destructive) { session.disconnect() }
                    .font(.system(size: 13, design: .monospaced))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Pad.surface)

            switch session.mode {
            case .keypad:
                KeypadView(link: session.link)
            case .terminal:
                TerminalView(model: session.model)
                    .id(ObjectIdentifier(session.model))
            }
        }
    }
}
