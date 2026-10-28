// Musica: the player. One AVQueuePlayer holding the current track and the next
// one already loaded (gapless, and it moves on by itself with the screen locked), a queue of our own (shuffle, repeat),
// files from the phone first and the PC's stream only when there is none.
// The lock screen and the headphones drive it (MPRemoteCommandCenter), Now
// Playing shows title, artist, cover and time; calls and alarms pause it and
// give it back, pulling the headphones out pauses it.
import AVFoundation
import Combine
import MediaPlayer
import SwiftUI
import UIKit

private struct SavedQueue: Codable {
    var original: [String]
    var queue: [String]
    var index: Int
    var time: Double
    var shuffle: Bool
    var repeatMode: String
}

/// The playback position, alone: only the progress bars observe it.
@MainActor
final class PlayerClock: ObservableObject {
    @Published var time: Double = 0
}

@MainActor
final class MusicPlayer: ObservableObject {
    static let shared = MusicPlayer()

    enum Repeat: String { case off, all, one }

    /// The order the music was chosen in, and the order it plays in (shuffled or not).
    @Published private(set) var original: [String] = []
    @Published private(set) var queue: [String] = []
    @Published private(set) var index = 0
    @Published private(set) var playing = false
    /// Not published: it ticks twice a second and would redraw every list holding the player.
    /// The few views that show it watch `clock`.
    private(set) var time: Double = 0 { didSet { if clock.time != time { clock.time = time } } }
    let clock = PlayerClock()
    @Published private(set) var duration: Double = 0
    @Published private(set) var shuffle = false
    @Published var repeatMode: Repeat = .off { didSet { save(); prepareNext() } }
    @Published var full = false
    @Published private(set) var message: String?

    private let player = AVQueuePlayer()
    /// The track after the current one, already in the queue player, and where it sits in `queue`.
    private var nextItem: AVPlayerItem?
    private var nextIndex: Int?
    private var bag = Set<AnyCancellable>()
    private var itemBag = Set<AnyCancellable>()
    private var timeObserver: Any?
    private var loadedId: String?
    private var failures = 0
    private var resumeAfterInterruption = false
    private var lastSave = Date.distantPast

    private var store: MusicStore { MusicStore.shared }

    var current: Track? { queue.indices.contains(index) ? store.track(queue[index]) : nil }
    var upNext: [String] { index + 1 < queue.count ? Array(queue[(index + 1)...]) : [] }

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { t in
            Task { @MainActor in MusicPlayer.shared.tick(t.seconds) }
        }
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { s in Task { @MainActor in MusicPlayer.shared.status(s) } }
            .store(in: &bag)
        player.publisher(for: \.currentItem)
            .receive(on: DispatchQueue.main)
            .sink { item in Task { @MainActor in MusicPlayer.shared.moved(to: item) } }
            .store(in: &bag)
        let nc = NotificationCenter.default
        nc.publisher(for: .AVPlayerItemFailedToPlayToEndTime)
            .receive(on: DispatchQueue.main)
            .sink { n in
                let item = n.object as? AVPlayerItem
                Task { @MainActor in MusicPlayer.shared.cut(item) }
            }
            .store(in: &bag)
        nc.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .receive(on: DispatchQueue.main)
            .sink { n in
                let item = n.object as? AVPlayerItem
                Task { @MainActor in MusicPlayer.shared.ended(item) }
            }
            .store(in: &bag)
        nc.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { n in
                let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                let opts = AVAudioSession.InterruptionOptions(rawValue: (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0)
                Task { @MainActor in MusicPlayer.shared.interrupted(type, shouldResume: opts.contains(.shouldResume)) }
            }
            .store(in: &bag)
        nc.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { n in
                let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                // Headphones out (cable or Bluetooth gone): pause, like every player does.
                if reason == .oldDeviceUnavailable { Task { @MainActor in MusicPlayer.shared.pause() } }
            }
            .store(in: &bag)
        nc.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { _ in Task { @MainActor in MusicPlayer.shared.save(force: true) } }
            .store(in: &bag)
        remote()
        restore()
    }

