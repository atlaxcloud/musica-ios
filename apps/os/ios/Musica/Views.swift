// Musica: the screens. Libreria, Playlist, Cerca, Scaricati under one header,
// the mini player docked at the bottom, the full player over everything.
import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case library = "Libreria", playlists = "Playlist", search = "Cerca", downloads = "Scaricati"
    var id: String { rawValue }
}

struct RootView: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.scenePhase) private var phase
    @AppStorage("musica.pane") private var pane = Pane.library.rawValue
    @State private var login = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $pane) {
                    ForEach(Pane.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                Banner(login: $login)
                switch Pane(rawValue: pane) ?? .library {
                case .library: LibraryView()
                case .playlists: PlaylistsView()
                case .search: SearchView()
                case .downloads: DownloadsView()
                }
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Musica")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { Task { await store.refresh() } } label: { Label("Aggiorna", systemImage: "arrow.clockwise") }
                        if store.needsLogin {
                            Button { login = true } label: { Label("Accedi", systemImage: "person.crop.circle") }
                        } else {
                            Button(role: .destructive) { store.signOut() } label: { Label("Esci", systemImage: "rectangle.portrait.and.arrow.right") }
                        }
                    } label: {
                        Image(systemName: store.loading ? "arrow.triangle.2.circlepath" : "ellipsis.circle")
                    }
                }
            }
            .navigationDestination(for: String.self) { PlaylistView(name: $0) }
            // While open, the library stays current with the PC every few minutes (new songs get saved too).
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 300_000_000_000)
                    if phase == .active { await store.refresh() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if player.current != nil { MiniPlayer() }
            }
        }
        .fullScreenCover(isPresented: $player.full) { FullPlayer() }
        .sheet(isPresented: $login) { LoginSheet() }
        .onAppear { if store.needsLogin && store.online { login = true } }
        .onChange(of: store.needsLogin) { need in if need && store.online { login = true } }
        .onChange(of: phase) { p in
            if p == .active { Task { await store.refresh() }; store.pump() }
            if p == .background { player.save(force: true) }
        }
    }
}

/// One line on where we stand: offline, PC off, signed out, a note from the server.
struct Banner: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: MusicPlayer
    @Binding var login: Bool

    var body: some View {
        VStack(spacing: 6) {
            if store.needsLogin {
                HStack(spacing: 12) {
                    Text("Accedi una volta con Atlax ID: poi la musica scaricata va anche senza rete.")
                        .font(.system(size: 13)).foregroundColor(Brand.dim)
                    Button("Accedi") { login = true }.buttonStyle(Pill()).frame(width: 96)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: Brand.r.tile, style: .continuous).fill(Brand.surface))
            } else {
                Status()
            }
            if let n = store.note { line("info.circle", n) }
            if let m = player.message { line("exclamationmark.circle", m) }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private func line(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            Text(text).font(.system(size: 13)).lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundColor(Brand.dim)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Brand.r.small, style: .continuous).fill(Brand.surface))
    }
}

/// One quiet line under the tabs: is the phone self-sufficient, is it filling up, is it offline.
/// No box, no colour: it only says what changes what you can play.
struct Status: View {
    @EnvironmentObject private var store: MusicStore

    var body: some View {
        let all = store.tracks.filter(\.supported).count
        let have = store.downloadedTracks.count
        let busy = !store.inFlight.isEmpty || !store.pending.isEmpty
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(store.online ? Brand.fg.opacity(have >= all ? 0.9 : 0.5) : Brand.faint).frame(width: 6, height: 6)
                Text(text(all: all, have: have, busy: busy))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundColor(Brand.dim)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if busy && store.online && all > 0 {
                ProgressView(value: Double(have), total: Double(all))
                    .tint(Brand.fg.opacity(0.6))
                    .scaleEffect(x: 1, y: 0.5, anchor: .center)
            }
        }
        .padding(.horizontal, 4)
        .animation(.easeOut(duration: 0.2), value: busy)
    }

    private func text(all: Int, have: Int, busy: Bool) -> String {
        if !store.online { return "Offline · \(have) brani sul telefono" }
        if !store.pcOn && store.syncedAt != nil && have < all { return "PC spento · \(have) di \(all) sul telefono" }
        if busy { return "Scarico sul telefono · \(have) di \(all)" }
        return all == 0 ? "" : "Tutto sul telefono · \(have) brani"
    }
}

