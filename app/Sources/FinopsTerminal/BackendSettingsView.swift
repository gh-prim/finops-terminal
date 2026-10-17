import FinopsRemote
import FinopsUI
import SwiftUI

/// Settings → Backend: address, pairing, and which data source is live.
struct BackendSettingsView: View {
    let delegate: AppDelegate
    let model: TerminalModel

    @AppStorage("backend.url") private var address = ""
    @State private var code = ""
    @State private var busy = false
    @State private var result: String?

    private var host: RemoteHost? { RemoteHost.backendURL(from: address).map(RemoteHost.backend) }
    private var paired: Bool { host.map(RemoteLink.hasToken(for:)) ?? false }

    var body: some View {
        Form {
            Section("finops backend") {
                TextField("Address", text: $address, prompt: Text("finops-backend.<tailnet>.ts.net"))
                    .autocorrectionDisabled()
                if let url = host?.url {
                    Text(url.absoluteString).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                LabeledContent("Data source", value: model.dataSource ?? "—")
                LabeledContent("Pairing", value: paired ? "paired" : "not paired")
            }

            Section(paired ? "Re-pair" : "Pair this Mac") {
                Text("On the backend: ssh finops@<vm> docker exec finops-api-1 finops-admin pair")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    TextField("6-digit code", text: $code)
                        .onChange(of: code) { code = String(code.filter(\.isNumber).prefix(6)) }
                    Button("Pair") { Task { await pair() } }
                        .disabled(host == nil || code.count != 6 || busy)
                }
            }

            Section {
                HStack {
                    Button("Use backend") { Task { await connect() } }
                        .disabled(host == nil || !paired || busy || model.dataSource == "backend")
                    Button("Use local data") { Task { await delegate.useLocal(model) } }
                        .disabled(busy || model.dataSource == "local")
                    Spacer()
                    if paired, let host {
                        Button("Forget pairing", role: .destructive) {
                            RemoteLink.forgetToken(for: host)
                            result = "Pairing removed from this Mac."
                        }
                    }
                }
                if busy { ProgressView().controlSize(.small) }
                if let result { Text(result).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical, 8)
    }

    private func pair() async {
        guard let host else { return }
        busy = true
        defer { busy = false }
        let ok = await delegate.useBackend(host, code: code, model: model)
        code = ""
        result = ok ? "Paired — now using the backend." : failure
    }

    private func connect() async {
        guard let host else { return }
        busy = true
        defer { busy = false }
        result = await delegate.useBackend(host, model: model) ? "Connected to the backend." : failure
    }

    private var failure: String {
        if case .failed(let reason) = delegate.backendLink.phase { return reason }
        return "Couldn't connect."
    }
}
