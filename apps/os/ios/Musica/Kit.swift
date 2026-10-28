// Musica: the few pieces every screen shares (haptics, cover, buttons, rows).
import SwiftUI
import UIKit

enum Haptic {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func ok() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func select() { UISelectionFeedbackGenerator().selectionChanged() }
}

/// Local search: every word typed must be in title, artist or album, ignoring case and accents.
/// The folded text of each track is kept, so a keystroke over thousands of songs stays instant.
enum Search {
    private static var keys: [String: (sig: Int, key: String)] = [:]

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func key(_ t: Track) -> String {
        var h = Hasher()
        h.combine(t.title)
        h.combine(t.artist)
        h.combine(t.album)
        let sig = h.finalize()
        if let k = keys[t.id], k.sig == sig { return k.key }
        let k = fold(t.title + " " + t.artist + " " + t.album)
        keys[t.id] = (sig, k)
        return k
    }

    static func filter(_ ts: [Track], _ q: String) -> [Track] {
        let words = fold(q).split(separator: " ").map(String.init)
        if words.isEmpty { return ts }
        return ts.filter { t in
            let k = key(t)
            return words.allSatisfy { k.contains($0) }
        }
    }
}

/// The one search field of the app: a soft capsule, the clear button when there is text.
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Brand.faint)
            TextField("", text: $text, prompt: Text(prompt).foregroundColor(Brand.faint))
                .focused(focus)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(Brand.faint)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .font(.system(size: 16))
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Capsule(style: .continuous).fill(Brand.raised))
        .animation(.easeOut(duration: 0.15), value: text.isEmpty)
    }
}

/// A track's cover: memory (read in the body, so a cached cover never flashes), then the phone
/// decoded off the main thread at the drawn size, then the network.
struct CoverView: View {
    let track: Track?
    var size: CGFloat = 46
    var radius: CGFloat = Brand.r.small
    @State private var loaded: UIImage?
    @State private var loadedId: String?

    var body: some View {
        let px = coverPixels(size)
        let img = track.flatMap { t in (loadedId == t.id ? loaded : nil) ?? coverMemory.object(forKey: coverKey(t.id, px)) }
        ZStack {
            Rectangle().fill(Brand.raised)
            if let img = img {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.34, weight: .medium))
                    .foregroundColor(Brand.faint)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .task(id: track?.id) {
            guard let t = track, Covers.shared.cached(t, px: px) == nil else { return }
            let i = await Covers.shared.load(t, px: px)
            if !Task.isCancelled { loaded = i; loadedId = t.id }
        }
    }
}

/// White fill (primary) or a raised grey (secondary): monochrome like every Atlax surface.
struct Pill: ButtonStyle {
    var filled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .foregroundColor(filled ? Brand.bg : Brand.fg)
            .background(Capsule(style: .continuous).fill(filled ? Brand.fg : Brand.raised))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct Press: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// One track in any list. Tap plays; the ⋯ (or a long press) opens its menu.
struct TrackRow: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: MusicPlayer
    let track: Track
    var playlist: String? = nil
    /// Position in a playlist: shown instead of the cover's left edge, like an album.
    var number: Int? = nil
    let onTap: () -> Void

    var body: some View {
        let now = player.current?.id == track.id
        let ok = store.playable(track)
        HStack(spacing: 12) {
            Button(action: { Haptic.tap(); onTap() }) {
                HStack(spacing: 12) {
                    ZStack {
                        CoverView(track: track, size: 48, radius: 8)
                        if now {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.45))
                            Bars(on: player.playing).frame(width: 16, height: 14)
                        }
                    }
                    .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.system(size: 15.5, weight: now ? .semibold : .medium))
                            .foregroundColor(ok ? Brand.fg : Brand.faint)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            // On the phone is the normal case: only what is not there gets a mark.
                            if !store.isDownloaded(track.id) { DownloadMark(id: track.id) }
                            Text(track.artist.isEmpty ? mmss(track.duration) : track.artist).lineLimit(1)
                        }
                        .font(.system(size: 13))
                        .foregroundColor(Brand.dim)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu { TrackMenu(track: track, playlist: playlist) } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Brand.faint)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 5)
        .opacity(ok ? 1 : 0.45)
        .contextMenu { TrackMenu(track: track, playlist: playlist) }
    }
}

extension Brand {
    /// The one colour of the app: "this is on the phone".
    static let here = Color(red: 0.19, green: 0.84, blue: 0.45)
}

/// Where a track is, at a glance: green arrow = on the phone (plays offline),
/// a ring = downloading now, grey arrow = queued, cloud = only on the PC.
struct DownloadMark: View {
    @EnvironmentObject private var store: MusicStore
    let id: String