    // MARK: commands

    /// Plays `ids` from `start`; `shuffled` shuffles the whole list.
    func play(_ ids: [String], from start: Int = 0, shuffled: Bool = false) {
        guard !ids.isEmpty else { return }
        original = ids
        shuffle = shuffled
        if shuffled {
            queue = ids.shuffled()
            index = 0
        } else {
            queue = ids
            index = min(max(start, 0), ids.count - 1)
        }
        failures = 0
        load(autoplay: true, step: 1)
    }

    func toggle() { playing ? pause() : resume() }

    func resume() {
        guard current != nil else { return }
        activate()
        if loadedId != current?.id { load(autoplay: true, step: 1); return }
        player.play()
        playing = true
        nowPlaying()
    }

    func pause() {
        player.pause()
        playing = false
        nowPlaying()
        save(force: true)
    }

    func next() { advance(auto: false) }

    func previous() {
        if time > 3 || index == 0 && repeatMode != .all {
            seek(0)
            return
        }
        index = index > 0 ? index - 1 : queue.count - 1
        load(autoplay: playing, step: -1)
    }

    func seek(_ s: Double) {
        let to = max(0, min(s, duration > 0 ? duration - 0.5 : s))
        time = to
        player.seek(to: CMTime(seconds: to, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor in MusicPlayer.shared.nowPlaying() }
        }
    }

    func jump(_ i: Int) {
        guard queue.indices.contains(i) else { return }
        index = i
        load(autoplay: true, step: 1)
    }

    func setShuffle(_ on: Bool) {
        guard on != shuffle else { return }
        shuffle = on
        guard let cur = queue.indices.contains(index) ? queue[index] : nil else { return }
        if on {
            var rest = original
            if let i = rest.firstIndex(of: cur) { rest.remove(at: i) }
            queue = [cur] + rest.shuffled()
            index = 0
        } else {
            queue = original
            index = original.firstIndex(of: cur) ?? 0
        }
        save(force: true)
        prepareNext()
    }

    func cycleRepeat() {
        repeatMode = repeatMode == .off ? .all : repeatMode == .all ? .one : .off
    }

    /// "Riproduci dopo": right after the current one.
    func playNext(_ id: String) {
        guard current != nil else { play([id]); return }
        queue.insert(id, at: index + 1)
        if let i = original.firstIndex(of: queue[index]) { original.insert(id, at: i + 1) } else { original.append(id) }
        save(force: true)
        prepareNext()
    }

    func enqueue(_ id: String) {
        guard current != nil else { play([id]); return }
        queue.append(id)
        original.append(id)
        save(force: true)
        prepareNext()
    }

    /// Removes from the "up next" part (offsets relative to `upNext`).
    func removeUpNext(at offsets: IndexSet) {
        let gone = offsets.map { queue[index + 1 + $0] }
        for o in offsets.sorted(by: >) { queue.remove(at: index + 1 + o) }
        for id in gone { if let i = original.lastIndex(of: id) { original.remove(at: i) } }
        save(force: true)
        prepareNext()
    }

    func moveUpNext(from: IndexSet, to: Int) {
        var up = upNext
        up.move(fromOffsets: from, toOffset: to)
        queue = Array(queue[...index]) + up
        save(force: true)
        prepareNext()
    }

    func stop() {
        player.pause()
        player.removeAllItems()
        nextItem = nil
        nextIndex = nil
        loadedId = nil
        queue = []
        original = []
        index = 0
        playing = false
        time = 0
        duration = 0
        full = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        save(force: true)
    }

    // MARK: engine