struct LibraryView: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: MusicPlayer

    var body: some View {
        let ids = store.tracks.map(\.id)
        List {
            if store.tracks.isEmpty {
                Empty(text: store.loading ? "Carico la libreria…" : "La libreria è vuota. Cerca un brano per aggiungerlo.").row()
            } else {
                HStack(spacing: 10) {
                    Button { player.play(ids) } label: { Label("Riproduci", systemImage: "play.fill") }.buttonStyle(Pill())
                    Button { player.play(ids, shuffled: true) } label: { Label("Casuale", systemImage: "shuffle") }.buttonStyle(Pill(filled: false))
                }
                .row()
                ForEach(Array(store.tracks.enumerated()), id: \.element.id) { i, t in
                    TrackRow(track: t) { player.play(ids, from: i) }.row()
                }
                Footer(text: "\(store.tracks.count) brani" + (store.syncedAt.map { " · aggiornata alle " + $0.formatted(date: .omitted, time: .shortened) } ?? "")).row()
            }
        }
        .page()
        .refreshable { await store.refresh() }
    }
}

struct PlaylistsView: View {
    @EnvironmentObject private var store: MusicStore
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        List {
            Button { name = ""; naming = true } label: { Label("Nuova playlist", systemImage: "plus") }
                .buttonStyle(Pill(filled: false)).row()
            ForEach(store.playlists) { p in
                let have = p.ids.filter { store.isDownloaded($0) }.count
                NavigationLink(value: p.name) {
                    HStack(spacing: 12) {
                        CoverView(track: p.ids.first.flatMap { store.track($0) }, size: 52, radius: Brand.r.tile)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.name).font(.system(size: 16, weight: .semibold)).foregroundColor(Brand.fg).lineLimit(1)
                            Text("\(p.ids.count) brani · \(have) sul telefono").font(.system(size: 12.5)).foregroundColor(Brand.dim)
                        }
                        Spacer(minLength: 8)
                        if have < p.ids.count {
                            Image(systemName: "icloud").font(.system(size: 12)).foregroundColor(Brand.faint)
                        }
                    }
                }
                .row()
            }
            if store.playlists.isEmpty { Empty(text: "Nessuna playlist.").row() }
        }
        .page()
        .refreshable { await store.refresh() }
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

struct PlaylistView: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.dismiss) private var dismiss
    let name: String
    @State private var confirmDelete = false

    var body: some View {
        let p = store.playlist(name) ?? Playlist(name: name, ids: [])
        let ts = store.tracks(of: p)
        let ids = ts.map(\.id)
        let have = ids.filter { store.isDownloaded($0) }.count
        let missing = ts.filter { !store.isDownloaded($0.id) && $0.supported }.map(\.id)
        List {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(ts.count) brani · \(mmss(ts.reduce(0) { $0 + $1.duration })) · \(have) sul telefono")
                    .font(.system(size: 13)).foregroundColor(Brand.dim)
                HStack(spacing: 10) {
                    Button { player.play(ids) } label: { Label("Riproduci", systemImage: "play.fill") }.buttonStyle(Pill())
                    Button { player.play(ids, shuffled: true) } label: { Label("Casuale", systemImage: "shuffle") }.buttonStyle(Pill(filled: false))
                }
                if !ids.isEmpty && (missing.contains { store.pending.contains($0) || store.inFlight.contains($0) }) {
                    Text(store.online ? "Sul telefono \(have) di \(ids.count)" : "Offline · \(have) di \(ids.count) sul telefono")
                        .font(.system(size: 12).monospacedDigit()).foregroundColor(Brand.dim)
                }
            }
            .row()
            ForEach(Array(ts.enumerated()), id: \.element.id) { i, t in
                TrackRow(track: t, playlist: name) { player.play(ids, from: i) }.row()
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
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                EditButton()
                Menu {
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Elimina playlist", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .confirmationDialog("Eliminare \(name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Elimina playlist", role: .destructive) { store.deletePlaylist(name); dismiss() }
        }
    }
}

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
        List {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(Brand.faint)
                TextField("Brano, artista, album", text: $q)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit { remote() }
                if !q.isEmpty {
                    Button { q = ""; found = [] } label: { Image(systemName: "xmark.circle.fill").foregroundColor(Brand.faint) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: Brand.r.small, style: .continuous).fill(Brand.surface))
            .row()
            if !local.isEmpty {
                Header(text: "Nella libreria").row()
                ForEach(Array(local.enumerated()), id: \.element.id) { i, t in
                    TrackRow(track: t) { player.play(ids, from: i) }.row()
                }
            }
            if !needle.isEmpty {
                if !store.online {
                    Footer(text: "Offline: cerco solo nella libreria.").row()
                } else if searching {
                    HStack { Spacer(); ProgressView(); Spacer() }.row()
                } else if let e = error {
                    Footer(text: e).row()
                } else if found.isEmpty {
                    Button { remote() } label: { Label("Cerca su YouTube", systemImage: "globe") }.buttonStyle(Pill(filled: false)).row()
                } else {
                    Header(text: "Da aggiungere").row()
                    ForEach(found) { c in CandidateRow(c: c) { found.removeAll { $0.id == c.id } }.row() }
                }
            }
        }
        .page()
        .scrollDismissesKeyboard(.interactively)
    }

    private func remote() {
        let needle = q.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty, store.online, !searching else { return }
        focused = false
        searching = true
        error = nil
        Task {
            defer { searching = false }
            do {
                found = try await store.search(needle).found
                if found.isEmpty { error = "Nessun risultato da aggiungere." }
            } catch MusicError.auth {
                error = "Serve l'accesso."
            } catch MusicError.pcOff {
                error = "Il PC è spento: la ricerca passa da lì."
            } catch {
                self.error = "Ricerca non riuscita."
            }
        }
    }
}

