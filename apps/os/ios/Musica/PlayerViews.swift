// Musica: the mini player docked at the bottom, the full player, the queue.
import AVKit
import SwiftUI

struct MiniPlayer: View {
    @EnvironmentObject private var player: MusicPlayer

    var body: some View {
        let t = player.current
        HStack(spacing: 12) {
            CoverView(track: t, size: 40, radius: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(t?.title ?? "").font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                Text(t?.artist ?? "").font(.system(size: 12.5)).foregroundColor(Brand.dim).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button { Haptic.tap(); player.toggle() } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 21)).frame(width: 42, height: 42)
            }
            .buttonStyle(Press())
            Button { Haptic.tap(); player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 18)).frame(width: 38, height: 42)
            }
            .buttonStyle(Press())
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        .foregroundColor(Brand.fg)
        .background {
            ZStack {
                Backdrop(track: t, fade: false)
                Rectangle().fill(.ultraThinMaterial).opacity(0.6)
            }
        }
        .overlay(alignment: .bottom) {
            GeometryReader { g in
                Capsule().fill(Brand.fg.opacity(0.85))
                    .frame(width: g.size.width * CGFloat(player.duration > 0 ? min(player.time / player.duration, 1) : 0), height: 2)
            }
            .frame(height: 2)
            .padding(.horizontal, 14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Brand.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onTapGesture { player.full = true }
        .gesture(DragGesture(minimumDistance: 20).onEnded { v in if v.translation.height < -30 { player.full = true } })
    }
}

struct FullPlayer: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: MusicPlayer
    @State private var showQueue = false
    @State private var drag: CGFloat = 0

    var body: some View {
        let t = player.current
        GeometryReader { g in
            let side = min(g.size.width - 56, g.size.height * 0.44)
            VStack(spacing: 0) {
                HStack {
                    Button { player.full = false } label: {
                        Image(systemName: "chevron.down").font(.system(size: 17, weight: .bold)).frame(width: 44, height: 44)
                    }
                    .buttonStyle(Press())
                    Spacer()
                    if let t = t, !store.isDownloaded(t.id) {
                        Label(store.online ? "Dal PC" : "Non scaricato", systemImage: "icloud")
                            .font(.system(size: 11.5, weight: .semibold)).foregroundColor(Brand.dim)
                    }
                    Spacer()
                    Button { showQueue = true } label: {
                        Image(systemName: "list.bullet").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
                    }
                    .buttonStyle(Press())
                }
                .padding(.horizontal, 14)
                Spacer(minLength: 10)
                CoverView(track: t, size: max(side, 120), radius: Brand.r.card)
                    .shadow(color: .black.opacity(0.55), radius: 30, y: 16)
                    .scaleEffect(player.playing ? 1 : 0.86)
                    .animation(.spring(response: 0.45, dampingFraction: 0.75), value: player.playing)
                Spacer(minLength: 22)
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t?.title ?? "").font(.system(size: 22, weight: .bold)).lineLimit(1)
                        Text(t?.artist ?? "").font(.system(size: 17)).foregroundColor(Brand.dim).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Menu {
                        if let t = t { TrackMenu(track: t, playlist: nil) }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 16, weight: .bold))
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Brand.raised))
                    }
                }
                .padding(.horizontal, 28)
                Scrubber().padding(.horizontal, 28).padding(.top, 20)
                HStack {
                    Button { Haptic.tap(); player.setShuffle(!player.shuffle) } label: {
                        Image(systemName: "shuffle").font(.system(size: 18, weight: .semibold))
                            .foregroundColor(player.shuffle ? Brand.fg : Brand.faint).frame(width: 48, height: 48)
                    }
                    Spacer()
                    Button { Haptic.tap(); player.previous() } label: {
                        Image(systemName: "backward.fill").font(.system(size: 32)).frame(width: 66, height: 66)
                    }
                    Spacer()
                    Button { Haptic.tap(); player.toggle() } label: {
                        Image(systemName: player.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 34))
                            .foregroundColor(Brand.bg)
                            .frame(width: 78, height: 78)
                            .background(Circle().fill(Brand.fg))
                    }
                    Spacer()
                    Button { Haptic.tap(); player.next() } label: {
                        Image(systemName: "forward.fill").font(.system(size: 32)).frame(width: 66, height: 66)
                    }
                    Spacer()
                    Button { Haptic.tap(); player.cycleRepeat() } label: {
                        Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").font(.system(size: 18, weight: .semibold))
                            .foregroundColor(player.repeatMode == .off ? Brand.faint : Brand.fg).frame(width: 48, height: 48)
                    }
                }
                .buttonStyle(Press())
                .padding(.horizontal, 20)
                .padding(.top, 14)
                Spacer(minLength: 14)
                HStack {
                    RoutePicker().frame(width: 44, height: 44)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 6)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .foregroundColor(Brand.fg)
        .background(Backdrop(track: t).ignoresSafeArea())
        .offset(y: drag)
        .gesture(DragGesture(minimumDistance: 24)
            .onChanged { v in drag = max(v.translation.height, 0) }
            .onEnded { v in
                if v.translation.height > 140 { player.full = false }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { drag = 0 }
            })
        .sheet(isPresented: $showQueue) { QueueView() }
    }
}

