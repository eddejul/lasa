import CryptoKit
import Foundation

/// Klienten för Förklara stycket (A1) och provet av nyckeln (U7), med Google Gemini på gratisnivån.
///
/// Varje svar sparas (`AIStore`), så att samma fråga aldrig hämtas två gånger, och appen räknar hur många
/// anrop som gjorts i dag. När kvoten är slut, nyckeln saknas eller är fel blir det ett begripligt besked.
/// Ordknappen (`GeminiClient`) har kvar sina egna anrop och regler, men räknas också här.
/// Används bara från huvudtråden, svaren kommer på huvudtråden.
enum AIClient {

    /// Googles adress. Självtestet byter den mot en låtsasserver med `-LasaGeminiURL http://127.0.0.1:<port>`.
    static var baseURL: String {
        if let override = overrideBaseURL {
            return override
        }
        let argument = UserDefaults.standard.string(forKey: "LasaGeminiURL") ?? ""
        return argument.isEmpty ? "https://generativelanguage.googleapis.com" : argument
    }

    /// Bara till självtestet (till exempel en stängd port för att pröva beskedet utan nät).
    static var overrideBaseURL: String?

    enum Failure: LocalizedError, Equatable {
        case noKey
        case badKey
        case unknownModel(String)
        case quotaPerMinute(seconds: Int?)
        case quotaToday
        case offline
        case network(String)
        case http(Int, String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .noKey:
                return "Förklaring med AI är inte uppsatt än. Det tar en minut: skapa en gratis nyckel i Google AI "
                    + "Studio och klistra in den."
            case .badKey:
                return "Google godkände inte nyckeln. Skapa en ny i Google AI Studio och klistra in den igen."
            case .unknownModel(let model):
                return "Modellen \(model) finns inte hos Google. Kontrollera modellens namn under Förklaring med AI "
                    + "i Inställningar."
            case .quotaPerMinute(let seconds):
                if let seconds = seconds, seconds > 0 {
                    return "Gratiskvoten för den här minuten är slut. Prova igen om \(seconds) sekunder."
                }
                return "Gratiskvoten för den här minuten är slut. Prova igen om en minut."
            case .quotaToday:
                return "Dagens gratiskvot hos Google är slut. Den fylls på klockan \(AIClient.quotaResetText) "
                    + "svensk tid. Svar som redan hämtats finns kvar."
            case .offline:
                return "Ingen kontakt med Google. Kontrollera att iPaden är ansluten till internet."
            case .network(let message):
                return "Ingen kontakt med Google. \(message)"
            case .http(let code, let message):
                return "Gemini svarade med fel \(code). \(message.prefix(160))"
            case .invalidResponse:
                return "Svaret från Gemini gick inte att läsa. Prova igen."
            }
        }

