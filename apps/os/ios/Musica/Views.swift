// Musica: the screens. Three tabs (Ascolta, Playlist, Cerca) in a bar of our own,
// the mini player floating above it, the full player over everything.
import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case home = "Ascolta", playlists = "Playlist", search = "Cerca"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: return "play.circle"
        case .playlists: return "square.stack"
        case .search: return "magnifyingglass"
        }
    }
    var iconOn: String {
        switch self {
        case .home: return "play.circle.fill"
        case .playlists: return "square.stack.fill"
        case .search: return "magnifyingglass"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.scenePhase) private var phase
    @AppStorage("musica.tab") private var tab = Pane.home.rawValue
    @State private var login = false

    var body: some View {
        let pane = Pane(rawValue: tab) ?? .home
        ZStack {
            Brand.bg.ignoresSafeArea()
            // Every tab keeps its own stack (and its scroll) while you switch.
            ForEach(Pane.allCases) { p in
                NavigationStack { screen(p) }
                    .opacity(p == pane ? 1 : 0)
                    .allowsHitTesting(p == pane)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                if player.current != nil { MiniPlayer().transition(.move(edge: .bottom).combined(with: .opacity)) }
                TabBar(tab: $tab)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.86), value: player.current?.id)
        }
        .fullScreenCover(isPresented: $player.full) { FullPlayer() }
        .sheet(isPresented: $login) { LoginSheet() }
        .onAppear { if store.needsLogin && store.online { login = true } }
        .onChange(of: store.needsLogin) { need in if need && store.online { login = true } }
        .onChange(of: phase) { p in
            if p == .active { Task { await store.refresh() }; store.pump() }
            if p == .background { player.save(force: true) }
        }
        // While open, the library stays current with the PC every few minutes (new songs get saved too).
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                if phase == .active { await store.refresh() }
            }
        }
    }

    @ViewBuilder private func screen(_ p: Pane) -> some View {
        switch p {
        case .home: HomeView(login: $login)
        case .playlists: PlaylistsView()
        case .search: SearchView()
        }
    }
}

/// The bottom bar: three icons with their names, on glass, the selected one white.
struct TabBar: View {
    @Binding var tab: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Pane.allCases) { p in
                let on = tab == p.rawValue
                Button {
                    if !on { Haptic.tap() }
                    tab = p.rawValue
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: on ? p.iconOn : p.icon).font(.system(size: 20, weight: on ? .semibold : .regular))
                        Text(p.rawValue).font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundColor(on ? Brand.fg : Brand.faint)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(.ultraThinMaterial)
        .background(Brand.bg.opacity(0.55))
        .overlay(Rectangle().fill(Brand.line).frame(height: 0.5), alignment: .top)
    }
}

// MARK: Ascolta

struct HomeView: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: MusicPlayer
    @Binding var login: Bool
    @State private var confirmWipe = false

    var body: some View {
        let ids = store.tracks.map(\.id)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Banner(login: $login).padding(.horizontal, 20).padding(.bottom, 14)
                if store.tracks.isEmpty {
                    Empty(text: store.loading ? "Carico la libreria…" : "La libreria è vuota.\nCerca un brano per aggiungerlo.")
                        .padding(.top, 60)
                } else {
                    HStack(spacing: 10) {
                        Button { player.play(ids, shuffled: true) } label: { Label("Casuale", systemImage: "shuffle") }.buttonStyle(Pill())
                        Button { player.play(ids) } label: { Label("Riproduci", systemImage: "play.fill") }.buttonStyle(Pill(filled: false))
                    }
                    .padding(.horizontal, 20)
                    if !store.playlists.isEmpty {
                        SectionTitle(text: "Le tue playlist").padding(.top, 28)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(store.playlists) { p in
                                    NavigationLink(value: p.name) { PlaylistCard(playlist: p, side: 150) }.buttonStyle(Press())
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                    SectionTitle(text: "Tutti i brani", trailing: "\(store.tracks.count)").padding(.top, 28).padding(.bottom, 4)
                    ForEach(Array(store.tracks.enumerated()), id: \.element.id) { i, t in
                        TrackRow(track: t) { player.play(ids, from: i) }
                            .padding(.horizontal, 20)
                    }
                    Footer(text: store.syncedAt.map { "Aggiornata alle " + $0.formatted(date: .omitted, time: .shortened) } ?? "")
                        .padding(.top, 8)
                }
            }
            .padding(.bottom, 24)
        }
        .refreshable { await store.refresh() }
        .background(Brand.bg)
        .navigationTitle("Musica")
        .navigationDestination(for: String.self) { PlaylistView(name: $0) }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { Task { await store.refresh() } } label: { Label("Aggiorna", systemImage: "arrow.clockwise") }
                    Text("\(store.downloadedTracks.count) brani · \(megabytes(store.bytes)) sul telefono")
                    Divider()
                    if store.needsLogin {
                        Button { login = true } label: { Label("Accedi", systemImage: "person.crop.circle") }
                    } else {
                        Button(role: .destructive) { confirmWipe = true } label: { Label("Libera spazio sul telefono", systemImage: "trash") }
                        Button(role: .destructive) { store.signOut() } label: { Label("Esci", systemImage: "rectangle.portrait.and.arrow.right") }
                    }
                } label: {
                    Image(systemName: store.loading ? "arrow.triangle.2.circlepath" : "ellipsis.circle")
                        .font(.system(size: 17, weight: .medium))
                }
            }
        }
        .confirmationDialog("Togliere i brani dal telefono? Si riscaricano col prossimo aggiornamento.", isPresented: $confirmWipe, titleVisibility: .visible) {
            Button("Togli tutti", role: .destructive) { store.deleteAll() }
        }
    }
}

