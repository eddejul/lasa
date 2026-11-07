import Foundation
import Security

/// Hemligheter (API-nyckeln till Gemini, inloggningen till synken) i iOS nyckelring.
/// Inget av det sparas i filer, i UserDefaults eller i repot.
enum Keychain {

    private static let service = "se.edvin.lasa"

    enum Key: String {
        case geminiAPIKey = "gemini.apiKey"
        case syncRefreshToken = "sync.refreshToken"
        case syncAccessToken = "sync.accessToken"
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
            return nil
        }
        return text
    }

    /// Sparar eller tar bort (tom text eller nil) en hemlighet.
    static func set(_ value: String?, for key: Key) {
        SecItemDelete(baseQuery(key) as CFDictionary)
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        var query = baseQuery(key)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func baseQuery(_ key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }
}
