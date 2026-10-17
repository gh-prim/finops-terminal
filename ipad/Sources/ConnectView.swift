import FinopsRemote
import SwiftUI

/// Not connected: pick a Mac found on the network, enter the pairing code the
/// first time, or type an address manually.
struct ConnectView: View {
    let session: PadSession

    @State private var selected: RemoteHost?
    @State private var code = ""
    @State private var backendAddress = ""
    @State private var backendCode = ""
    @State private var manualHost = ""
    @State private var manualPort = "52817"
    @FocusState private var codeFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("finops").font(.system(size: 34, weight: .bold, design: .monospaced)).foregroundStyle(Pad.amber)
                    Text("Connect to finops-terminal on your Mac. Both devices must be on the same Wi-Fi.")
                        .foregroundStyle(Pad.muted)
                }

                section("finops backend (anywhere, over Tailscale)") {
                    TextField("finops-backend.<tailnet>.ts.net", text: $backendAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .padding(10)
                        .background(Pad.surface, in: RoundedRectangle(cornerRadius: 8))
                    if let host = backendHost {
                        if RemoteLink.hasToken(for: host) {
                            Button("Connect") { connectBackend(host, code: nil) }
                                .buttonStyle(.borderedProminent).tint(Pad.amber)
                                .disabled(connecting)
                        } else {
                            Text("First time: on the backend run  finops-admin pair  and enter the code.")
                                .foregroundStyle(Pad.muted)
                            HStack(spacing: 12) {
                                TextField("6-digit code", text: $backendCode)
                                    .keyboardType(.numberPad)
                                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                                    .frame(width: 200)
                                    .padding(10)
                                    .background(Pad.surface, in: RoundedRectangle(cornerRadius: 8))
                                    .onChange(of: backendCode) { backendCode = String(backendCode.filter(\.isNumber).prefix(6)) }
                                Button("Pair") { connectBackend(host, code: backendCode) }
                                    .buttonStyle(.borderedProminent).tint(Pad.amber)
                                    .disabled(backendCode.count != 6 || connecting)
                            }
                        }
                    }
                }

                section("Macs on this network") {
                    if session.browser.hosts.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Searching… open finops-terminal on the Mac.").foregroundStyle(Pad.muted)
                        }
                        Text(session.browser.status).font(.caption.monospaced()).foregroundStyle(Pad.muted)
                    }
                    ForEach(session.browser.hosts) { host in
                        Button { pick(host) } label: {
                            HStack {
                                Image(systemName: "laptopcomputer")
                                VStack(alignment: .leading) {
                                    Text(host.name).foregroundStyle(Pad.text)
                                    Text("\(host.host):\(host.port)").font(.caption.monospaced()).foregroundStyle(Pad.muted)
                                }
                                Spacer()
                                Text(RemoteLink.hasToken(for: host) ? "Paired" : "Pair")
                                    .foregroundStyle(Pad.amber)
                            }
                            .padding(14)
                            .background(selected == host ? Pad.raised : Pad.surface, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let host = selected, !RemoteLink.hasToken(for: host) || failed {
                    section("Pairing code for \(host.name)") {
                        Text("On the Mac, click the iPad icon in the toolbar, then Show pairing code.")
                            .foregroundStyle(Pad.muted)
                        HStack(spacing: 12) {
                            TextField("6-digit code", text: $code)
                                .keyboardType(.numberPad)
                                .font(.system(size: 28, weight: .bold, design: .monospaced))
                                .focused($codeFocused)
                                .frame(width: 220)
                                .padding(10)
                                .background(Pad.surface, in: RoundedRectangle(cornerRadius: 8))
                                .onChange(of: code) { code = String(code.filter(\.isNumber).prefix(6)) }
                            Button("Pair") { Task { await session.connect(to: host, code: code) } }
                                .buttonStyle(.borderedProminent)
                                .tint(Pad.amber)
                                .disabled(code.count != 6 || connecting)
                        }
                    }
                }

                if connecting {
                    HStack(spacing: 10) { ProgressView(); Text("Connecting…").foregroundStyle(Pad.muted) }
                }
                if case .failed(let reason) = session.link.phase {
                    Text(reason).foregroundStyle(Pad.red)
                }

                section("Manual address") {
                    HStack(spacing: 8) {
                        TextField("Mac host or IP (e.g. my-mac.local)", text: $manualHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(10)
                            .background(Pad.surface, in: RoundedRectangle(cornerRadius: 8))
                        TextField("Port", text: $manualPort)
                            .keyboardType(.numberPad)
                            .frame(width: 90)
                            .padding(10)
                            .background(Pad.surface, in: RoundedRectangle(cornerRadius: 8))
                        Button("Use") {
                            guard let port = UInt16(manualPort), !manualHost.isEmpty else { return }
                            pick(RemoteHost(name: manualHost, host: manualHost, port: port))
                        }
                        .disabled(manualHost.isEmpty || UInt16(manualPort) == nil)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .font(.system(size: 15, design: .monospaced))
        .onAppear { if backendAddress.isEmpty { backendAddress = session.backendURL } }
    }

    private var connecting: Bool { session.link.phase == .connecting }

    private var backendHost: RemoteHost? {
        RemoteHost.backendURL(from: backendAddress).map(RemoteHost.backend)
    }

    private func connectBackend(_ host: RemoteHost, code: String?) {
        session.backendURL = backendAddress
        backendCode = ""
        Task { await session.connect(to: host, code: code) }
    }

    private var failed: Bool {
        if case .failed = session.link.phase { return true }
        return false
    }

    private func pick(_ host: RemoteHost) {
        selected = host
        code = ""
        if RemoteLink.hasToken(for: host) {
            Task { await session.connect(to: host) }
        } else {
            codeFocused = true
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Pad.muted).tracking(1)
            content()
        }
    }
}
