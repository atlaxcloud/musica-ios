// Musica: Matteo's library from manager.atlax.cloud as a native iPhone app,
// built to work with no network at all (the gym): playlists kept offline on
// the phone, played with the screen locked, driven from the lock screen and
// the headphones. Its own IPA (cloud.atlax.musica), nothing shared with Atlax.
import SwiftUI

@main
struct MusicaApp: App {
    @StateObject private var store = MusicStore.shared
    @StateObject private var player = MusicPlayer.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(player)
                .preferredColorScheme(.dark)
                .tint(Brand.fg)
        }
    }
}
