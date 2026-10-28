// The Atlax agent, as seen from the phone: the Manager's OpenAI-compatible
// endpoint (https://ai.atlax.cloud/os/v1, the same one the shell's AI page
// uses; apps/manager/os-ai.ts in atlaxcloud/ai) with the Atlax ID machine key.
// Configured once by opening
//   atlax://agent?k=<machine key>[&model=<id>][&url=<base>]
// (QR or link from atlaxd / Fleet); stored in the App Group so Siri intents,
// widgets and extensions all reach it.
// /chat/completions always answers as SSE (chat.completion.chunk deltas, then
// [DONE], or {"error":{"message"}}): stream() reads it line by line.
import Foundation

enum Agent {
    static var base: String { Group.defaults.string(forKey: "ai.url") ?? "https://ai.atlax.cloud/os/v1" }
    static var token: String? { Group.defaults.string(forKey: "ai.token") }
    static var linked: Bool { !(token ?? "").isEmpty }
    static var model: String? {
        get { Group.defaults.string(forKey: "ai.model") }
        set { Group.defaults.set(newValue, forKey: "ai.model") }
    }
    static func disconnect() { Group.defaults.removeObject(forKey: "ai.token"); forget() }

    /// atlax://agent?k=..&model=..&url=..  -> true when it was an agent link.
    static func configure(_ u: URL) -> Bool {
        guard u.scheme == "atlax", u.host == "agent",
              let q = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        for i in q {
            switch i.name {
            case "k": Group.defaults.set(i.value, forKey: "ai.token")
            case "model": Group.defaults.set(i.value, forKey: "ai.model")
            case "url": Group.defaults.set(i.value, forKey: "ai.url")
            default: break
            }
        }
        return true
    }

    enum Failure: LocalizedError {
        case noKey, http(Int), empty, server(String)
        var errorDescription: String? {
            switch self {
            case .noKey: return "Atlax non è collegato: apri il link atlax://agent dal tuo PC Atlax."
            case .http(401), .http(403): return "La chiave di questa macchina non è autorizzata."
            case .http(503): return "Atlax ID non risponde, riprova tra poco."
            case .http(let c): return "Il Manager ha risposto con errore \(c)."
            case .empty: return "Il Manager non ha dato una risposta."
            case .server(let m): return m
            }
        }
    }

    // ---- conversations ---------------------------------------------------------

    struct Message: Codable, Hashable {
        var role: String // "user" | "assistant"
        var content: String
    }

    /// A saved chat: the app keeps the last 50, Siri talks in the newest one.
    struct Conversation: Codable, Identifiable, Hashable {
        var id = UUID()
        var title: String
        var updated: Date
        var model: String?
        var messages: [Message]
    }

    static var conversations: [Conversation] {
        get { Group.defaults.data(forKey: "ai.chats").flatMap { try? JSONDecoder().decode([Conversation].self, from: $0) } ?? [] }
        set {
            let keep = Array(newValue.sorted { $0.updated > $1.updated }.prefix(50))
            Group.defaults.set(try? JSONEncoder().encode(keep), forKey: "ai.chats")
        }
    }

    static func save(_ c: Conversation) {
        var all = conversations.filter { $0.id != c.id }
        if !c.messages.isEmpty { all.insert(c, at: 0) }
        conversations = all
    }

    static func delete(_ id: UUID) { conversations = conversations.filter { $0.id != id } }

    /// Siri's running conversation: the newest one if touched in the last hour.
    private static var siriChat: Conversation {
        if let c = conversations.first, c.updated > Date(timeIntervalSinceNow: -3600) { return c }
        return Conversation(title: "Siri", updated: Date(), model: model, messages: [])
    }
    /// "Nuova conversazione": Siri starts fresh next time.
    static func forget() {
        if var c = conversations.first {
            c.updated = Date(timeIntervalSinceNow: -7200)
            save(c)
        }
    }

    // ---- API -------------------------------------------------------------------

    /// A model the Manager offers (GET /models: id, name, "stato", "pronto").
    struct Model: Identifiable, Hashable {
        let id: String
        let name: String
        let state: String
        let ready: Bool
    }

    private static func request(_ path: String, timeout: Double) throws -> URLRequest {
        guard let token, !token.isEmpty else { throw Failure.noKey }
        var r = URLRequest(url: URL(string: base + path)!, timeoutInterval: timeout)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    /// The models list, also the cheapest "is the agent reachable with my key" check.
    static func models() async throws -> [Model] {
        let (data, resp) = try await URLSession.shared.data(for: request("/models", timeout: 15))
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw Failure.http(h.statusCode) }
        let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((j?["data"] as? [[String: Any]]) ?? []).compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            return Model(id: id, name: m["name"] as? String ?? id, state: m["stato"] as? String ?? "", ready: m["pronto"] as? Bool ?? false)
        }
    }

    /// Streams one answer; `onText` gets the full text so far, on the main actor.
    static func stream(_ messages: [Message], model: String?, system: String? = nil,
                       onText: @escaping @MainActor (String) -> Void) async throws -> String {
        var msgs: [[String: String]] = []
        if let system { msgs.append(["role": "system", "content": system]) }
        msgs += messages.suffix(40).map { ["role": $0.role, "content": $0.content] }
        var body: [String: Any] = ["messages": msgs, "stream": true]
        if let model { body["model"] = model }
        var r = try request("/chat/completions", timeout: 120)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, resp) = try await URLSession.shared.bytes(for: r)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw Failure.http(h.statusCode) }
        var text = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let d = payload.data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if let e = (j["error"] as? [String: Any])?["message"] as? String { throw Failure.server(e) }
            let delta = ((j["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])?["content"] as? String
            if let delta, !delta.isEmpty {
                text += delta
                let now = text
                await onText(now)
            }
        }
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw Failure.empty }
        return answer
    }

    /// One question, one full answer, in Siri's running conversation.
    static func ask(_ text: String, voice: Bool = true) async throws -> String {
        var c = siriChat
        c.messages.append(Message(role: "user", content: text))
        let system = voice ? "Rispondi in italiano, in modo breve e parlato: la risposta viene letta ad alta voce, anche in auto. Niente markdown, niente elenchi, niente link." : nil
        let answer = try await stream(c.messages, model: c.model ?? model, system: system) { _ in }
        c.messages.append(Message(role: "assistant", content: answer))
        c.updated = Date()
        if c.title == "Siri" || c.title.isEmpty { c.title = String(text.prefix(60)) }
        save(c)
        return answer
    }
}
