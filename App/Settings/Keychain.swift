import Foundation
import Security

/// Hemligheter (API-nyckeln till Gemini, inloggningen till synken) i iOS nyckelring.
/// Inget av det sparas i filer, i UserDefaults eller i repot.
enum Keychain {

    private static let service = "se.edvin.lasa"

    /// Reserv när nyckelringen inte går att skriva i (en osignerad app i simulatorn). Gäller bara tills
    /// appen stängs. På iPaden signerar Sideloadly appen, och då används nyckelringen.
    private static var memory: [Key: String] = [:]

    /// Svaret från nyckelringen vid senaste sparandet, till självtestet.
    private(set) static var lastStatus: OSStatus = errSecSuccess

    enum Key: String {
        case geminiAPIKey = "gemini.apiKey"
        case syncRefreshToken = "sync.refreshToken"
        case syncAccessToken = "sync.accessToken"
        case syncAnonKey = "sync.anonKey"
    }

    static func string(_ key: Key) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else {
            return memory[key]
        }
        return text
    }

    /// Sparar eller tar bort (tom text eller nil) en hemlighet.
    static func set(_ value: String?, for key: Key) {
        SecItemDelete(baseQuery(key) as CFDictionary)
        memory[key] = nil
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        var query = baseQuery(key)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        lastStatus = SecItemAdd(query as CFDictionary, nil)
        if lastStatus != errSecSuccess {
            memory[key] = value
        }
    }

    private static func baseQuery(_ key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }
}