    var body: some View {
        Group {
            if store.isDownloaded(id) {
                Image(systemName: "arrow.down.circle.fill").foregroundColor(Brand.here)
            } else if store.inFlight.contains(id) {
                ProgressView().controlSize(.mini).scaleEffect(0.75)
            } else if store.pending.contains(id) {
                Image(systemName: "arrow.down.circle").foregroundColor(Brand.faint)
            } else {
                Image(systemName: "icloud").foregroundColor(Brand.faint)
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .frame(width: 13, height: 13)
    }
}

/// "On the phone" for a set of tracks: green check when all are, else how many.
struct HereLine: View {
    @EnvironmentObject private var store: MusicStore
    let ids: [String]
    var size: CGFloat = 12.5

    var body: some View {
        let ids = ids.filter { store.track($0)?.supported ?? false }
        let all = ids.count
        let have = ids.filter { store.isDownloaded($0) }.count
        HStack(spacing: 5) {
            // All on the phone is the normal case: no mark, just the count.
            if have < all {
                Image(systemName: "icloud")
                    .foregroundColor(Brand.faint)
                    .font(.system(size: size - 1, weight: .semibold))
            }
            Text(have >= all ? "\(all) brani" : "\(all - have) da scaricare")
                .font(.system(size: size).monospacedDigit())
                .foregroundColor(Brand.dim)
                .lineLimit(1)
        }
    }
}

/// The three bouncing bars on the track that is playing (still when paused).
struct Bars: View {
    let on: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !on)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2.5) {
                ForEach(0..<3) { i in
                    let h = on ? 0.35 + 0.65 * abs(sin(t * (5.2 + Double(i) * 1.7) + Double(i))) : 0.35
                    Capsule().fill(Brand.fg).frame(width: 3.5).frame(height: 14 * h)
                }
            }
            .frame(height: 14, alignment: .bottom)
        }
    }
}

/// A playlist's face: its first four covers in a square, or the first one alone.
struct Mosaic: View {
    @EnvironmentObject private var store: MusicStore
    let ids: [String]
    var radius: CGFloat = Brand.r.tile

    var body: some View {
        GeometryReader { g in
            let ts = ids.prefix(12).compactMap { store.track($0) }.filter { !$0.cover.isEmpty }
            let four = Array(ts.prefix(4))
            ZStack {
                Rectangle().fill(Brand.raised)
                if four.count == 4 {
                    let h = g.size.width / 2
                    VStack(spacing: 0) {
                        HStack(spacing: 0) { tile(four[0], h); tile(four[1], h) }
                        HStack(spacing: 0) { tile(four[2], h); tile(four[3], h) }
                    }
                } else if let t = ts.first {
                    CoverView(track: t, size: g.size.width, radius: 0)
                } else {
                    Image(systemName: "music.note.list").font(.system(size: g.size.width * 0.28, weight: .medium)).foregroundColor(Brand.faint)
                }
            }
            .frame(width: g.size.width, height: g.size.width)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private func tile(_ t: Track, _ side: CGFloat) -> some View {
        CoverView(track: t, size: side, radius: 0)
    }
}

/// The cover blown up and blurred, fading to black: the colour of the song behind a screen.
struct Backdrop: View {
    let track: Track?
    var fade = true
    @State private var img: UIImage?

    var body: some View {
        ZStack {
            Brand.bg
            if let img = img {
                Image(uiImage: img).resizable().scaledToFill()
                    .blur(radius: 70, opaque: true)
                    .saturation(1.4)
                    .opacity(0.75)
                    .transition(.opacity)
            }
            if fade {
                LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.55), .black], startPoint: .top, endPoint: .bottom)
            } else {
                Color.black.opacity(0.42)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.5), value: img)
        .task(id: track?.id) {
            guard let t = track else { img = nil; return }
            // Blurred to death: a small decode is all it needs.
            img = Covers.shared.cached(t, px: 160)
            if img == nil { img = await Covers.shared.load(t, px: 160) }
        }
    }
}

/// Long-press menu of a track (singletons: a context menu is its own tree).
struct TrackMenu: View {
    let track: Track
    let playlist: String?

    var body: some View {
        let store = MusicStore.shared
        let player = MusicPlayer.shared
        Button { player.playNext(track.id) } label: { Label("Riproduci dopo", systemImage: "text.insert") }
        Button { player.enqueue(track.id) } label: { Label("Aggiungi in coda", systemImage: "text.append") }
        if store.isDownloaded(track.id) {
            Button(role: .destructive) { store.delete(track.id) } label: { Label("Elimina dal telefono", systemImage: "trash") }
        } else if track.supported {
            Button { store.download([track.id]) } label: { Label("Scarica", systemImage: "arrow.down.circle") }
        }
        if !store.playlists.isEmpty {
            Menu {
                ForEach(store.playlists) { p in
                    Button(p.name) { store.addTo(p.name, track.id); Haptic.ok() }
                }
            } label: { Label("Aggiungi a playlist", systemImage: "text.badge.plus") }
        }
        if let pl = playlist {
            Button(role: .destructive) { store.removeFrom(pl, track.id) } label: { Label("Togli dalla playlist", systemImage: "minus.circle") }
        }
    }
}

extension View {
    /// A list row on the black page: no grey cell, hairline separators.
    func row() -> some View {
        listRowBackground(Brand.bg)
            .listRowSeparatorTint(Brand.line)
            .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 14))
    }

    func page() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Brand.bg)
    }
}

func megabytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}
