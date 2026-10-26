// Musica: the mini player docked at the bottom, the full player, the queue.
import AVKit
import SwiftUI

struct MiniPlayer: View {
    @EnvironmentObject private var player: MusicPlayer

    var body: some View {
        let t = player.current
        VStack(spacing: 0) {
            GeometryReader { g in
                Rectangle().fill(Brand.fg)
                    .frame(width: g.size.width * CGFloat(player.duration > 0 ? min(player.time / player.duration, 1) : 0))
            }
            .frame(height: 2)
            .background(Brand.line)
            HStack(spacing: 12) {
                CoverView(track: t, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t?.title ?? "").font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                    Text(t?.artist ?? "").font(.system(size: 12.5)).foregroundColor(Brand.dim).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { Haptic.tap(); player.toggle() } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 22)).frame(width: 44, height: 44)
                }
                .buttonStyle(Press())
                Button { Haptic.tap(); player.next() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 19)).frame(width: 40, height: 44)
                }
                .buttonStyle(Press())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .foregroundColor(Brand.fg)
        .background(.ultraThinMaterial)
        .background(Brand.surface)
        .clipShape(RoundedRectangle(cornerRadius: Brand.r.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Brand.r.tile, style: .continuous).stroke(Brand.line, lineWidth: 1))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .onTapGesture { player.full = true }
        .gesture(DragGesture(minimumDistance: 20).onEnded { v in if v.translation.height < -30 { player.full = true } })
    }
}

struct FullPlayer: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: MusicPlayer
    @State private var scrub: Double?
    @State private var showQueue = false
    @State private var drag: CGFloat = 0

    var body: some View {
        let t = player.current
        GeometryReader { g in
            let side = min(g.size.width - 48, g.size.height * 0.45)
            VStack(spacing: 0) {
                HStack {
                    Button { player.full = false } label: {
                        Image(systemName: "chevron.down").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44)
                    }
                    .buttonStyle(Press())
                    Spacer()
                    Text(store.online ? (t.map { store.isDownloaded($0.id) } == true ? "Sul telefono" : "Dal PC") : "Offline")
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(Brand.faint)
                    Spacer()
                    Menu {
                        if let t = t { TrackMenu(track: t, playlist: nil) }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44)
                    }
                }
                .padding(.horizontal, 12)
                Spacer(minLength: 12)
                CoverView(track: t, size: max(side, 120), radius: Brand.r.card)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                    .scaleEffect(player.playing ? 1 : 0.9)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: player.playing)
                Spacer(minLength: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text(t?.title ?? "").font(.system(size: 22, weight: .bold)).lineLimit(2)
                    Text(t?.subtitle ?? "").font(.system(size: 15)).foregroundColor(Brand.dim).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                VStack(spacing: 4) {
                    Slider(value: Binding(get: { scrub ?? player.time }, set: { scrub = $0 }),
                           in: 0...max(player.duration, 1),
                           onEditingChanged: { editing in
                               if !editing, let s = scrub { player.seek(s); scrub = nil }
                           })
                        .tint(Brand.fg)
                    HStack {
                        Text(mmss(scrub ?? player.time))
                        Spacer()
                        Text("-" + mmss(max(player.duration - (scrub ?? player.time), 0)))
                    }
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundColor(Brand.faint)
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                HStack {
                    Button { Haptic.tap(); player.setShuffle(!player.shuffle) } label: {
                        Image(systemName: "shuffle").font(.system(size: 19, weight: .semibold))
                            .foregroundColor(player.shuffle ? Brand.fg : Brand.faint).frame(width: 48, height: 48)
                    }
                    Spacer()
                    Button { Haptic.tap(); player.previous() } label: {
                        Image(systemName: "backward.fill").font(.system(size: 30)).frame(width: 64, height: 64)
                    }
                    Spacer()
                    Button { Haptic.tap(); player.toggle() } label: {
                        Image(systemName: player.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 76))
                    }
                    Spacer()
                    Button { Haptic.tap(); player.next() } label: {
                        Image(systemName: "forward.fill").font(.system(size: 30)).frame(width: 64, height: 64)
                    }
                    Spacer()
                    Button { Haptic.tap(); player.cycleRepeat() } label: {
                        Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").font(.system(size: 19, weight: .semibold))
                            .foregroundColor(player.repeatMode == .off ? Brand.faint : Brand.fg).frame(width: 48, height: 48)
                    }
                }
                .buttonStyle(Press())
                .padding(.horizontal, 20)
                .padding(.top, 14)
                Spacer(minLength: 16)
                HStack {
                    RoutePicker().frame(width: 44, height: 44)
                    Spacer()
                    Button { showQueue = true } label: {
                        Image(systemName: "list.bullet").font(.system(size: 19, weight: .semibold)).frame(width: 44, height: 44)
                    }
                    .buttonStyle(Press())
                }
                .foregroundColor(Brand.dim)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .foregroundColor(Brand.fg)
        .background(Brand.bg.ignoresSafeArea())
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
