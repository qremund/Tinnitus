import SwiftUI

@main
struct TinnitusApp: App {
    @State private var store = ProfileStore()
    @State private var audio = TestToneEngine()
    @State private var player = SleepPlayer()
    @State private var library = MusicLibrary()
    @State private var music = MusicPlayer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(audio)
                .environment(player)
                .environment(library)
                .environment(music)
                .onAppear {
                    // Only one thing plays at a time.
                    player.onWillPlay = { [music] in music.pause() }
                    music.onWillPlay = { [player] in player.pause() }
                }
        }
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            PlayView()
                .tabItem { Label("Play", systemImage: "play.circle") }
            MusicView()
                .tabItem { Label("Music", systemImage: "music.note") }
            MatchFlowView()
                .tabItem { Label("Match", systemImage: "waveform.badge.magnifyingglass") }
            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
