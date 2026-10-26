// Musica: the library on the phone. Everything the app shows comes from disk
// first (Application Support/Music, out of iCloud backups), then the network
// refreshes it when there is one: no network = the app opens as it was.
//
//   Music/library.json   tracks + playlists, as last seen on manager.atlax.cloud
//   Music/state.json     playlists kept offline + the download queue (resumes)
//   Music/player.json    the queue and the position (Player.swift)
//   Music/audio/<id>.<ext>, Music/cover/<id>.jpg
import Foundation
import Network
import SwiftUI
import UIKit

enum Disk {
    static let root: URL = {
        let fm = FileManager.default
        let u = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Music", isDirectory: true)
        for d in [u, u.appendingPathComponent("audio", isDirectory: true), u.appendingPathComponent("cover", isDirectory: true)] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        exclude(u)
        return u
    }()
    static var audio: URL { root.appendingPathComponent("audio", isDirectory: true) }
    static var cover: URL { root.appendingPathComponent("cover", isDirectory: true) }

    /// Music is not a backup: hundreds of MB that the PC holds anyway.
    static func exclude(_ u: URL) {
        var v = u
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? v.setResourceValues(rv)
    }

    static func read<T: Decodable>(_ name: String, as: T.Type) -> T? {
        guard let d = try? Data(contentsOf: root.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    static func write<T: Encodable>(_ name: String, _ v: T) {
        guard let d = try? JSONEncoder().encode(v) else { return }
        try? d.write(to: root.appendingPathComponent(name), options: .atomic)
    }

    static func size(_ u: URL) -> Int64 {
        Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}

private struct Library: Codable {
    var tracks: [Track]
    var playlists: [Playlist]
    var syncedAt: Date?
    var pcOn: Bool
}

private struct Saved: Codable {
    var keep: [String]
    var queue: [String]
}

@MainActor
final class MusicStore: ObservableObject {
    static let shared = MusicStore()

    @Published private(set) var tracks: [Track] = []
    @Published private(set) var playlists: [Playlist] = []
    /// Track id -> its file in Music/audio.
    @Published private(set) var files: [String: URL] = [:]
    @Published private(set) var bytes: Int64 = 0
    /// Playlists kept offline: every refresh with network downloads what they gained.
    @Published private(set) var keep: Set<String> = []
    @Published private(set) var online = true
    @Published private(set) var pcOn = false
    @Published private(set) var syncedAt: Date?
    @Published private(set) var loading = false
    @Published private(set) var needsLogin = false
    @Published private(set) var note: String?
    /// Download queue (ids), the one in flight, and the batch's progress.
    @Published private(set) var pending: [String] = []
    @Published private(set) var downloading: String?
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var adding: Set<String> = []

    private var byId: [String: Track] = [:]
    private var pumping = false
    private let monitor = NWPathMonitor()

    init() {
        if let lib = Disk.read("library.json", as: Library.self) {
            set(lib.tracks, lib.playlists)
            syncedAt = lib.syncedAt
            pcOn = lib.pcOn
        }
        if let s = Disk.read("state.json", as: Saved.self) {
            keep = Set(s.keep)
            pending = s.queue
        }
        scan()
        needsLogin = !Auth.signedIn
        monitor.pathUpdateHandler = { path in
            let up = path.status == .satisfied
            Task { @MainActor in MusicStore.shared.reach(up) }
        }
        monitor.start(queue: DispatchQueue(label: "musica.net"))
    }

    private func reach(_ up: Bool) {
        let was = online
        online = up
        if up && !was { Task { await refresh() } }
    }

    // MARK: lookups

    func track(_ id: String) -> Track? { byId[id] }
    func file(_ id: String) -> URL? { files[id] }
    func isDownloaded(_ id: String) -> Bool { files[id] != nil }
    func playlist(_ name: String) -> Playlist? { playlists.first { $0.name == name } }
    func tracks(of p: Playlist) -> [Track] { p.ids.compactMap { byId[$0] } }

    /// Playable now: on the phone, or streamable (network + the PC that holds the library on).
    func playable(_ t: Track) -> Bool {
        files[t.id] != nil || (t.supported && online && pcOn && Auth.signedIn)
    }

    var downloadedTracks: [Track] { tracks.filter { files[$0.id] != nil } }

    private func set(_ ts: [Track], _ ps: [Playlist]) {
        tracks = ts
        playlists = ps
        byId = Dictionary(ts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// What is in Music/audio (the truth about "downloaded") and how much it weighs.
    private func scan() {
        let fm = FileManager.default
        var f: [String: URL] = [:]
        var b: Int64 = 0
        let names = Dictionary(tracks.map { ($0.fileName, $0.id) }, uniquingKeysWith: { a, _ in a })
        for u in (try? fm.contentsOfDirectory(at: Disk.audio, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
            b += Disk.size(u)
            if let id = names[u.lastPathComponent] { f[id] = u }
            else { f[u.deletingPathExtension().lastPathComponent] = u }
        }
        for u in (try? fm.contentsOfDirectory(at: Disk.cover, includingPropertiesForKeys: [.fileSizeKey])) ?? [] { b += Disk.size(u) }
        files = f
        bytes = b
    }

    private func saveLibrary() {
        Disk.write("library.json", Library(tracks: tracks, playlists: playlists, syncedAt: syncedAt, pcOn: pcOn))
    }

    private func saveState() {
        Disk.write("state.json", Saved(keep: Array(keep), queue: pending))
    }

    // MARK: network

    func refresh() async {
        guard !loading, Auth.signedIn else { needsLogin = !Auth.signedIn; return }
        loading = true
        defer { loading = false }
        do {
            apply(try await MusicAPI.json(MusicAPI.request("/api/musica")))
            needsLogin = false
            note = nil
            syncKept()
            Task { await prefetchCovers() }
        } catch MusicError.auth {
            needsLogin = true
        } catch {
            note = online ? "Server non raggiungibile: uso la libreria salvata" : nil
        }
    }

    private func apply(_ o: [String: Any]) {
        guard let raw = o["brani"] as? [[String: Any]] else { return }
        var ts = raw.compactMap(Track.init(json:))
        // A track gone from the server but still on the phone stays playable here.
        let seen = Set(ts.map(\.id))
        ts += tracks.filter { !seen.contains($0.id) && files[$0.id] != nil }
        let ps: [Playlist] = (o["playlist"] as? [[String: Any]] ?? []).compactMap { p in
            guard let n = p["nome"] as? String else { return nil }
            return Playlist(name: n, ids: p["brani"] as? [String] ?? [])
        }
        set(ts, ps)
        pcOn = (o["acceso"] as? Bool) ?? false
        if let n = o["nota"] as? String, !n.isEmpty { note = n }
        syncedAt = Date()
        keep = keep.filter { k in ps.contains { $0.name == k } }
        saveLibrary()
        saveState()
        scan()
    }

    /// Search on YouTube through the PC; the library part is filtered locally by the view.
    func search(_ q: String) async throws -> (inLibrary: [Track], found: [Candidate]) {
        let o = try await MusicAPI.json(MusicAPI.request("/api/musica/cerca", body: ["q": q, "n": 15], timeout: 40))
        let lib = (o["risultati"] as? [[String: Any]] ?? []).compactMap(Track.init(json:))
        let found: [Candidate] = (o["trovati"] as? [[String: Any]] ?? []).compactMap { c in
            guard let id = c["id"] as? String else { return nil }
            return Candidate(id: id, title: (c["titolo"] as? String) ?? id, channel: (c["canale"] as? String) ?? "",
                             duration: Track.num(c["durata"]), thumb: (c["thumb"] as? String) ?? "")
        }
        return (lib, found)
    }

    /// Adds a YouTube video to the library (the PC downloads it; slow).
    func add(_ c: Candidate) async -> Bool {
        adding.insert(c.id)
        defer { adding.remove(c.id) }
        do {
            apply(try await MusicAPI.json(MusicAPI.request("/api/musica/aggiungi", body: ["url": "https://www.youtube.com/watch?v=\(c.id)"], timeout: 300)))
            return true
        } catch MusicError.auth {
            needsLogin = true
        } catch {
            note = "Aggiunta non riuscita: il PC è acceso?"
        }
        return false
    }

    /// Creates or rewrites a playlist (optimistic: the change shows at once).
    func savePlaylist(_ name: String, _ ids: [String]) {
        var ps = playlists
        if let i = ps.firstIndex(where: { $0.name == name }) { ps[i].ids = ids } else { ps.append(Playlist(name: name, ids: ids)) }
        set(tracks, ps)
        saveLibrary()
        if keep.contains(name) { download(ids) }
        Task { await post(["nome": name, "brani": ids]) }
    }

    func deletePlaylist(_ name: String) {
        set(tracks, playlists.filter { $0.name != name })
        keep.remove(name)
        saveLibrary()
        saveState()
        Task { await post(["nome": name, "via": true]) }
    }

    func addTo(_ name: String, _ id: String) {
        guard let p = playlist(name), !p.ids.contains(id) else { return }
        savePlaylist(name, p.ids + [id])
    }

    func removeFrom(_ name: String, _ id: String) {
        guard let p = playlist(name) else { return }
        savePlaylist(name, p.ids.filter { $0 != id })
    }

    private func post(_ body: [String: Any]) async {
        do {
            let o = try await MusicAPI.json(MusicAPI.request("/api/musica/playlist", body: body))
            if o["brani"] != nil { apply(o) }
        } catch MusicError.auth {
            needsLogin = true
        } catch {
            note = "Playlist salvata sul telefono: sul PC arriverà quando è raggiungibile"
        }
    }

    // MARK: offline

    func keepOffline(_ name: String, _ on: Bool) {
        if on { keep.insert(name) } else { keep.remove(name) }
        saveState()
        if on, let p = playlist(name) { download(p.ids) }
    }

    private func syncKept() {
        for n in keep { if let p = playlist(n) { download(p.ids) } }
        pump()
    }

    func download(_ ids: [String]) {
        var added = 0
        for id in ids where files[id] == nil && !pending.contains(id) && downloading != id && (byId[id]?.supported ?? false) {
            pending.append(id)
            added += 1
        }
        guard added > 0 else { return }
        total += added
        saveState()
        pump()
    }

    func cancelDownloads() {
        pending = []
        total = done
        saveState()
    }

    /// One file at a time, in order; the queue is on disk, so a cut (no
    /// network, app killed) resumes from where it stopped at the next refresh.
    func pump() {
        guard !pumping, !pending.isEmpty, online, Auth.signedIn else { return }
        pumping = true
        Task { await runQueue() }
    }

    private func runQueue() async {
        var bg: UIBackgroundTaskIdentifier = .invalid
        bg = UIApplication.shared.beginBackgroundTask(withName: "musica.download") {
            UIApplication.shared.endBackgroundTask(bg)
            bg = .invalid
        }
        defer {
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
            pumping = false
            downloading = nil
            if pending.isEmpty { done = 0; total = 0 }
            saveState()
        }
        if total < pending.count + done { total = pending.count + done }
        while let id = pending.first, online {
            guard let t = byId[id], files[id] == nil else { pending.removeFirst(); continue }
            downloading = id
            do {
                try await fetch(t)
                pending.removeFirst()
                done += 1
                saveState()
            } catch MusicError.auth {
                needsLogin = true
                return
            } catch MusicError.http(let c) where c == 404 || c == 400 || c == 415 {
                pending.removeFirst()
                done += 1
            } catch MusicError.pcOff {
                pcOn = false
                note = "Il PC con la musica è spento: i download riprendono quando torna"
                return
            } catch {
                note = "Download interrotto: riprende con la rete"
                return
            }
        }
    }

    private func fetch(_ t: Track) async throws {
        let (tmp, resp) = try await MusicAPI.files.download(for: MusicAPI.get(MusicAPI.fileURL(t.rel), timeout: 60))
        Auth.absorb(resp)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let type = ((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "content-type") ?? "").lowercased()
        let fm = FileManager.default
        guard code == 200 || code == 206, !type.contains("json"), !type.contains("html") else {
            try? fm.removeItem(at: tmp)
            if code == 401 || code == 403 { throw MusicError.auth }
            if code == 503 { throw MusicError.pcOff }
            throw MusicError.http(code == 200 ? 415 : code)
        }
        let dst = Disk.audio.appendingPathComponent(t.fileName)
        try? fm.removeItem(at: dst)
        try fm.moveItem(at: tmp, to: dst)
        Disk.exclude(dst)
        files[t.id] = dst
        bytes += Disk.size(dst)
        _ = await Covers.shared.load(t)
    }

    func delete(_ id: String) {
        guard let u = files[id] else { return }
        bytes -= Disk.size(u)
        try? FileManager.default.removeItem(at: u)
        files[id] = nil
        // Deleted by hand: a playlist kept offline would fetch it right back.
        for p in playlists where keep.contains(p.name) && p.ids.contains(id) { keep.remove(p.name) }
        saveState()
    }

    func deleteAll() {
        cancelDownloads()
        for u in files.values { try? FileManager.default.removeItem(at: u) }
        files = [:]
        keep = []
        saveState()
        scan()
    }

    /// Covers of the whole library on disk, so the lists look the same offline.
    private func prefetchCovers() async {
        for t in tracks where !t.cover.isEmpty && !Covers.shared.onDisk(t) {
            guard online else { return }
            _ = await Covers.shared.load(t)
        }
        scan()
    }

    func signedIn() {
        needsLogin = false
        Task { await refresh() }
    }

    func signOut() {
        Auth.signOut()
        needsLogin = true
        cancelDownloads()
    }
}

/// Covers: memory, then Music/cover, then the network (and then disk).
@MainActor
final class Covers {
    static let shared = Covers()
    private let cache = NSCache<NSString, UIImage>()
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    func url(_ t: Track) -> URL { Disk.cover.appendingPathComponent(t.coverName) }
    func onDisk(_ t: Track) -> Bool { FileManager.default.fileExists(atPath: url(t).path) }

    func cached(_ t: Track) -> UIImage? {
        if let i = cache.object(forKey: t.id as NSString) { return i }
        guard let i = UIImage(contentsOfFile: url(t).path) else { return nil }
        cache.setObject(i, forKey: t.id as NSString)
        return i
    }

    func load(_ t: Track) async -> UIImage? {
        if let i = cached(t) { return i }
        guard !t.cover.isEmpty, Auth.signedIn else { return nil }
        if let job = inflight[t.id] { return await job.value }
        let dst = url(t)
        let req = MusicAPI.get(MusicAPI.fileURL(t.cover), timeout: 20)
        let job = Task<UIImage?, Never> {
            guard let r = try? await MusicAPI.session.data(for: req),
                  (r.1 as? HTTPURLResponse)?.statusCode == 200, let img = UIImage(data: r.0) else { return nil }
            let d = r.0
            try? d.write(to: dst, options: .atomic)
            Disk.exclude(dst)
            return img
        }
        inflight[t.id] = job
        let img = await job.value
        inflight[t.id] = nil
        if let img = img { cache.setObject(img, forKey: t.id as NSString) }
        return img
    }
}
