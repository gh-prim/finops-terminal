import CryptoKit
import Foundation
import Security

public struct PairedDevice: Codable, Hashable, Identifiable, Sendable {
    public let id: String          // device ID chosen by the iPad
    public var name: String
    public var tokenHash: String   // SHA-256 of the bearer token; the token itself is never stored on the Mac
    public var pairedAt: Date
}

/// Short-lived 6-digit code shown on the Mac and typed on the iPad.
public struct PairingCode: Sendable, Equatable {
    public let code: String
    public let expires: Date
    public var failedAttempts = 0

    public static let lifetime: TimeInterval = 300
    public static let maxAttempts = 5

    public static func generate(now: Date = .now) -> PairingCode {
        PairingCode(code: String(format: "%06d", Int.random(in: 0...999_999)), expires: now.addingTimeInterval(lifetime))
    }

    public func isValid(at date: Date = .now) -> Bool {
        date < expires && failedAttempts < Self.maxAttempts
    }
}

public enum PairingCrypto {
    public static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time comparison of two hex digests.
    public static func matches(_ token: String, hash: String) -> Bool {
        let a = Array(Self.hash(token).utf8), b = Array(hash.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Generic-password Keychain storage (iPad tokens per Mac).
public enum RemoteKeychain {
    private static let service = "dev.finops.remote"

    public static func get(_ account: String) -> String? {
        var item: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
