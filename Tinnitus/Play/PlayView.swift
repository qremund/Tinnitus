import SwiftUI

/// Placeholder until filtered sleep sounds arrive in step 3.
struct PlayView: View {
    @Environment(ProfileStore.self) private var store

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Sleep sounds coming soon", systemImage: "moon.zzz")
            } description: {
                Text(store.current == nil
                    ? "Start with the Match tab. Filtered white noise and ambient sounds come next."
                    : "Your profile is saved. Filtered white noise and ambient sounds come next.")
            }
            .navigationTitle("Play")
        }
    }
}
