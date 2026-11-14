import SwiftUI
import TinnitusCore

/// Picks the profile whose matches set the notches, in Play and Music. Profiles are made and edited
/// on the Notch Profile tab and from the match screens.
struct ProfilePicker: View {
    @Environment(ProfileStore.self) private var store

    var body: some View {
        HStack {
            Text("Profile")
            Spacer()
            Menu {
                ProfileMenuItems()
            } label: {
                HStack(spacing: 4) {
                    Text(store.activeProfile.name)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                }
            }
            .accessibilityLabel("Profile")
            .accessibilityValue(store.activeProfile.name)
        }
    }
}

/// Menu entries for choosing the active profile.
struct ProfileMenuItems: View {
    @Environment(ProfileStore.self) private var store

    var body: some View {
        Section("Profiles") {
            ForEach(store.matchProfiles) { profile in
                Button {
                    store.activeProfileID = profile.id
                } label: {
                    let count = store.matches(in: profile).count
                    let detail = "\(count) match\(count == 1 ? "" : "es")"
                    if store.activeProfile.id == profile.id {
                        Label("\(profile.name) · \(detail)", systemImage: "checkmark")
                    } else {
                        Text("\(profile.name) · \(detail)")
                    }
                }
            }
        }
    }
}