/// Sign-in call, then the quiet status line, then a note from the server or the player.
struct Banner: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: MusicPlayer
    @Binding var login: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.needsLogin {
                HStack(spacing: 12) {
                    Text("Accedi una volta con Atlax ID: poi la musica va anche senza rete.")
                        .font(.system(size: 13)).foregroundColor(Brand.dim)
                    Button("Accedi") { login = true }.buttonStyle(Pill()).frame(width: 96)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: Brand.r.tile, style: .continuous).fill(Brand.surface))
            } else {
                Status()
            }
            if let n = store.note { Note(icon: "info.circle", text: n) }
            if let m = player.message { Note(icon: "exclamationmark.circle", text: m) }
        }
    }
}

/// One quiet line: is the phone self-sufficient, is it filling up, is it offline. No box, no colour.
struct Status: View {
    @EnvironmentObject private var store: MusicStore

    var body: some View {
        let all = store.tracks.filter(\.supported).count
        let have = store.downloadedTracks.count
        let busy = !store.inFlight.isEmpty || !store.pending.isEmpty
        let text = line(all: all, have: have, busy: busy)
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon(all: all, have: have))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(store.online && have >= all ? Brand.here : Brand.dim)
                    Text(text).font(.system(size: 12.5).monospacedDigit()).lineLimit(1)
                }
                .foregroundColor(Brand.dim)
                if busy && store.online && all > 0 {
                    Capsule().fill(Brand.raised).frame(height: 2)
                        .overlay(GeometryReader { g in
                            Capsule().fill(Brand.fg.opacity(0.7)).frame(width: g.size.width * CGFloat(have) / CGFloat(all))
                        }, alignment: .leading)
                        .frame(maxWidth: 180)
                }
            }
            .animation(.easeOut(duration: 0.25), value: busy)
        }
    }

    private func icon(all: Int, have: Int) -> String {
        if !store.online { return "wifi.slash" }
        return have >= all ? "arrow.down.circle.fill" : "arrow.down.circle"
    }

    private func line(all: Int, have: Int, busy: Bool) -> String {
        if !store.online { return "Offline · \(have) brani sul telefono" }
        if !store.pcOn && store.syncedAt != nil && have < all { return "PC spento · \(have) di \(all) sul telefono" }
        if busy { return "Scarico sul telefono · \(have) di \(all)" }
        if have < all { return "\(have) di \(all) sul telefono" }
        return all == 0 ? "" : "Tutti i \(all) brani sul telefono: vanno anche offline"
    }
}

struct Note: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            Text(text).font(.system(size: 13)).lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundColor(Brand.dim)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: Brand.r.small, style: .continuous).fill(Brand.surface))
    }
}

// MARK: Playlist

struct PlaylistsView: View {
    @EnvironmentObject private var store: MusicStore
    @State private var naming = false
    @State private var name = ""
    private let cols = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        ScrollView {
            if store.playlists.isEmpty {
                Empty(text: "Nessuna playlist.").padding(.top, 80)
            } else {
                LazyVGrid(columns: cols, alignment: .leading, spacing: 22) {
                    ForEach(store.playlists) { p in
                        NavigationLink(value: p.name) { PlaylistCard(playlist: p, side: nil) }.buttonStyle(Press())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 24)
            }
        }
        .refreshable { await store.refresh() }
        .background(Brand.bg)
        .navigationTitle("Playlist")
        .navigationDestination(for: String.self) { PlaylistView(name: $0) }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { name = ""; naming = true } label: { Image(systemName: "plus").font(.system(size: 17, weight: .semibold)) }
            }
        }
        .alert("Nuova playlist", isPresented: $naming) {
            TextField("Nome", text: $name)
            Button("Annulla", role: .cancel) {}
            Button("Crea") {
                let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !n.isEmpty && store.playlist(n) == nil { store.savePlaylist(n, []) }
            }
        }
    }
}