/// The time bar: a thin line that grows under the finger, the times beneath it.
struct Scrubber: View {
    @EnvironmentObject private var player: MusicPlayer
    @State private var scrub: Double?

    var body: some View {
        let dur = max(player.duration, 1)
        let now = scrub ?? player.time
        VStack(spacing: 7) {
            GeometryReader { g in
                let w = g.size.width
                let on = scrub != nil
                ZStack(alignment: .leading) {
                    Capsule().fill(Brand.fg.opacity(0.22))
                    Capsule().fill(Brand.fg.opacity(on ? 1 : 0.85)).frame(width: w * CGFloat(min(now / dur, 1)))
                }
                .frame(height: on ? 9 : 5)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in scrub = min(max(Double(v.location.x / w), 0), 1) * dur }
                    .onEnded { _ in
                        if let s = scrub { player.seek(s); Haptic.tap() }
                        scrub = nil
                    })
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: on)
            }
            .frame(height: 22)
            HStack {
                Text(mmss(now))
                Spacer()
                Text("-" + mmss(max(player.duration - now, 0)))
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundColor(Brand.dim)
        }
    }
}

struct QueueView: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let t = player.current {
                    Section {
                        row(t, now: true).row()
                    } header: { Header(text: "In riproduzione") }
                }
                Section {
                    ForEach(Array(player.upNext.enumerated()), id: \.offset) { i, id in
                        if let t = store.track(id) {
                            Button { player.jump(player.index + 1 + i) } label: { row(t, now: false) }.buttonStyle(.plain).row()
                        }
                    }
                    .onDelete { player.removeUpNext(at: $0) }
                    .onMove { player.moveUpNext(from: $0, to: $1) }
                } header: { Header(text: player.upNext.isEmpty ? "Coda vuota" : "A seguire") }
            }
            .page()
            .navigationTitle("Coda")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { EditButton() }
                ToolbarItem(placement: .navigationBarTrailing) { Button("Fatto") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }

    private func row(_ t: Track, now: Bool) -> some View {
        HStack(spacing: 12) {
            CoverView(track: t, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).font(.system(size: 15, weight: now ? .semibold : .regular)).lineLimit(1)
                Text(t.artist).font(.system(size: 12.5)).foregroundColor(Brand.dim).lineLimit(1)
            }
            Spacer(minLength: 8)
            if !store.playable(t) { Image(systemName: "icloud.slash").font(.system(size: 12)).foregroundColor(Brand.faint) }
        }
        .contentShape(Rectangle())
    }
}

/// AirPlay / Bluetooth output picker.
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = UIColor.white.withAlphaComponent(0.56)
        v.activeTintColor = .white
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ v: AVRoutePickerView, context: Context) {}
}
