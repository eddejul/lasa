import Foundation

/// Svaret från AI-knappen: vilken betydelse ordet har i meningen, och en kort förklaring.
struct WordExplanation: Equatable {
    /// Betydelsen ur ordboken som passar, med ordbokens egen text.
    let senseText: String?
    /// Ordet ur ordbokens lista (synonym eller översättning) som passar bäst i meningen.
    let bestWord: String?
    /// En eller två meningar på svenska.
    let explanation: String
}

/// AI-knappen "Förklara i meningen" (fas 6), med Google Gemini.
///
/// Gratisnivån räcker. Nyckeln skrivs in under Inställningar och sparas i nyckelringen, modellen är en
/// inställning. Modellen får meningen, ordet och ordbokens betydelser, och ska bara välja bland dem
/// (strukturerat JSON-svar). Ett ord den hittar på själv visas inte. Utan nyckel syns ingen knapp.
enum GeminiClient {

    /// En gratismodell som är snabb nog för en knapp (kontrollerad på Googles prissida 7 november 2026).
    static let defaultModel = "gemini-3.5-flash-lite"
    private static let modelKey = "ai.model"

    enum Failure: LocalizedError {
        case noKey
        case http(Int, String)
        case invalidResponse
        case network(String)

        var errorDescription: String? {
            switch self {
            case .noKey:
                return "Ingen API-nyckel. Skriv in den under Inställningar."
            case .http(let code, let message):
                switch code {
                case 400 where message.lowercased().contains("api key"):
                    return "Google godkände inte nyckeln. Kontrollera den under Inställningar."
                case 401, 403:
                    return "Google godkände inte nyckeln. Kontrollera den under Inställningar."
                case 404:
                    return "Modellen finns inte. Kontrollera modellens namn under Inställningar."
                case 429:
                    return "Gratiskvoten är slut för stunden. Prova igen om en stund."
                default:
                    return "Gemini svarade med fel \(code). \(message.prefix(160))"
                }
            case .invalidResponse:
                return "Svaret från Gemini gick inte att läsa."
            case .network(let message):
                return "Ingen kontakt med Gemini. \(message)"
            }
        }
    }

