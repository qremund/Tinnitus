import SwiftUI

@main
struct TinnitusApp: App {
    @State private var store = ProfileStore()
    @State private var audio = TestToneEngine()
    @State private var player = SleepPlayer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(audio)
                .environment(player)
        }
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            PlayView()
                .tabItem { Label("Play", systemImage: "play.circle") }
            MatchFlowView()
                .tabItem { Label("Match", systemImage: "waveform.badge.magnifyingglass") }
            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