/// A playlist as a square of its covers, its name and how many songs.
struct PlaylistCard: View {
    @EnvironmentObject private var store: MusicStore
    let playlist: Playlist
    /// Fixed side (carousel) or the grid cell's width.
    let side: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let s = side {
                    Mosaic(ids: playlist.ids, radius: Brand.r.tile).frame(width: s, height: s)
                } else {
                    Mosaic(ids: playlist.ids, radius: Brand.r.tile).aspectRatio(1, contentMode: .fit)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name).font(.system(size: 15, weight: .semibold)).foregroundColor(Brand.fg).lineLimit(1)
                HereLine(ids: playlist.ids, size: 12)
            }
        }
        .frame(width: side)
    }
}

struct PlaylistView: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.dismiss) private var dismiss
    let name: String
    @State private var confirmDelete = false
    @State private var editing = false

    var body: some View {
        let p = store.playlist(name) ?? Playlist(name: name, ids: [])
        let ts = store.tracks(of: p)
        let ids = ts.map(\.id)
        let minutes = Int(ts.reduce(0) { $0 + $1.duration } / 60)
        List {
            VStack(spacing: 18) {
                Mosaic(ids: p.ids, radius: Brand.r.card)
                    .frame(width: 236, height: 236)
                    .shadow(color: .black.opacity(0.55), radius: 26, y: 14)
                VStack(spacing: 4) {
                    Text(name).font(.system(size: 26, weight: .bold)).multilineTextAlignment(.center).lineLimit(2)
                    Text("\(ts.count) brani · \(minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min")")
                        .font(.system(size: 13).monospacedDigit()).foregroundColor(Brand.dim)
                    if !ts.isEmpty { HereLine(ids: ids, size: 13) }
                }
                HStack(spacing: 10) {
                    Button { player.play(ids) } label: { Label("Riproduci", systemImage: "play.fill") }.buttonStyle(Pill())
                    Button { player.play(ids, shuffled: true) } label: { Label("Casuale", systemImage: "shuffle") }.buttonStyle(Pill(filled: false))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.bottom, 10)
            .background(alignment: .top) { Backdrop(track: ts.first).frame(height: 420).offset(y: -160) }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            ForEach(Array(ts.enumerated()), id: \.element.id) { i, t in
                TrackRow(track: t, playlist: name, number: i + 1) { player.play(ids, from: i) }.row()
            }
            .onDelete { offs in for o in offs { store.removeFrom(name, ts[o].id) } }
            .onMove { from, to in
                var next = ids
                next.move(fromOffsets: from, toOffset: to)
                store.savePlaylist(name, next)
            }
            if ts.isEmpty { Empty(text: "Vuota. Tieni premuto un brano → Aggiungi a playlist.").row() }
        }
        .page()
        .environment(\.editMode, .constant(editing ? .active : .inactive))
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { withAnimation { editing.toggle() } } label: { Label(editing ? "Fine" : "Riordina", systemImage: "arrow.up.arrow.down") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Elimina playlist", systemImage: "trash") }
                } label: { Image(systemName: editing ? "checkmark.circle.fill" : "ellipsis.circle").font(.system(size: 17, weight: .medium)) }
            }
        }
        .confirmationDialog("Eliminare \(name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Elimina playlist", role: .destructive) { store.deletePlaylist(name); dismiss() }
        }
    }
}

// MARK: Cerca