        /// Fel som gör att knappen pekar på guiden (U7) i stället för att bara be om ett nytt försök.
        var needsSetup: Bool {
            switch self {
            case .noKey, .badKey, .unknownModel: return true
            default: return false
            }
        }
    }

    /// Ett svar från modellen, och om det kom ur de sparade svaren.
    struct Answer {
        let json: [String: Any]
        let cached: Bool
    }

    // MARK: Status (U7)

    enum KeyStatus: Equatable {
        case notSet
        case untested
        case working
        case failing(String)

        var title: String {
            switch self {
            case .notSet: return "Inte uppsatt"
            case .untested: return "Inte provad än"
            case .working: return "Fungerar"
            case .failing: return "Fel"
            }
        }
    }

    static var hasKey: Bool {
        Keychain.string(.geminiAPIKey) != nil
    }

    /// Nyckelns läge: ingen nyckel, inte provad, fungerar eller fel (det senaste anropets utfall).
    static var keyStatus: KeyStatus {
        guard hasKey else { return .notSet }
        let stored = AIStore.shared.meta("key_status") ?? ""
        if stored == "ok" {
            return .working
        }
        if stored.hasPrefix("fel:") {
            return .failing(String(stored.dropFirst(4)))
        }
        return .untested
    }

    /// Sparar nyckelns läge efter ett anrop. Kvot och nät säger inget om nyckeln, då står läget kvar.
    static func noteKey(_ result: Result<Void, Failure>) {
        switch result {
        case .success:
            AIStore.shared.setMeta("key_status", "ok")
        case .failure(let failure) where failure.needsSetup:
            AIStore.shared.setMeta("key_status", "fel:" + (failure.errorDescription ?? ""))
        case .failure:
            break
        }
    }

    /// Glömmer nyckelns läge, när nyckeln byts eller tas bort.
    static func resetKeyStatus() {
        AIStore.shared.setMeta("key_status", "")
    }

    /// Anropen till Gemini i dag (lokal dag), även ordknappens.
    static var callsToday: Int {
        AIStore.shared.calls(on: AIStore.day(Date()))
    }

    /// Ordknappen (`GeminiClient`) räknas också. `status` är HTTP-svaret, nil när inget svar kom.
    static func recordWordButtonCall(status: Int?) {
        AIStore.shared.recordCall(failed: status.map { !(200..<300).contains($0) } ?? true, quota: status == 429)
        if let status = status, (200..<300).contains(status) {
            noteKey(.success(()))
        }
    }

    /// Klockslaget i svensk (lokal) tid när dagens kvot fylls på: midnatt i Kalifornien, enligt Googles
    /// sida om gränserna (kontrollerad 9 november 2026).
    static var quotaResetText: String {
        guard let pacific = TimeZone(identifier: "America/Los_Angeles") else { return "9" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = pacific
        let now = Date()
        guard let midnight = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0),
                                               matchingPolicy: .nextTime) else { return "9" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "sv_SE")
        formatter.timeZone = .current
        formatter.dateFormat = "HH.mm"
        return formatter.string(from: midnight)
    }

    // MARK: Fråga

    /// Frågar modellen, eller ger det sparade svaret om exakt samma fråga redan ställts med samma modell.
    /// `kind` skiljer frågetyperna åt i de sparade svaren (till exempel "stycke"). `timeout` är tidsgränsen för
    /// anropet, och med `useCache` false läses och sparas inget svar i `ai-svar.sqlite` (AI-frågorna, K6b, som
    /// sparar sina frågor själva). Standardvärdena ger samma anrop som förut (A1, A2, U7 och ordknappen).
    static func generate(kind: String, prompt: String, schema: [String: Any], maxTokens: Int,
                         timeout: TimeInterval = 40, useCache: Bool = true,
                         completion: @escaping (Result<Answer, Failure>) -> Void) {
        let model = GeminiClient.model
        let cacheKey = Self.cacheKey(kind: kind, model: model, prompt: prompt, schema: schema)
        if useCache, let cached = AIStore.shared.answer(for: cacheKey) {
            completion(.success(Answer(json: cached, cached: true)))
            return
        }
        guard let key = Keychain.string(.geminiAPIKey) else {
            completion(.failure(.noKey))
            return
        }
        send(prompt: prompt, schema: schema, key: key, model: model, maxTokens: maxTokens, timeout: timeout,
             useSchema: true) { result in
            switch result {
            case .success(let json):
                if useCache {
                    AIStore.shared.store(json, for: cacheKey, kind: kind, model: model)
                }
                noteKey(.success(()))
                completion(.success(Answer(json: json, cached: false)))
            case .failure(let failure):
                noteKey(.failure(failure))
                completion(.failure(failure))
            }
        }
    }

    /// Provar nyckeln billigt (U7): frågar efter modellen (models.get), vilket inte drar av gratiskvoten för svar
    /// men visar om nyckeln godkänns och om modellen finns.
    static func testKey(_ key: String, completion: @escaping (Result<Void, Failure>) -> Void) {
        let model = GeminiClient.model
        guard let url = modelURL(model, suffix: "") else {
            completion(.failure(.invalidResponse))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<Void, Failure>
            if let error = error {
                result = .failure(networkFailure(error))
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(failure(status: http.statusCode, data: data, model: model))
            } else {
                result = .success(())
            }
            DispatchQueue.main.async {
                // Provet räknas inte bland dagens anrop: det drar inte av kvoten för svar.
                if key == Keychain.string(.geminiAPIKey) {
                    noteKey(result)
                }
                completion(result)
            }
        }.resume()
    }

    // MARK: Nätet

    private static func modelURL(_ model: String, suffix: String) -> URL? {
        let name = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? GeminiClient.defaultModel
        return URL(string: "\(baseURL)/v1beta/models/\(name)\(suffix)")
    }

    private static func send(prompt: String, schema: [String: Any], key: String, model: String, maxTokens: Int,
                             timeout: TimeInterval = 40, useSchema: Bool,
                             completion: @escaping (Result<[String: Any], Failure>) -> Void) {
        guard let url = modelURL(model, suffix: ":generateContent") else {
            completion(.failure(.invalidResponse))
            return
        }
        var generation: [String: Any] = ["responseMimeType": "application/json", "temperature": 0.3,
                                         "maxOutputTokens": maxTokens]
        if useSchema {
            generation["responseJsonSchema"] = schema
        }
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": generation,
        ]
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            var result: Result<[String: Any], Failure>
            var retryWithoutSchema = false
            var status: Int?
            if let error = error {
                result = .failure(networkFailure(error))
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                status = http.statusCode
                let message = errorMessage(data) ?? ""
                // Äldre modeller känner inte till responseJsonSchema: fråga igen med schemat bara i texten,
                // som ordknappen gör.
                retryWithoutSchema = useSchema && http.statusCode == 400 && message.contains("response")
                    && !message.lowercased().contains("api key")
                result = .failure(failure(status: http.statusCode, data: data, model: model))
            } else if let data = data, let json = GeminiClient.answerJSON(data) {
                status = (response as? HTTPURLResponse)?.statusCode
                result = .success(json)
            } else {
                result = .failure(.invalidResponse)
            }
            DispatchQueue.main.async {
                AIStore.shared.recordCall(failed: (try? result.get()) == nil, quota: status == 429)
                if retryWithoutSchema {
                    let withSchema = prompt + "\n\nJSON-schema: " + (jsonText(schema) ?? "")
                    send(prompt: withSchema, schema: schema, key: key, model: model, maxTokens: maxTokens,
                         timeout: timeout, useSchema: false, completion: completion)
                } else {
                    completion(result)
                }
            }
        }.resume()
    }

    private static func networkFailure(_ error: Error) -> Failure {
        let code = (error as NSError).code
        if [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed, NSURLErrorDataNotAllowed,
            NSURLErrorInternationalRoamingOff].contains(code) {
            return .offline
        }
        return .network(error.localizedDescription)
    }

    /// Googles fel som ett besked. 429 delas upp i dagens kvot och minutens, efter `quotaId` i svaret
    /// (till exempel GenerateRequestsPerDayPerProjectPerModel-FreeTier) och väntetiden i RetryInfo.
    static func failure(status: Int, data: Data?, model: String) -> Failure {
        let message = errorMessage(data) ?? ""
        let lower = message.lowercased()
        switch status {
        case 400 where lower.contains("api key") || lower.contains("api_key"):
            return .badKey
        case 401, 403:
            return .badKey
        case 404:
            return .unknownModel(model)
        case 429:
            let details = errorDetails(data)
            let quotaIDs = details.flatMap { detail -> [String] in
                ((detail["violations"] as? [[String: Any]]) ?? []).compactMap { $0["quotaId"] as? String }
            }
            if quotaIDs.contains(where: { $0.contains("PerDay") }) || lower.contains("per day") {
                return .quotaToday
            }
            let delay = details.compactMap { $0["retryDelay"] as? String }.first
            let seconds = delay.flatMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: "s"))) }
            return .quotaPerMinute(seconds: seconds.map { Int($0.rounded(.up)) })
        default:
            return .http(status, message)
        }
    }

    private static func errorObject(_ data: Data?) -> [String: Any]? {
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["error"] as? [String: Any]
    }

    private static func errorMessage(_ data: Data?) -> String? {
        errorObject(data)?["message"] as? String
    }

    private static func errorDetails(_ data: Data?) -> [[String: Any]] {
        (errorObject(data)?["details"] as? [[String: Any]]) ?? []
    }

    private static func jsonText(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Nyckeln för ett sparat svar: frågetypen, modellen, frågan och schemat.
    static func cacheKey(kind: String, model: String, prompt: String, schema: [String: Any]) -> String {
        let text = [kind, model, prompt, jsonText(schema) ?? ""].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Sparade AI-svar och dagens anrop, i `ai-svar.sqlite` under Application Support med en egen trappa.
/// Det är en cache: den ingår inte i säkerhetskopian, eftersom svaret till en markering också sparas som
/// anteckning (den varaktiga kopian). Används bara från huvudtråden.
final class AIStore {

    static let shared = AIStore()

    /// Trappan. Lägg nya steg sist, ändra aldrig ett steg som redan finns.
    static let migrations: [String] = [
        """
            CREATE TABLE IF NOT EXISTS answers (
                key TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                model TEXT NOT NULL,
                created REAL NOT NULL,
                json TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS usage (
                day TEXT PRIMARY KEY,
                calls INTEGER NOT NULL DEFAULT 0,
                failures INTEGER NOT NULL DEFAULT 0,
                quota INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """,
    ]

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ai-svar.sqlite")
    }

    private let db: SQLiteDatabase?

    private init() {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let db = try SQLiteDatabase(path: url.path, readOnly: false)
            try db.executeScript("PRAGMA journal_mode = WAL;")
            let versions = try db.migrate(Self.migrations)
            if versions.from != versions.to {
                AppLog.shared.write("ai-svar.sqlite: version \(versions.from) till \(versions.to)")
            }
            self.db = db
        } catch {
            AppLog.shared.write("ai-svar.sqlite gick inte att öppna: \(error)")
            self.db = nil
        }
    }

    /// Databasens version, till självtestet.
    var schemaVersion: Int {
        (try? db?.userVersion()) ?? -1
    }

    /// Dagen i lokal tid, som "2026-11-09".
    static func day(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    func answer(for key: String) -> [String: Any]? {
        var text: String?
        try? db?.query("SELECT json FROM answers WHERE key = ?", [key]) { row in text = row.string(0) }
        guard let data = text?.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func store(_ json: [String: Any], for key: String, kind: String, model: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        run("svaret") { db in
            try db.execute("INSERT OR REPLACE INTO answers (key, kind, model, created, json) VALUES (?, ?, ?, ?, ?)",
                           [key, kind, model, Date().timeIntervalSince1970, text])
        }
    }

    var answerCount: Int {
        var count = 0
        try? db?.query("SELECT COUNT(*) FROM answers") { row in count = row.int(0) }
        return count
    }

    func recordCall(failed: Bool, quota: Bool) {
        let today = Self.day(Date())
        run("dagens anrop") { db in
            try db.execute("INSERT OR IGNORE INTO usage (day) VALUES (?)", [today])
            try db.execute("UPDATE usage SET calls = calls + 1, failures = failures + ?, quota = quota + ? WHERE day = ?",
                           [failed ? 1 : 0, quota ? 1 : 0, today])
        }
    }

    func calls(on day: String) -> Int {
        var count = 0
        try? db?.query("SELECT calls FROM usage WHERE day = ?", [day]) { row in count = row.int(0) }
        return count
    }

    func meta(_ key: String) -> String? {
        var value: String?
        try? db?.query("SELECT value FROM meta WHERE key = ?", [key]) { row in value = row.string(0) }
        return value
    }

    func setMeta(_ key: String, _ value: String) {
        run("inställningen") { db in
            try db.execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [key, value])
        }
    }

    /// En skrivning i en transaktion. Ett fel hamnar bara i loggen: det är en cache, inget går förlorat.
    private func run(_ what: String, _ body: (SQLiteDatabase) throws -> Void) {
        guard let db = db else { return }
        do {
            try db.transaction { try body(db) }
        } catch {
            AppLog.shared.write("AI-svaren: \(what) kunde inte sparas: \(error)")
        }
    }
}
