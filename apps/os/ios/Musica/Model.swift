// Musica: the data the app knows (tracks, playlists), the manager.atlax.cloud
// API (apps/fleet/musica.ts) and the login cookies that open it.
import Foundation
import WebKit

struct Track: Codable, Identifiable, Hashable {
    var id: String
    var rel: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var year: String
    var cover: String
    var mb: Double

    init?(json o: [String: Any]) {
        guard let id = o["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        rel = (o["rel"] as? String) ?? "audio/\(id).m4a"
        let t = (o["titolo"] as? String) ?? ""
        title = t.isEmpty ? id : t
        artist = (o["artista"] as? String) ?? ""
        album = (o["album"] as? String) ?? ""
        duration = Track.num(o["durata"])
        if let s = o["anno"] as? String { year = s } else if let n = o["anno"] as? NSNumber { year = n.stringValue } else { year = "" }
        cover = (o["cover"] as? String) ?? ""
        mb = Track.num(o["mb"])
    }

    static func num(_ x: Any?) -> Double {
        if let n = x as? NSNumber { return n.doubleValue }
        if let s = x as? String { return Double(s) ?? 0 }
        return 0
    }

    var ext: String { (rel as NSString).pathExtension.lowercased() }
    /// AVPlayer decodes m4a/mp3/aac/mp4, not opus/webm/ogg.
    var supported: Bool { !["opus", "webm", "ogg", "oga", "mka"].contains(ext) }
    /// The file name on the phone: the id (YouTube ids are file-safe) + the extension.
    var fileName: String { safe(id) + "." + (ext.isEmpty ? "m4a" : ext) }
    var coverName: String { safe(id) + ".jpg" }
    var subtitle: String { [artist, album].filter { !$0.isEmpty }.joined(separator: " · ") }

    private func safe(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }
}

struct Playlist: Codable, Identifiable, Hashable {
    var name: String
    var ids: [String]
    var id: String { name }
}

/// A YouTube result not yet in the library (`trovati`).
struct Candidate: Identifiable, Hashable {
    let id: String
    let title: String
    let channel: String
    let duration: Double
    let thumb: String
}

enum MusicError: Error {
    case auth, pcOff, http(Int), bad
}

func mmss(_ s: Double) -> String {
    guard s.isFinite, s > 0 else { return "0:00" }
    let t = Int(s.rounded())
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}

/// The music API on manager.atlax.cloud. Auth is the Atlax ID session cookie
/// of that host, taken from the login web view (Auth) and sent by hand: the
/// sessions here keep no cookie store of their own.
enum MusicAPI {
    static let host = "manager.atlax.cloud"
    static let base = URL(string: "https://manager.atlax.cloud")!

    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    /// Downloads: long timeouts, a big file over a slow link must not die at 15 s.
    static let files: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 30 * 60
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        return URLSession(configuration: c)
    }()

    static func request(_ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 15) -> URLRequest {
        var r = URLRequest(url: URL(string: path, relativeTo: base)!.absoluteURL)
        r.timeoutInterval = timeout
        r.httpShouldHandleCookies = false
        r.setValue("application/json", forHTTPHeaderField: "accept")
        if let body = body {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "content-type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        Auth.apply(&r)
        return r
    }

    static func json(_ r: URLRequest) async throws -> [String: Any] {
        let (d, resp) = try await session.data(for: r)
        Auth.absorb(resp)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw MusicError.auth }
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { throw MusicError.http(code) }
        if (o["error"] as? String) == "auth" { throw MusicError.auth }
        if code == 503 { throw MusicError.pcOff }
        if code >= 400 { throw MusicError.http(code) }
        return o
    }

