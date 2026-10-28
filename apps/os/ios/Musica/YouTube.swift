// Musica: search YouTube Music straight from the phone, through its own web API
// (~0.5 s, no PC in the way). The PC only fetches the song you pick.
import Foundation

enum YouTubeSearch {
    private static let endpoint = URL(string: "https://music.youtube.com/youtubei/v1/search?prettyPrint=false")!
    /// YouTube Music's "Brani" filter; without it, the mixed results (videos too).
    private static let songsOnly = "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"

    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 8
        c.httpCookieStorage = nil
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    /// Songs first; a query that finds no song (a live, a remix only on YouTube) gets everything.
    static func songs(_ q: String) async throws -> [Candidate] {
        let found = try await run(q, params: songsOnly)
        return found.isEmpty ? try await run(q, params: nil) : found
    }

    private static func run(_ q: String, params: String?) async throws -> [Candidate] {
        var r = URLRequest(url: endpoint, timeoutInterval: 8)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        r.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        var body: [String: Any] = [
            "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": "1.20241023.01.00", "hl": "it", "gl": "IT"]],
            "query": q,
        ]
        if let p = params { body["params"] = p }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, resp) = try await session.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let o = try? JSONSerialization.jsonObject(with: d) else { throw MusicError.bad }
        var items: [[String: Any]] = []
        collect(o, into: &items)
        var seen = Set<String>()
        return items.compactMap(candidate).filter { seen.insert($0.id).inserted }
    }

    /// Every result row, in page order (arrays keep it; the rows live in arrays).
    private static func collect(_ o: Any, into out: inout [[String: Any]]) {
        if let d = o as? [String: Any] {
            if let m = d["musicResponsiveListItemRenderer"] as? [String: Any] { out.append(m); return }
            for v in d.values { collect(v, into: &out) }
        } else if let a = o as? [Any] {
            for v in a { collect(v, into: &out) }
        }
    }

    /// Row columns: title, then "[Brano/Video •] Artist • Album/views • 3:50".
    private static func candidate(_ m: [String: Any]) -> Candidate? {
        guard let id = (m["playlistItemData"] as? [String: Any])?["videoId"] as? String else { return nil }
        let cols: [String] = (m["flexColumns"] as? [[String: Any]] ?? []).map { c in
            let text = (c["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"] as? [String: Any]
            return ((text?["runs"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
        }
        guard let title = cols.first, !title.isEmpty else { return nil }
        var parts = cols.count > 1 ? cols[1].components(separatedBy: " • ") : []
        if let k = parts.first, ["Brano", "Video", "Song", "Episodio", "Episode"].contains(k) { parts.removeFirst() }
        if let k = cols.count > 1 ? cols[1].components(separatedBy: " • ").first : nil, k == "Episodio" || k == "Episode" { return nil }
        let duration = parts.last.map(seconds) ?? 0
        let thumbs = (((m["thumbnail"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any])?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let thumb = (thumbs?.last?["url"] as? String) ?? "https://i.ytimg.com/vi/\(id)/mqdefault.jpg"
        return Candidate(id: id, title: title, channel: parts.first ?? "", duration: duration, thumb: thumb)
    }

    /// "3:50" / "1:02:03" -> seconds; anything else -> 0.
    private static func seconds(_ s: String) -> Double {
        let p = s.split(separator: ":").map { Int($0) }
        guard p.count >= 2, p.count <= 3, !p.contains(nil) else { return 0 }
        return Double(p.reduce(0) { $0 * 60 + ($1 ?? 0) })
    }
}
