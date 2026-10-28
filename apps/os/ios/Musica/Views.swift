// Musica: the screens. Three tabs (Ascolta, Playlist, Cerca), each with its own stack,
// under the floating dock and mini player (Dock.swift); the full player over everything.
import SwiftUI
import UIKit

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
    @EnvironmentObject private var dock: DockState
    @Environment(\.scenePhase) private var phase
    @AppStorage("musica.tab") private var tab = Pane.home.rawValue
    @State private var login = false
    @State private var paths: [Pane: NavigationPath] = [:]
    @State private var keyboard = false

    var body: some View {
        let pane = Pane(rawValue: tab) ?? .home
        // Reserved under every screen: the open bar (it only gets smaller when folded),
        // a constant so the lists never jump while the dock folds.
        let inset = Bar.open + (player.current != nil ? Bar.open + Bar.gap : 0)
        ZStack {
            Brand.bg.ignoresSafeArea()
            // Every tab keeps its own stack (and its scroll) while you switch.
            ForEach(Pane.allCases) { p in
                NavigationStack(path: path(p)) { screen(p).underBar() }
                    .environment(\.barInset, inset)
                    .opacity(p == pane ? 1 : 0)
                    .allowsHitTesting(p == pane)
                    .accessibilityHidden(p != pane)
            }
        }
        .overlay(alignment: .bottom) {
            BottomBar(tab: $tab, reselect: reselect)
                .padding(.bottom, 2)
                // Typing: the keyboard has the bottom, the bar steps aside.
                .opacity(keyboard ? 0 : 1)
                .offset(y: keyboard ? 30 : 0)
                .allowsHitTesting(!keyboard)
                .animation(.easeOut(duration: 0.2), value: keyboard)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboard = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboard = false }
        .onChange(of: tab) { _ in dock.set(false) }
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

    private func path(_ p: Pane) -> Binding<NavigationPath> {
        Binding(get: { paths[p] ?? NavigationPath() }, set: { paths[p] = $0 })
    }

    /// The tab already open, tapped again: back to its first screen.
    private func reselect(_ p: Pane) {
        Haptic.tap()
        if let n = paths[p], !n.isEmpty { paths[p] = NavigationPath() }
        dock.set(false)
    }

    @ViewBuilder private func screen(_ p: Pane) -> some View {
        switch p {
        case .home: HomeView(login: $login)
        case .playlists: PlaylistsView()
        case .search: SearchView()
        }
    }
}

// MARK: Ascolta

struct HomeView: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: MusicPlayer
    @Binding var login: Bool
    @State private var confirmWipe = false
    @State private var q = ""
    @State private var found: [Track] = []
    @FocusState private var focused: Bool

    var body: some View {
        let searching = !q.trimmingCharacters(in: .whitespaces).isEmpty
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SearchField(prompt: "Cerca nei tuoi brani", text: $q, focus: $focused)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
                if store.tracks.isEmpty {
                    Banner(login: $login).padding(.horizontal, 20)
                    Empty(text: store.loading ? "Carico la libreria…" : "La libreria è vuota.\nCerca un brano per aggiungerlo.")
                        .padding(.top, 50)
                } else if searching {
                    if found.isEmpty {
                        Empty(text: "Nessun brano trovato.").padding(.top, 30)
                    } else {
                        SectionTitle(text: "Risultati", trailing: "\(found.count)").padding(.top, 6).padding(.bottom, 2)
                        rows(found)
                    }
                } else {
                    Banner(login: $login).padding(.horizontal, 20).padding(.bottom, 14)
                    HStack(spacing: 10) {
                        Button { player.play(store.tracks.map(\.id), shuffled: true) } label: { Label("Casuale", systemImage: "shuffle") }.buttonStyle(Pill())
                        Button { player.play(store.tracks.map(\.id)) } label: { Label("Riproduci", systemImage: "play.fill") }.buttonStyle(Pill(filled: false))
                    }
                    .padding(.horizontal, 20)
                    if !store.playlists.isEmpty {
                        SectionTitle(text: "Le tue playlist").padding(.top, 30)
                        // Two columns of compact tiles: every playlist one tap away, no sideways scroll.
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(store.playlists) { p in
                                NavigationLink(value: p.name) { PlaylistTile(playlist: p) }.buttonStyle(Press())
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 2)
                    }
                    SectionTitle(text: "Tutti i brani", trailing: "\(store.tracks.count)").padding(.top, 30).padding(.bottom, 2)
                    rows(store.tracks)
                    Footer(text: store.syncedAt.map { "Aggiornata alle " + $0.formatted(date: .omitted, time: .shortened) } ?? "")
                        .padding(.top, 8)
                }
            }
            .padding(.bottom, 24)
            .dockScroll()
        }
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await store.refresh() }
        .background(Brand.bg)
        .navigationTitle("Musica")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: String.self) { PlaylistView(name: $0).underBar() }
        // Filtered once per keystroke (or per library change), never on unrelated redraws.
        .onChange(of: q) { _ in refilter() }
        .onChange(of: store.tracks) { _ in refilter() }
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
                    Image(systemName: store.loading ? "arrow.triangle.2.circlepath" : "ellipsis")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Brand.raised))
                }
            }
        }
        .confirmationDialog("Togliere i brani dal telefono? Si riscaricano col prossimo aggiornamento.", isPresented: $confirmWipe, titleVisibility: .visible) {
            Button("Togli tutti", role: .destructive) { store.deleteAll() }
        }
    }

    private func refilter() {
        let n = q.trimmingCharacters(in: .whitespaces)
        found = n.isEmpty ? [] : Search.filter(store.tracks, n)
    }

    /// Tap plays this very list (all songs, or what the search left) from that song.
    @ViewBuilder private func rows(_ ts: [Track]) -> some View {
        ForEach(Array(ts.enumerated()), id: \.element.id) { i, t in
            TrackRow(track: t) { player.play(ts.map(\.id), from: i) }
                .padding(.horizontal, 20)
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
                .background(RoundedRectangle(cornerRadius: Brand.r.card, style: .continuous).fill(Brand.surface))
            } else {
                Status()
            }
            if let n = store.note { Note(icon: "info.circle", text: n) }
            if let m = player.message { Note(icon: "exclamationmark.circle", text: m) }
        }
    }
}