    /// `/api/musica/file?rel=...` (Range-aware: AVPlayer streams from it).
    static func fileURL(_ rel: String) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        let q = rel.addingPercentEncoding(withAllowedCharacters: allowed) ?? rel
        return URL(string: "/api/musica/file?rel=\(q)", relativeTo: base)!.absoluteURL
    }

    static func get(_ url: URL, timeout: TimeInterval) -> URLRequest {
        var r = URLRequest(url: url)
        r.timeoutInterval = timeout
        r.httpShouldHandleCookies = false
        Auth.apply(&r)
        return r
    }
}

/// The Atlax ID session of manager.atlax.cloud, kept on the phone: one login in
/// the web view (LoginSheet), then every request and every stream carries it.
/// Stored in UserDefaults too, with session cookies given a far expiry, so it
/// survives the app being killed (the server decides when it ends).
enum Auth {
    private static let key = "musica.cookies"
    private static let lock = NSLock()
    private static var jar: [HTTPCookie] = load()

    static var cookies: [HTTPCookie] {
        lock.lock(); defer { lock.unlock() }
        return jar
    }
    static var signedIn: Bool { !cookies.isEmpty }

    static func apply(_ r: inout URLRequest) {
        for (k, v) in HTTPCookie.requestHeaderFields(with: cookies) { r.setValue(v, forHTTPHeaderField: k) }
    }

    static func mine(_ c: HTTPCookie) -> Bool {
        let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
        return MusicAPI.host == d || MusicAPI.host.hasSuffix("." + d)
    }

    /// A rolling session: a Set-Cookie on any answer replaces the one we hold.
    static func absorb(_ resp: URLResponse) {
        guard let h = resp as? HTTPURLResponse, let url = h.url,
              let fields = h.allHeaderFields as? [String: String], fields.keys.contains(where: { $0.lowercased() == "set-cookie" }) else { return }
        let fresh = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).filter(mine)
        guard !fresh.isEmpty else { return }
        var all = cookies.filter { c in !fresh.contains { $0.name == c.name && $0.path == c.path } }
        all += fresh.filter { ($0.expiresDate ?? .distantFuture) > Date() && !$0.value.isEmpty }
        save(all)
    }

    static func save(_ cs: [HTTPCookie]) {
        let keep = cs.filter(mine)
        lock.lock(); jar = keep; lock.unlock()
        let list: [[String: Any]] = keep.compactMap { c in
            guard let p = c.properties else { return nil }
            var o: [String: Any] = [:]
            for (k, v) in p {
                if v is String || v is Date || v is NSNumber { o[k.rawValue] = v } else { o[k.rawValue] = "\(v)" }
            }
            o.removeValue(forKey: HTTPCookiePropertyKey.discard.rawValue)
            if c.expiresDate == nil { o[HTTPCookiePropertyKey.expires.rawValue] = Date().addingTimeInterval(400 * 86400) }
            return o
        }
        UserDefaults.standard.set(list, forKey: key)
    }

    private static func load() -> [HTTPCookie] {
        guard let list = UserDefaults.standard.array(forKey: key) as? [[String: Any]] else { return [] }
        return list.compactMap { o in
            var p: [HTTPCookiePropertyKey: Any] = [:]
            for (k, v) in o { p[HTTPCookiePropertyKey(k)] = v }
            return HTTPCookie(properties: p)
        }
    }

    /// After the web login: the cookies the web view got for manager.atlax.cloud.
    @MainActor static func fromWeb() async {
        let all: [HTTPCookie] = await withCheckedContinuation { c in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { c.resume(returning: $0) }
        }
        let got = all.filter(mine)
        if !got.isEmpty { save(got) }
    }

    /// Before the web view opens: it starts already signed in if we are.
    @MainActor static func toWeb() {
        for c in cookies { WKWebsiteDataStore.default().httpCookieStore.setCookie(c) }
    }

    @MainActor static func signOut() {
        lock.lock(); jar = []; lock.unlock()
        UserDefaults.standard.removeObject(forKey: key)
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { recs in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: recs.filter { $0.displayName.contains("atlax") }) {}
        }
    }
}