struct CandidateRow: View {
    @EnvironmentObject private var store: MusicStore
    let c: Candidate
    let added: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: c.thumb)) { img in img.resizable().scaledToFill() } placeholder: { Rectangle().fill(Brand.raised) }
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: Brand.r.small, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(c.title).font(.system(size: 15)).foregroundColor(Brand.fg).lineLimit(1)
                Text([c.channel, c.duration > 0 ? mmss(c.duration) : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12.5)).foregroundColor(Brand.dim).lineLimit(1)
            }
            Spacer(minLength: 8)
            if store.adding.contains(c.id) {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Haptic.tap()
                    Task { if await store.add(c) { Haptic.ok(); added() } }
                } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 24)).foregroundColor(Brand.fg)
                }
                .buttonStyle(Press())
            }
        }
    }
}

struct DownloadsView: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: MusicPlayer
    @State private var confirm = false

    var body: some View {
        let ts = store.downloadedTracks
        let ids = ts.map(\.id)
        List {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(ts.count) brani · \(megabytes(store.bytes)) sul telefono")
                    .font(.system(size: 13)).foregroundColor(Brand.dim)
                if store.downloading != nil || !store.pending.isEmpty {
                    ProgressView(value: Double(store.done), total: Double(max(store.total, 1))).tint(Brand.fg)
                    HStack {
                        Text(store.online ? "Scarico \(min(store.done + 1, max(store.total, 1))) di \(max(store.total, 1))" : "In pausa: niente rete")
                            .font(.system(size: 12)).foregroundColor(Brand.dim)
                        Spacer()
                        Button("Annulla") { store.cancelDownloads() }.font(.system(size: 13, weight: .semibold)).buttonStyle(.plain)
                    }
                }
                if !ts.isEmpty {
                    HStack(spacing: 10) {
                        Button { player.play(ids) } label: { Label("Riproduci", systemImage: "play.fill") }.buttonStyle(Pill())
                        Button { player.play(ids, shuffled: true) } label: { Label("Casuale", systemImage: "shuffle") }.buttonStyle(Pill(filled: false))
                    }
                }
            }
            .row()
            ForEach(Array(ts.enumerated()), id: \.element.id) { i, t in
                TrackRow(track: t) { player.play(ids, from: i) }.row()
            }
            .onDelete { offs in for o in offs { store.delete(ts[o].id) } }
            if ts.isEmpty {
                Empty(text: store.online ? "Scarico la libreria sul telefono…" : "Niente sul telefono: si scarica appena c'è rete.").row()
            } else {
                Button(role: .destructive) { confirm = true } label: { Text("Elimina tutti") }.buttonStyle(Pill(filled: false)).row()
            }
        }
        .page()
        .confirmationDialog("Eliminare tutti i brani scaricati?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Elimina tutti", role: .destructive) { store.deleteAll() }
        }
    }
}

struct Empty: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 14)).foregroundColor(Brand.dim)
            .frame(maxWidth: .infinity, alignment: .center).multilineTextAlignment(.center)
            .padding(.vertical, 40)
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
