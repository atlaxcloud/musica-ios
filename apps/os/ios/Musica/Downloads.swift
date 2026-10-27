// Musica: downloads that keep going with the app closed or the phone locked.
// A background URLSession: iOS moves the bytes and wakes the app when a batch is
// done. One task per track (its description is the track id); the file lands in
// Music/incoming/<id> and the store moves it into Music/audio on its own actor.
import Foundation

final class BackgroundFetch: NSObject, URLSessionDownloadDelegate {
    static let shared = BackgroundFetch()
    static let identifier = "cloud.atlax.musica.downloads"

    /// Given by iOS when it wakes the app for this session: called once its events are handled.
    var finishEvents: (() -> Void)?

    /// Outside Music/audio, so a half-finished batch never looks like a song.
    static let incoming: URL = {
        let u = Disk.root.appendingPathComponent("incoming", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        // The PC bridge serves a few files at a time well; more only queue up on the server.
        c.httpMaximumConnectionsPerHost = 3
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        c.allowsCellularAccess = true
        c.timeoutIntervalForResource = 6 * 3600
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    func start(_ t: Track, high: Bool) {
        let task = session.downloadTask(with: MusicAPI.get(MusicAPI.fileURL(t.rel), timeout: 120))
        task.taskDescription = t.id
        task.priority = high ? URLSessionTask.highPriority : URLSessionTask.defaultPriority
        task.resume()
    }

    /// The track you just tapped: ahead of the others still waiting.
    func boost(_ id: String) {
        session.getAllTasks { ts in
            for t in ts where t.taskDescription == id { t.priority = URLSessionTask.highPriority }
        }
    }

    func cancelAll() {
        session.getAllTasks { ts in ts.forEach { $0.cancel() } }
    }

    /// The ids already on their way: after a relaunch the session still holds them.
    func running(_ done: @escaping (Set<String>) -> Void) {
        session.getAllTasks { ts in
            let ids = Set(ts.filter { $0.state == .running || $0.state == .suspended }.compactMap(\.taskDescription))
            DispatchQueue.main.async { done(ids) }
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let http = downloadTask.response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        let type = (http?.value(forHTTPHeaderField: "content-type") ?? "").lowercased()
        // The temporary file is deleted when this returns: it moves now, synchronously.
        let staged = Self.incoming.appendingPathComponent(id)
        let fm = FileManager.default
        try? fm.removeItem(at: staged)
        let ok = (try? fm.moveItem(at: location, to: staged)) != nil
        Task { @MainActor in MusicStore.shared.fetched(id, staged: ok ? staged : nil, code: code, type: type) }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error, let id = task.taskDescription else { return }
        let cancelled = (error as? URLError)?.code == .cancelled
        Task { @MainActor in MusicStore.shared.fetchFailed(id, cancelled: cancelled) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.finishEvents?()
            self.finishEvents = nil
        }
    }
}