/// One quiet line: is the phone self-sufficient, is it filling up, is it offline. No box.
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
        if have < all { return "\(all - have) brani da scaricare" }
        return ""  // all on the phone is the normal case: nothing to say
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
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Brand.r.tile, style: .continuous).fill(Brand.surface))
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
            VStack(spacing: 0) {
                if store.playlists.isEmpty {
                    Empty(text: "Nessuna playlist.\nTocca + per crearne una.").padding(.top, 80)
                } else {
                    LazyVGrid(columns: cols, alignment: .leading, spacing: 24) {
                        ForEach(store.playlists) { p in
                            NavigationLink(value: p.name) { PlaylistCard(playlist: p, side: nil) }.buttonStyle(Press())
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .padding(.bottom, 24)
                }
            }
            .dockScroll()
        }
        .refreshable { await store.refresh() }
        .background(Brand.bg)
        .navigationTitle("Playlist")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: String.self) { PlaylistView(name: $0).underBar() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { name = ""; naming = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Brand.raised))
                }
            }
        }
        .alert("Nuova playlist", isPresented: $naming) {
            TextField("Nome", text: $name)
            Button("Annulla", role: .cancel) {}
            Button("Crea") {
                let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !n.isEmpty && store.playlist(n) == nil { store.savePlaylist(n, []); Haptic.ok() }
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
        VStack(alignment: .leading, spacing: 9) {
            Group {
                if let s = side {
                    Mosaic(ids: playlist.ids, radius: Brand.r.card).frame(width: s, height: s)
                } else {
                    Mosaic(ids: playlist.ids, radius: Brand.r.card).aspectRatio(1, contentMode: .fit)
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

/// Home's quick tile: covers on the left, name and count on the right, in a raised card.
struct PlaylistTile: View {
    @EnvironmentObject private var store: MusicStore
    let playlist: Playlist

    var body: some View {
        let ids = playlist.ids.filter { store.track($0)?.supported ?? false }
        let missing = ids.filter { !store.isDownloaded($0) }.count
        HStack(spacing: 10) {
            Mosaic(ids: playlist.ids, radius: Brand.r.small).frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Brand.fg)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    if missing > 0 { Image(systemName: "icloud").font(.system(size: 10, weight: .semibold)) }
                    Text(missing > 0 ? "\(missing) da scaricare" : "\(ids.count) brani")
                }
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundColor(Brand.dim)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Brand.r.tile, style: .continuous).fill(Brand.raised))
    }
}

struct PlaylistView: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.dismiss) private var dismiss
    let name: String
    @State private var confirmDelete = false
    @State private var editing = false
    @State private var q = ""
    @FocusState private var focused: Bool

    var body: some View {
        let p = store.playlist(name) ?? Playlist(name: name, ids: [])
        let ts = store.tracks(of: p)
        let ids = ts.map(\.id)
        let needle = q.trimmingCharacters(in: .whitespaces)
        let shown = needle.isEmpty ? ts : Search.filter(ts, needle)
        let minutes = Int(ts.reduce(0) { $0 + $1.duration } / 60)
        // Reordering only makes sense on the whole playlist, not on a filtered slice.
        let mover: ((IndexSet, Int) -> Void)? = needle.isEmpty ? { from, to in
            var next = ids
            next.move(fromOffsets: from, toOffset: to)
            store.savePlaylist(name, next)
        } : nil
        List {
            VStack(spacing: 18) {
                Mosaic(ids: p.ids, radius: Brand.r.card)
                    .frame(width: 220, height: 220)
                    .shadow(color: .black.opacity(0.55), radius: 26, y: 14)
                VStack(spacing: 4) {
                    Text(name).font(.system(size: 26, weight: .bold)).multilineTextAlignment(.center).lineLimit(2)
                    Text("\(ts.count) brani · \(minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min")")
                        .font(.system(size: 13).monospacedDigit()).foregroundColor(Brand.dim)
                    if ids.contains(where: { !store.isDownloaded($0) && (store.track($0)?.supported ?? false) }) { HereLine(ids: ids, size: 13) }
                }
                HStack(spacing: 10) {
                    Button { player.play(ids) } label: { Label("Riproduci", systemImage: "play.fill") }.buttonStyle(Pill())
                    Button { player.play(ids, shuffled: true) } label: { Label("Casuale", systemImage: "shuffle") }.buttonStyle(Pill(filled: false))
                }
                if ts.count > 1 {
                    SearchField(prompt: "Cerca nella playlist", text: $q, focus: $focused)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .background(alignment: .top) { Backdrop(track: ts.first).frame(height: 420).offset(y: -160) }
            .dockScroll()
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
                TrackRow(track: t, playlist: name, number: needle.isEmpty ? i + 1 : nil) {
                    player.play(shown.map(\.id), from: i)
                }
                .row()
            }
            .onDelete { offs in for o in offs where o < shown.count { store.removeFrom(name, shown[o].id) } }
            .onMove(perform: mover)
            if ts.isEmpty {
                Empty(text: "Vuota. Tieni premuto un brano → Aggiungi a playlist.").row()
            } else if shown.isEmpty {
                Empty(text: "Nessun brano trovato.").row()
            }
        }
        .page()
        .scrollDismissesKeyboard(.immediately)
        .environment(\.editMode, .constant(editing ? .active : .inactive))
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { q = ""; withAnimation { editing.toggle() } } label: { Label(editing ? "Fine" : "Riordina", systemImage: "arrow.up.arrow.down") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Elimina playlist", systemImage: "trash") }
                } label: {
                    Image(systemName: editing ? "checkmark" : "ellipsis")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Brand.raised))
                }
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
    @State private var local: [Track] = []
    @State private var found: [Candidate] = []
    @State private var searching = false
    @State private var error: String?
    @FocusState private var focused: Bool
    @AppStorage("musica.tab") private var tab = Pane.home.rawValue

    var body: some View {
        let needle = q.trimmingCharacters(in: .whitespaces)
        let have = Set(store.tracks.map(\.id))
        let fresh = found.filter { !have.contains($0.id) || store.adding.contains($0.id) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SearchField(prompt: "Brani, artisti, YouTube", text: $q, focus: $focused) {
                    focused = false
                    remote(needle)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                if needle.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").font(.system(size: 30, weight: .semibold)).foregroundColor(Brand.faint)
                        Text("Cerca nella tua musica e su YouTube.\nTocca un risultato di YouTube: si aggiunge e parte.")
                            .font(.system(size: 14)).foregroundColor(Brand.faint).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 70)
                }
                if !local.isEmpty {
                    SectionTitle(text: "Nella libreria", trailing: "\(local.count)").padding(.top, 16).padding(.bottom, 2)
                    ForEach(Array(local.enumerated()), id: \.element.id) { i, t in
                        TrackRow(track: t) { player.play(local.map(\.id), from: i) }.padding(.horizontal, 20)
                    }
                }
                if !needle.isEmpty {
                    Group {
                        if !store.online {
                            Footer(text: "Offline: cerco solo nella libreria.")
                        } else if !fresh.isEmpty {
                            SectionTitle(text: "Da YouTube", trailing: searching ? "…" : nil).padding(.top, 24).padding(.bottom, 2)
                            ForEach(fresh) { c in CandidateRow(c: c).padding(.horizontal, 20) }
                        } else if searching {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Cerco su YouTube…") }
                                .font(.system(size: 13)).foregroundColor(Brand.dim)
                                .frame(maxWidth: .infinity).padding(.vertical, 24)
                        } else if let e = error {
                            Footer(text: e)
                        }
                    }
                }
            }
            .padding(.bottom, 24)
            .dockScroll()
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Brand.bg)
        .navigationTitle("Cerca")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { relocal() }
        .onChange(of: q) { _ in relocal() }
        .onChange(of: store.tracks) { _ in relocal() }
        // Opening Cerca with nothing typed: the keyboard is already up.
        .onChange(of: tab) { t in if t == Pane.search.rawValue && q.isEmpty { focused = true } }
        // YouTube as you type: a short pause after the last letter, the newest query wins.
        .task(id: needle) {
            guard needle.count >= 2 else { found = []; error = nil; return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            remote(needle)
        }
    }

    private func relocal() {
        let n = q.trimmingCharacters(in: .whitespaces)
        local = n.isEmpty ? [] : Search.filter(store.tracks, n)
    }

    private func remote(_ needle: String) {
        guard !needle.isEmpty, store.online else { return }
        searching = true
        error = nil
        Task {
            let r: Result<[Candidate], Error>
            do { r = .success(try await store.search(needle)) } catch { r = .failure(error) }
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
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
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
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Brand.fg)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Brand.raised))
                }
                .buttonStyle(Press())
            }
        }
        .padding(.vertical, 6)
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
            Text(text).font(.system(size: 20, weight: .bold)).foregroundColor(Brand.fg)
            Spacer()
            if let t = trailing { Text(t).font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundColor(Brand.faint) }
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