    private func activate() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [])
        try? s.setActive(true)
    }

    private func advance(auto: Bool) {
        guard !queue.isEmpty else { return }
        if auto && repeatMode == .one {
            seek(0)
            player.play()
            return
        }
        if index + 1 < queue.count {
            index += 1
        } else if repeatMode == .all || !auto {
            index = 0
        } else {
            // End of the queue: stop on the last one, from the start.
            player.pause()
            playing = false
            seek(0)
            nowPlaying()
            save(force: true)
            return
        }
        load(autoplay: auto || playing, step: 1)
    }

    /// Loads queue[index] (skipping what cannot play now, in `step` direction) and plays it.
    private func load(autoplay: Bool, step: Int, at start: Double = 0) {
        var tries = 0
        while tries < queue.count {
            if let t = current, let item = makeItem(t) {
                itemBag = []
                item.publisher(for: \.status)
                    .receive(on: DispatchQueue.main)
                    .sink { s in
                        guard s == .failed else { return }
                        Task { @MainActor in MusicPlayer.shared.failed(t.id) }
                    }
                    .store(in: &itemBag)
                player.removeAllItems()
                nextItem = nil
                nextIndex = nil
                player.insert(item, after: nil)
                loadedId = t.id
                time = start
                duration = t.duration
                message = nil
                if start > 0 { player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) }
                if autoplay {
                    activate()
                    player.play()
                    playing = true
                }
                nowPlaying()
                save(force: true)
                prepareNext()
                return
            }
            tries += 1
            index = (index + step + queue.count) % queue.count
        }
        player.pause()
        playing = false
        message = store.online ? "Niente da suonare: brani non scaricati e PC spento" : "Offline: nessuno di questi brani è scaricato"
    }

    private func makeItem(_ t: Track) -> AVPlayerItem? {
        if let f = store.file(t.id) { return AVPlayerItem(url: f) }
        guard store.playable(t) else { return nil }
        store.prioritize(t.id)  // streams now, and is the next file saved on the phone
        let asset = AVURLAsset(url: MusicAPI.fileURL(t.rel), options: [AVURLAssetHTTPCookiesKey: Auth.cookies])
        return AVPlayerItem(asset: asset)
    }

    private func failed(_ id: String) {
        guard id == loadedId else { return }
        failures += 1
        message = "Non riesco a suonare \(store.track(id)?.title ?? "il brano")"
        if failures < max(queue.count, 1) { advance(auto: true) } else { pause() }
    }

    /// The track after the current one, loaded behind it (skipping what cannot play now).
    /// Repeat-one keeps the item: it rewinds at the end instead.
    private func prepareNext() {
        if let n = nextItem { player.remove(n) }
        nextItem = nil
        nextIndex = nil
        player.actionAtItemEnd = repeatMode == .one ? .none : .advance
        guard repeatMode != .one, !queue.isEmpty, player.currentItem != nil else { return }
        var i = index
        for _ in 0..<queue.count {
            i += 1
            if i >= queue.count {
                guard repeatMode == .all else { return }
                i = 0
            }
            if i == index { return }
            if let t = store.track(queue[i]), let item = laterItem(t) {
                player.insert(item, after: player.currentItem)
                nextItem = item
                nextIndex = i
                return
            }
        }
    }

    /// Like makeItem, but a stream for later does not jump the download queue.
    private func laterItem(_ t: Track) -> AVPlayerItem? {
        if let f = store.file(t.id) { return AVPlayerItem(url: f) }
        guard store.playable(t) else { return nil }
        return AVPlayerItem(asset: AVURLAsset(url: MusicAPI.fileURL(t.rel), options: [AVURLAssetHTTPCookiesKey: Auth.cookies]))
    }

    /// iOS moved on to the preloaded track: the queue follows, and the one after gets loaded.
    private func moved(to item: AVPlayerItem?) {
        guard let item = item, item === nextItem, let i = nextIndex, queue.indices.contains(i) else { return }
        nextItem = nil
        nextIndex = nil
        index = i
        let id = queue[i]
        loadedId = id
        time = 0
        duration = current?.duration ?? 0
        failures = 0
        message = nil
        itemBag = []
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { s in
                guard s == .failed else { return }
                Task { @MainActor in MusicPlayer.shared.failed(id) }
            }
            .store(in: &itemBag)
        if store.file(id) == nil { store.prioritize(id) }
        nowPlaying()
        save(force: true)
        prepareNext()
    }

    private func ended(_ item: AVPlayerItem?) {
        failures = 0
        if repeatMode == .one {
            seek(0)
            player.play()
            return
        }
        // With the next one preloaded the queue player has already moved on (see `moved`).
        if nextItem != nil || (player.currentItem != nil && item !== player.currentItem) { return }
        if player.currentItem == nil && index + 1 >= queue.count && repeatMode != .all {
            // End of the queue: stop on the last one, from the start, ready to play again.
            playing = false
            load(autoplay: false, step: 1)
            return
        }
        // Nothing loaded behind it: go the slow way.
        advance(auto: true)
    }

    private func cut(_ item: AVPlayerItem?) {
        guard item === player.currentItem, let id = loadedId else { return }
        failed(id)
    }

    private func tick(_ s: Double) {
        guard s.isFinite else { return }
        time = s
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - duration) > 0.5 {
            duration = d
            nowPlaying()
        }
        if playing { save() }
    }

    private func status(_ s: AVPlayer.TimeControlStatus) {
        let on = s != .paused
        if on != playing {
            playing = on
            nowPlaying()
        }
    }

    private func interrupted(_ type: AVAudioSession.InterruptionType?, shouldResume: Bool) {
        switch type {
        case .began?:
            resumeAfterInterruption = playing
            playing = false
            nowPlaying()
        case .ended?:
            if shouldResume && resumeAfterInterruption { self.resume() }
            resumeAfterInterruption = false
        default:
            break
        }
    }

    // MARK: lock screen

    private func remote() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { _ in Task { @MainActor in MusicPlayer.shared.resume() }; return .success }
        c.pauseCommand.addTarget { _ in Task { @MainActor in MusicPlayer.shared.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { _ in Task { @MainActor in MusicPlayer.shared.toggle() }; return .success }
        c.nextTrackCommand.addTarget { _ in Task { @MainActor in MusicPlayer.shared.next() }; return .success }
        c.previousTrackCommand.addTarget { _ in Task { @MainActor in MusicPlayer.shared.previous() }; return .success }
        c.changePlaybackPositionCommand.addTarget { e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let to = e.positionTime
            Task { @MainActor in MusicPlayer.shared.seek(to) }
            return .success
        }
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.isEnabled = false
    }

    func nowPlaying() {
        guard let t = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var i: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyAlbumTitle: t.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: index,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count,
        ]
        if let img = Covers.shared.cached(t) { i[MPMediaItemPropertyArtwork] = artwork(img) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = i
        if Covers.shared.cached(t) == nil && !t.cover.isEmpty {
            Task {
                if await Covers.shared.load(t) != nil, MusicPlayer.shared.current?.id == t.id { MusicPlayer.shared.nowPlaying() }
            }
        }
    }

    // MARK: persistence

    func save(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastSave) > 10 else { return }
        lastSave = Date()
        Disk.write("player.json", SavedQueue(original: original, queue: queue, index: index, time: time, shuffle: shuffle, repeatMode: repeatMode.rawValue))
    }

    private func restore() {
        guard let s = Disk.read("player.json", as: SavedQueue.self), !s.queue.isEmpty else { return }
        original = s.original
        queue = s.queue
        index = min(max(s.index, 0), s.queue.count - 1)
        shuffle = s.shuffle
        repeatMode = Repeat(rawValue: s.repeatMode) ?? .off
        if let t = current {
            time = s.time
            duration = t.duration
        }
    }
}

/// Built outside the main actor: MediaPlayer may ask for the image on any thread.
private func artwork(_ img: UIImage) -> MPMediaItemArtwork {
    MPMediaItemArtwork(boundsSize: img.size) { _ in img }
}