    static var model: String {
        get {
            let stored = UserDefaults.standard.string(forKey: modelKey)?.trimmingCharacters(in: .whitespaces) ?? ""
            return stored.isEmpty ? defaultModel : stored
        }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: modelKey)
        }
    }

    static var isConfigured: Bool {
        Keychain.string(.geminiAPIKey) != nil
    }

    // MARK: Fråga

    /// Ber modellen välja betydelse och ord. Svaret kommer på huvudtråden.
    static func explain(_ lookup: WordLookup, sentence: String,
                        completion: @escaping (Result<WordExplanation, Error>) -> Void) {
        guard let key = Keychain.string(.geminiAPIKey) else {
            completion(.failure(Failure.noKey))
            return
        }
        let candidates = Candidates(lookup)
        send(prompt: prompt(lookup, sentence: sentence, candidates: candidates),
             schema: candidates.schema, key: key, useSchema: true) { result in
            completion(result.flatMap { candidates.explanation(from: $0) })
        }
    }

    /// Provar nyckeln och modellen med en liten fråga. Används av Inställningar.
    static func test(key: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let schema: [String: Any] = ["type": "object", "properties": ["ok": ["type": "boolean"]], "required": ["ok"]]
        send(prompt: "Svara med {\"ok\": true}.", schema: schema, key: key, useSchema: true) { result in
            completion(result.map { _ in () })
        }
    }

    private static func prompt(_ lookup: WordLookup, sentence: String, candidates: Candidates) -> String {
        var lines = [
            "Du hjälper en svensk läsare att förstå ett ord i en bok.",
            "Ordet: \(lookup.word)",
            "Meningen: \(sentence.isEmpty ? lookup.word : sentence)",
            "Språk: \(lookup.language.name)",
            "",
            "Ordbokens betydelser (id: förklaring; ord):",
        ]
        lines += candidates.senseLines
        if !candidates.words.isEmpty {
            lines.append("")
            lines.append("Ord att välja bland: " + candidates.words.joined(separator: ", "))
        }
        lines += [
            "",
            "Välj det id som passar ordets betydelse i just den här meningen.",
            "Välj det ord ur listan som bäst kan ersätta ordet i meningen" + (lookup.language == .english
                ? ", helst en svensk översättning." : "."),
            "Hitta inte på egna ord: best_word ska stå ordagrant i listan, eller vara tom.",
            "Skriv explanation på enkel svenska, högst två korta meningar, om vad ordet betyder här.",
            "Svara bara med JSON enligt schemat.",
        ]
        return lines.joined(separator: "\n")
    }

    // MARK: Nätet

    private static func send(prompt: String, schema: [String: Any], key: String, useSchema: Bool,
                             completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let model = Self.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? defaultModel
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            completion(.failure(Failure.invalidResponse))
            return
        }
        var generation: [String: Any] = ["responseMimeType": "application/json", "temperature": 0.2,
                                         "maxOutputTokens": 400]
        if useSchema {
            generation["responseJsonSchema"] = schema
        }
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": generation,
        ]
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<[String: Any], Error>
            var retryWithoutSchema = false
            if let error = error {
                result = .failure(Failure.network(error.localizedDescription))
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let message = Self.errorMessage(data) ?? ""
                // Äldre modeller känner inte till responseJsonSchema: fråga igen med schemat bara i texten.
                retryWithoutSchema = useSchema && http.statusCode == 400 && message.contains("response")
                    && !message.lowercased().contains("api key")
                result = .failure(Failure.http(http.statusCode, message))
            } else if let data = data, let json = Self.answerJSON(data) {
                result = .success(json)
            } else {
                result = .failure(Failure.invalidResponse)
            }
            DispatchQueue.main.async {
                // A1: ordknappens anrop räknas bland dagens anrop. Frågan och svaret är oförändrade.
                AIClient.recordWordButtonCall(status: (response as? HTTPURLResponse)?.statusCode)
                if retryWithoutSchema {
                    let withSchema = prompt + "\n\nJSON-schema: " + (Self.jsonText(schema) ?? "")
                    send(prompt: withSchema, schema: schema, key: key, useSchema: false, completion: completion)
                } else {
                    completion(result)
                }
            }
        }.resume()
    }

    private static func errorMessage(_ data: Data?) -> String? {
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }

    /// Texten i svaret, tolkad som JSON. Tål kodblock runt JSON:en.
    static func answerJSON(_ data: Data) -> [String: Any]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        var text = parts.compactMap { $0["text"] as? String }.joined()
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            text = String(text[start...end])
        }
        guard let answer = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: answer) as? [String: Any]
    }

    private static func jsonText(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Ordbokens kandidater

    /// Betydelserna och orden som modellen får välja bland, med korta id:n.
    struct Candidates {
        let senseLines: [String]
        let senseTexts: [String: String]
        let words: [String]

        init(_ lookup: WordLookup) {
            var lines: [String] = []
            var texts: [String: String] = [:]
            var words: [String] = []
            for (entryIndex, entry) in lookup.entries.prefix(3).enumerated() {
                let translations = entry.translations.map(\.text)
                words += translations
                for (senseIndex, sense) in entry.senses.prefix(6).enumerated() {
                    let id = "b\(entryIndex + 1)\(Character(UnicodeScalar(UInt8(97 + senseIndex))))"
                    let synonyms = sense.synonyms.prefix(8).map(\.word)
                    words += synonyms
                    let gloss = sense.definition ?? synonyms.prefix(4).joined(separator: ", ")
                    texts[id] = gloss
                    var line = "\(id) (\(entry.posName)): \(gloss)"
                    if !synonyms.isEmpty {
                        line += "; " + synonyms.joined(separator: ", ")
                    }
                    lines.append(line)
                }
                if entry.senses.isEmpty, !translations.isEmpty {
                    let id = "b\(entryIndex + 1)a"
                    texts[id] = translations.joined(separator: ", ")
                    lines.append("\(id) (\(entry.posName)): " + translations.joined(separator: ", "))
                }
            }
            var seen = Set<String>()
            self.words = words.filter { seen.insert($0.lowercased()).inserted }
            self.senseLines = lines
            self.senseTexts = texts
        }

        var schema: [String: Any] {
            var properties: [String: Any] = ["explanation": ["type": "string"]]
            var required = ["explanation"]
            if !senseTexts.isEmpty {
                properties["sense_id"] = ["type": "string", "enum": senseTexts.keys.sorted()]
                required.append("sense_id")
            }
            if !words.isEmpty {
                properties["best_word"] = ["type": "string", "enum": words + [""]]
            }
            return ["type": "object", "properties": properties, "required": required]
        }

        /// Svaret, med det modellen hittat på själv bortrensat.
        func explanation(from json: [String: Any]) -> Result<WordExplanation, Error> {
            guard let text = (json["explanation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                return .failure(Failure.invalidResponse)
            }
            let senseID = json["sense_id"] as? String
            let best = (json["best_word"] as? String)?.trimmingCharacters(in: .whitespaces)
            let known = best.flatMap { word in words.first { $0.caseInsensitiveCompare(word) == .orderedSame } }
            return .success(WordExplanation(senseText: senseID.flatMap { senseTexts[$0] },
                                            bestWord: known,
                                            explanation: String(text.prefix(400))))
        }
    }
}
