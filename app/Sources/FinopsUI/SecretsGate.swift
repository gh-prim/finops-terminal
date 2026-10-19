import FinopsDash
import Foundation
import LocalAuthentication

/// Touch ID (or the device password as fallback) before the app reads its stored credentials:
/// the backend token and provider API keys. Unlocked once per launch.
@MainActor
public enum SecretsGate {
    public private(set) static var unlocked = false

    /// Settings → "Require Touch ID to unlock credentials" (on by default).
    public static var required: Bool {
        get { UserDefaults.standard.object(forKey: "security.requireBiometrics") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "security.requireBiometrics") }
    }

    public static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "your password"
        }
    }

    /// Returns true when credentials may be used (already unlocked, not required, or authenticated now).
    public static func unlock(reason: String = "unlock your finops credentials") async -> Bool {
        if unlocked || !required { return true }
        let context = LAContext()
        context.localizedFallbackTitle = "Use Password"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode/biometrics configured on this device: nothing stronger to ask for.
            unlocked = true
            return true
        }
        do {
            unlocked = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            unlocked = false
        }
        return unlocked
    }
}
