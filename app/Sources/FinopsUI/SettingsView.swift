import FinopsCore
import FinopsDash
import Foundation
import Security
import SwiftUI

/// Provider settings. The FRED key lives in the Keychain; the EDGAR contact in UserDefaults.
public enum AppSettings {
    private static let service = "dev.finops.terminal"
    private static let fredAccount = "fred-api-key"

    public static var edgarContact: String {
        get { UserDefaults.standard.string(forKey: "edgarContact") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "edgarContact") }
    }

    /// Whether a FRED key is stored, without reading it (no Keychain prompt).
    public static var hasFredApiKey: Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: fredAccount, kSecReturnAttributes as String: true,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public static var fredApiKey: String {
        get {
            var item: CFTypeRef?
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: fredAccount, kSecReturnData as String: true,
            ]
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        set {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: fredAccount,
            ]
            SecItemDelete(base as CFDictionary)
            guard !newValue.isEmpty else { return }
            var add = base
            add[kSecValueData as String] = Data(newValue.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

extension TerminalModel {
    /// Push provider settings to the gateway (on connect and after saving).
    public func pushSettings() async {
        guard let client, await SecretsGate.unlock() else { return }
        do {
            try await client.configure(edgarContact: AppSettings.edgarContact, fredApiKey: AppSettings.fredApiKey)
        } catch {
            report(error)
        }
    }
}

public struct SettingsView: View {
    let model: TerminalModel

    @State private var edgarContact = AppSettings.edgarContact
    @State private var fredKey = ""
    @State private var saved = false
    @State private var requireBiometrics = SecretsGate.required

    public init(model: TerminalModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            Section("FRED (macro data: ECON, CURVE)") {
                SecureField("API key", text: $fredKey)
                Link("Get a free key at fred.stlouisfed.org", destination: URL(string: "https://fred.stlouisfed.org/docs/api/api_key.html")!)
                    .font(.caption)
            }
            Section("Security") {
                Toggle("Require \(SecretsGate.biometryName) to unlock credentials at launch", isOn: $requireBiometrics)
                    .onChange(of: requireBiometrics) { SecretsGate.required = requireBiometrics }
                Text("Protects the backend token and API keys stored in the Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("SEC EDGAR (FIN, FILE)") {
                TextField("Contact email for the User-Agent", text: $edgarContact)
                Text("SEC asks automated clients to identify themselves with a contact address.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if saved { Text("Saved").foregroundStyle(.secondary) }
                Button("Save") {
                    AppSettings.fredApiKey = fredKey.trimmingCharacters(in: .whitespaces)
                    AppSettings.edgarContact = edgarContact.trimmingCharacters(in: .whitespaces)
                    saved = true
                    Task { await model.pushSettings() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .task {
            // Read the key only when Settings opens, after the launch unlock.
            if await SecretsGate.unlock(reason: "show your finops API keys") { fredKey = AppSettings.fredApiKey }
        }
        .frame(width: 460)
        .padding(.vertical, 8)
    }
}
