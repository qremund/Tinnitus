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
    @Environment(ProfileStore.self) private var store

    var body: some View {
        TabView {
            PlayView()
                .tabItem { Label("Play", systemImage: "play.circle") }
            MusicView()
                .tabItem { Label("Music", systemImage: "music.note") }
            MatchHomeView()
                .tabItem { Label("Match", systemImage: "waveform.badge.magnifyingglass") }
            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
        }
        .alert("Saved data problem", isPresented: Binding(get: { store.loadProblem != nil }, set: { if !$0 { store.loadProblem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.loadProblem ?? "")
        }
    }
}
