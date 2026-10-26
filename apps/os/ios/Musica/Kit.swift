// Musica: the few pieces every screen shares (haptics, cover, buttons, rows).
import SwiftUI
import UIKit

enum Haptic {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func ok() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

/// A track's cover: memory, then the phone, then the network.
struct CoverView: View {
    let track: Track?
    var size: CGFloat = 46
    var radius: CGFloat = Brand.r.small
    @State private var img: UIImage?

    var body: some View {
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
            guard let t = track else { img = nil; return }
            img = Covers.shared.cached(t)
            if img == nil { img = await Covers.shared.load(t) }
        }
    }
}

/// White fill (primary) or a raised grey (secondary): monochrome like every Atlax surface.
struct Pill: ButtonStyle {
    var filled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .foregroundColor(filled ? Brand.bg : Brand.fg)
            .background(RoundedRectangle(cornerRadius: Brand.r.small, style: .continuous).fill(filled ? Brand.fg : Brand.raised))
            .opacity(configuration.isPressed ? 0.7 : 1)
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

/// One track in any list. Tap plays; long press opens the menu.
struct TrackRow: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: MusicPlayer
    let track: Track
    var playlist: String? = nil
    let onTap: () -> Void

    var body: some View {
        let now = player.current?.id == track.id
        let ok = store.playable(track)
        Button(action: { Haptic.tap(); onTap() }) {
            HStack(spacing: 12) {
                CoverView(track: track)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 15, weight: now ? .semibold : .regular))
                        .foregroundColor(ok ? Brand.fg : Brand.faint)
                        .lineLimit(1)
                    Text(track.subtitle.isEmpty ? " " : track.subtitle)
                        .font(.system(size: 12.5))
                        .foregroundColor(Brand.dim)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if now {
                    Image(systemName: player.playing ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.system(size: 12)).foregroundColor(Brand.fg)
                }
                if store.downloading == track.id {
                    ProgressView().controlSize(.small)
                } else if store.isDownloaded(track.id) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 13)).foregroundColor(Brand.dim)
                } else if store.pending.contains(track.id) {
                    Image(systemName: "clock").font(.system(size: 12)).foregroundColor(Brand.faint)
                }
                Text(mmss(track.duration))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundColor(Brand.faint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { TrackMenu(track: track, playlist: playlist) }
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
            .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
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
