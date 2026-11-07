import Foundation

/// Inloggningen och anropen till Edvins eget Supabase-projekt (fas 6).
///
/// Projektets adress sparas i inställningarna, den publika nyckeln (anon) och inloggningen i nyckelringen.
/// Lösenordet sparas aldrig: det används en gång, sedan räcker förnyelsetoken. Tabellerna och reglerna
/// som gör att bara den inloggade ser sina rader står i `tools/supabase/schema.sql`.
@MainActor
final class SyncClient {

    static let shared = SyncClient()

    enum Failure: LocalizedError {
        case notConfigured
        case notSignedIn
        case http(Int, String)
        case invalidResponse
        case network(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Synken är inte inställd. Fyll i projektets adress och nyckel under Inställningar."
            case .notSignedIn:
                return "Logga in under Inställningar för att synka."
            case .http(let code, let message):
                switch code {
                case 400 where message.lowercased().contains("invalid login"):
                    return "Fel e-post eller lösenord."
                case 401, 403:
                    return "Supabase nekade åtkomst (\(code)). Logga in igen. \(message.prefix(120))"
                case 404:
                    return "Tabellen saknas i Supabase. Har schema.sql körts? \(message.prefix(120))"
                default:
                    return "Supabase svarade med fel \(code). \(message.prefix(160))"
                }
            case .invalidResponse:
                return "Svaret från Supabase gick inte att läsa."
            case .network(let message):
                return "Ingen kontakt med Supabase. \(message)"
            }
        }
    }

    private let defaults = UserDefaults.standard
    private static let urlKey = "sync.url"
    private static let emailKey = "sync.email"
    private static let userKey = "sync.userID"
    private static let expiryKey = "sync.expiry"

    private init() {}

    // MARK: Inställningar

    var projectURL: String {
        get { defaults.string(forKey: Self.urlKey) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.urlKey) }
    }

    var anonKey: String {
        get { Keychain.string(.syncAnonKey) ?? "" }
        set { Keychain.set(newValue, for: .syncAnonKey) }
    }

    var email: String {
        get { defaults.string(forKey: Self.emailKey) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.emailKey) }
    }

    var userID: String? {
        defaults.string(forKey: Self.userKey)
    }

    var isConfigured: Bool {
        baseURL != nil && !anonKey.isEmpty
    }

    var isSignedIn: Bool {
        isConfigured && Keychain.string(.syncRefreshToken) != nil && userID != nil
    }

    private var baseURL: URL? {
        var text = projectURL
        while text.hasSuffix("/") {
            text.removeLast()
        }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }

    // MARK: Inloggning

    func signIn(email: String, password: String) async throws {
        guard isConfigured else { throw Failure.notConfigured }
        let json = try await authRequest(grant: "password", body: ["email": email, "password": password])
        try store(session: json)
        self.email = email
    }

    func signOut() {
        Keychain.set(nil, for: .syncRefreshToken)
        Keychain.set(nil, for: .syncAccessToken)
        defaults.removeObject(forKey: Self.userKey)
        defaults.removeObject(forKey: Self.expiryKey)
    }

    /// En giltig åtkomsttoken. Förnyas en minut innan den går ut.
    func accessToken() async throws -> String {
        guard isConfigured else { throw Failure.notConfigured }
        guard let refresh = Keychain.string(.syncRefreshToken) else { throw Failure.notSignedIn }
        let expiry = defaults.double(forKey: Self.expiryKey)
        if let token = Keychain.string(.syncAccessToken), Date().timeIntervalSince1970 < expiry - 60 {
            return token
        }
        let json = try await authRequest(grant: "refresh_token", body: ["refresh_token": refresh])
        try store(session: json)
        guard let token = Keychain.string(.syncAccessToken) else { throw Failure.notSignedIn }
        return token
    }

    private func store(session json: Any) throws {
        guard let info = json as? [String: Any],
              let access = info["access_token"] as? String,
              let refresh = info["refresh_token"] as? String,
              let user = info["user"] as? [String: Any],
              let id = user["id"] as? String else {
            throw Failure.invalidResponse
        }
        let lifetime = (info["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        Keychain.set(access, for: .syncAccessToken)
        Keychain.set(refresh, for: .syncRefreshToken)
        defaults.set(id, forKey: Self.userKey)
        defaults.set(Date().timeIntervalSince1970 + lifetime, forKey: Self.expiryKey)
    }

    private func authRequest(grant: String, body: [String: Any]) async throws -> Any {
        guard let base = baseURL,
              let url = URL(string: base.absoluteString + "/auth/v1/token?grant_type=" + grant) else {
            throw Failure.notConfigured
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(request)
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: Tabellerna

    /// Alla rader i en tabell som den inloggade får se, i omgångar om tusen.
    func rows(in table: String) async throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        var offset = 0
        while true {
            let request = try await restRequest(table: table, query: "select=*&order=updated_at.asc&limit=1000&offset=\(offset)",
                                                method: "GET")
            let data = try await send(request)
            guard let page = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw Failure.invalidResponse
            }
            result += page
            if page.count < 1000 {
                return result
            }
            offset += page.count
        }
    }

    /// Lägger in eller skriver över rader. `onConflict` är kolumnerna som gör en rad unik.
    func upsert(_ rows: [[String: Any]], into table: String, onConflict: String) async throws {
        var start = 0
        while start < rows.count {
            let batch = Array(rows[start..<min(start + 500, rows.count)])
            var request = try await restRequest(table: table, query: "on_conflict=" + onConflict, method: "POST")
            request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: batch)
            _ = try await send(request)
            start += batch.count
        }
    }

    private func restRequest(table: String, query: String, method: String) async throws -> URLRequest {
        guard let base = baseURL, let url = URL(string: base.absoluteString + "/rest/v1/" + table + "?" + query) else {
            throw Failure.notConfigured
        }
        let token = try await accessToken()
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.network(error.localizedDescription)
        }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var message = String(data: data, encoding: .utf8) ?? ""
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                message = (json["msg"] ?? json["message"] ?? json["error_description"] ?? json["error"]) as? String ?? message
            }
            throw Failure.http(http.statusCode, message)
        }
        return data
    }
}
