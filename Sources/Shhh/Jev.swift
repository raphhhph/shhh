import Foundation

/// Jev (TypeSafe AI, through OpenRouter): a fast, cheap model that only picks from typed options.
/// Joe asks it what a spoken request is before Claude starts, so the model choice doesn't rest on
/// the regex alone. Prototype: off without an OpenRouter key, and any error or slow answer
/// (over `timeout`) returns nil so the caller keeps its current path.
enum Jev {
    enum Intent: String, CaseIterable {
        case question     // a lookup or a chat: Haiku
        case schoolwork   // do/write/solve a piece of work: Opus
        case design       // slides, posters, "make it look good": Opus
        case command      // alarm, timer, note, calendar, music, open an app
    }

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "useJev") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "useJev") }
    }

    static var model: String {
        UserDefaults.standard.string(forKey: "jevModel").flatMap { $0.isEmpty ? nil : $0 } ?? "typesafe/jev-1.13"
    }

    static let timeout: TimeInterval = 0.35

    /// nil when Jev is off, has no key, fails or is too slow.
    static func needsStrongModel(_ request: String) async -> Bool? {
        guard await Assistant.strongModelForWork else { return false }
        guard let intent = await intent(of: request) else { return nil }
        return intent == .schoolwork || intent == .design
    }

    static func intent(of request: String) async -> Intent? {
        guard enabled, let key = AIAccount.openRouterKey,
              let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else { return nil }
        let started = Date()
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["intent": ["type": "string", "enum": Intent.allCases.map(\.rawValue)]],
            "required": ["intent"], "additionalProperties": false,
        ]
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": """
                    Classify what an IB student said to their Mac assistant. schoolwork = asks the assistant \
                    to do, write, answer or solve a piece of work. design = make slides, a poster or a deck, \
                    or make something look good. command = alarm, timer, reminder, note, calendar, music or \
                    opening an app. question = anything else, including asking about homework or deadlines.
                    """],
                ["role": "user", "content": request],
            ],
            "response_format": ["type": "json_schema",
                                "json_schema": ["name": "intent", "strict": true, "schema": schema]],
            "max_tokens": 20,
        ]
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String,
              let answer = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: String],
              let intent = answer["intent"].flatMap(Intent.init(rawValue:)) else { return nil }
        NSLog("Jev: %@ in %.0f ms", intent.rawValue, Date().timeIntervalSince(started) * 1000)
        return intent
    }
}
