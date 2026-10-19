import FinopsCore
import FinopsDash
import FinopsRemote
import SwiftUI

@main
struct FinopsTVApp: App {
    @State private var session = TVSession()

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    let session: TVSession

    var body: some View {
        Group {
            if session.isConnected {
                DisplayView(session: session)
            } else {
                ConnectView(session: session)
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .task { session.browser.start() }
        .onChange(of: session.browser.hosts) {
            Task { await session.autoConnectIfPossible() }
        }
        .onChange(of: session.link.phase) { _, phase in
            if case .failed = phase { Task { await session.reconnectSoon() } }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }  // a wall screen never sleeps
    }
}

// MARK: Display

/// Full-screen dashboard. Remote: ◀ ▶ previous/next, play/pause auto-rotate,
/// click for the dashboard list, Menu to leave the list.
struct DisplayView: View {
    let session: TVSession
    @State private var showMenu = false
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / DashboardView.canvas.width, geo.size.height / DashboardView.canvas.height)
            ZStack {
                Palette.background
                if let dashboard = session.current {
                    DashboardView(dashboard: dashboard, client: session.link.client)
                        .id(dashboard.id)
                        .scaleEffect(scale)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .transition(.opacity)
                } else {
                    VStack(spacing: 12) {
                        Text("No dashboard yet").font(.title2)
                        Text("Build one on the Mac: type DASH in finops-terminal.").foregroundStyle(Palette.muted)
                    }
                }
                if showMenu { menu }
            }
            .animation(.easeInOut(duration: 0.4), value: session.current?.id)
        }
        .ignoresSafeArea()
        .focusable(!showMenu)
        .focused($focused)
        .onAppear { focused = true }
        .onMoveCommand { direction in
            switch direction {
            case .left: session.step(-1)
            case .right: session.step(1)
            default: break
            }
        }
        .onPlayPauseCommand { session.rotating.toggle() }
        .onTapGesture { showMenu = true }
        .onExitCommand(perform: showMenu ? { showMenu = false; focused = true } : nil)
        .onChange(of: session.link.displayRequest?.at) { session.handleDisplayRequest() }
        .task(id: session.rotating) {
            while session.rotating, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(session.rotateSeconds))
                if session.rotating, !showMenu { session.step(1) }
            }
        }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Dashboards").font(.title3.bold()).foregroundStyle(Palette.accent)
            ForEach(session.dashboards) { dashboard in
                Button {
                    session.show(dashboard.id)
                    showMenu = false
                    focused = true
                } label: {
                    HStack {
                        Text(dashboard.name)
                        Spacer()
                        if dashboard.id == session.current?.id { Image(systemName: "checkmark") }
                    }
                }
            }
            Toggle("Rotate every \(session.rotateSeconds) s", isOn: Binding(get: { session.rotating },
                                                                           set: { session.rotating = $0 }))
            HStack {
                Text("Connected to \(session.connectedHost?.name ?? "Mac")").foregroundStyle(Palette.muted)
                Spacer()
                Button("Disconnect", role: .destructive) { session.disconnect() }
            }
        }
        .padding(48)
        .frame(width: 820)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }
}

// MARK: Connect

/// Pick a Mac running finops-terminal and enter its pairing code.
struct ConnectView: View {
    let session: TVSession
    @State private var selected: RemoteHost?
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("finops").font(.system(size: 64, weight: .bold, design: .monospaced)).foregroundStyle(Palette.accent)
            Text("Show your finops-terminal dashboards on this TV.").foregroundStyle(Palette.muted)

            if case .failed(let reason) = session.link.phase {
                Text(reason).foregroundStyle(Palette.down)
            }
            if case .connecting = session.link.phase {
                ProgressView("Connecting…")
            }

            if let host = selected, !RemoteLink.hasToken(for: host) {
                Text("On the Mac, click the iPad icon in the toolbar, then Show pairing code. Enter it here:")
                TextField("6-digit code", text: $code)
                    .keyboardType(.numberPad)
                    .frame(width: 480)
                    .onSubmit { pair(host) }
                HStack {
                    Button("Pair") { pair(host) }.disabled(code.count != 6)
                    Button("Back") { selected = nil; code = "" }
                }
            } else {
                Text("Macs on this network").font(.headline)
                if session.browser.hosts.isEmpty {
                    Text("Looking for finops-terminal… Open it on your Mac (same network).").foregroundStyle(Palette.muted)
                }
                ForEach(session.browser.hosts.filter { !$0.isBackend }) { host in
                    Button {
                        if RemoteLink.hasToken(for: host) {
                            Task { await session.connect(to: host) }
                        } else {
                            selected = host
                        }
                    } label: {
                        Label(host.name, systemImage: RemoteLink.hasToken(for: host) ? "desktopcomputer" : "lock")
                    }
                }
            }
            Spacer()
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func pair(_ host: RemoteHost) {
        let entered = code.filter(\.isNumber)
        guard entered.count == 6 else { return }
        Task {
            await session.connect(to: host, code: entered)
            if session.isConnected { selected = nil; code = "" }
        }
    }
}