struct SearchView: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: MusicPlayer
    @AppStorage("musica.q") private var q = ""
    @State private var found: [Candidate] = []
    @State private var searching = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        let needle = q.trimmingCharacters(in: .whitespaces)
        let local = needle.isEmpty ? [] : store.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(needle) || $0.artist.localizedCaseInsensitiveContains(needle) || $0.album.localizedCaseInsensitiveContains(needle)
        }
        let ids = local.map(\.id)
        let have = Set(store.tracks.map(\.id))
        let fresh = found.filter { !have.contains($0.id) || store.adding.contains($0.id) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(Brand.faint)
                    TextField("Brani, artisti, YouTube", text: $q)
                        .focused($focused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .onSubmit { focused = false; remote(needle) }
                    if !q.isEmpty {
                        Button { q = ""; found = [] } label: { Image(systemName: "xmark.circle.fill").foregroundColor(Brand.faint) }.buttonStyle(.plain)
                    }
                }
                .font(.system(size: 16))
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: Brand.r.tile, style: .continuous).fill(Brand.surface))
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                if needle.isEmpty {
                    Empty(text: "Cerca nella tua musica e su YouTube.\nTocca un risultato di YouTube: si aggiunge e parte.").padding(.top, 60)
                }
                if !local.isEmpty {
                    SectionTitle(text: "Nella libreria", trailing: "\(local.count)").padding(.top, 14)
                    ForEach(Array(local.enumerated()), id: \.element.id) { i, t in
                        TrackRow(track: t) { player.play(ids, from: i) }.padding(.horizontal, 20)
                    }
                }
                if !needle.isEmpty {
                    Group {
                        if !store.online {
                            Footer(text: "Offline: cerco solo nella libreria.")
                        } else if !fresh.isEmpty {
                            SectionTitle(text: "Da YouTube", trailing: searching ? "…" : nil).padding(.top, 22)
                            ForEach(fresh) { c in CandidateRow(c: c).padding(.horizontal, 20) }
                        } else if searching {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Cerco su YouTube…") }
                                .font(.system(size: 13)).foregroundColor(Brand.dim)
                                .frame(maxWidth: .infinity).padding(.vertical, 22)
                        } else if let e = error {
                            Footer(text: e)
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Brand.bg)
        .navigationTitle("Cerca")
        // YouTube as you type: a short pause after the last letter, the newest query wins.
        .task(id: needle) {
            guard needle.count >= 2 else { found = []; error = nil; return }
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            remote(needle)
        }
    }

    private func remote(_ needle: String) {
        guard !needle.isEmpty, store.online else { return }
        searching = true
        error = nil
        Task {
            let r: Result<[Candidate], Error>
            do { r = .success(try await store.search(needle).found) } catch { r = .failure(error) }
            // An older answer that arrives late must not replace the newer one.
            guard q.trimmingCharacters(in: .whitespaces) == needle else { return }
            searching = false
            switch r {
            case .success(let c):
                found = c
                if c.isEmpty { error = "Niente su YouTube." }
            case .failure(let e):
                switch e as? MusicError {
                case .auth?: error = "Serve l'accesso."
                case .pcOff?: error = "Il PC è spento: la ricerca passa da lì."
                default: error = "Ricerca non riuscita."
                }
            }
        }
    }
}

/// A YouTube result: tap = into the library and playing; + = only into the library.
struct CandidateRow: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: MusicPlayer
    let c: Candidate

    var body: some View {
        let busy = store.adding.contains(c.id)
        HStack(spacing: 12) {
            Button { take(play: true) } label: {
                HStack(spacing: 12) {
                    AsyncImage(url: URL(string: c.thumb)) { img in img.resizable().scaledToFill() } placeholder: { Rectangle().fill(Brand.raised) }
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(c.title).font(.system(size: 15.5, weight: .medium)).foregroundColor(Brand.fg).lineLimit(1)
                        Text(busy ? "Lo prendo da YouTube…" : [c.channel, c.duration > 0 ? mmss(c.duration) : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 13)).foregroundColor(Brand.dim).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy)
            if busy {
                ProgressView().controlSize(.small).frame(width: 32)
            } else {
                Button { take(play: false) } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 26)).foregroundColor(Brand.fg)
                }
                .buttonStyle(Press())
            }
        }
        .padding(.vertical, 7)
    }

    /// The PC fetches it into the library (some seconds); with `play` it starts right after.
    private func take(play: Bool) {
        guard !store.adding.contains(c.id) else { return }
        Haptic.tap()
        let id = c.id
        Task {
            guard await store.add(c) else { return }
            Haptic.ok()
            if play, store.track(id) != nil { player.play([id]) }
        }
    }
}

// MARK: small pieces

struct SectionTitle: View {
    let text: String
    var trailing: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.system(size: 21, weight: .bold)).foregroundColor(Brand.fg)
            Spacer()
            if let t = trailing { Text(t).font(.system(size: 13).monospacedDigit()).foregroundColor(Brand.faint) }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }
}

struct Empty: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 14)).foregroundColor(Brand.faint).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(.vertical, 24)
    }
}

struct Header: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11.5, weight: .semibold)).tracking(0.6).foregroundColor(Brand.faint).padding(.top, 8)
    }
}

struct Footer: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundColor(Brand.faint).frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 10)
    }
}
