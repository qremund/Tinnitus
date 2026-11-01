import SwiftUI
import TinnitusCore

/// Picks the profile whose matches set the notches, in Play and Music. Profiles are made and edited
/// on the Profile tab and from the match screens.
struct ProfilePicker: View {
    @Environment(ProfileStore.self) private var store

    var body: some View {
        if !store.profiles.isEmpty {
            HStack {
                Text("Profile")
                Spacer()
                Menu {
                    ProfileMenuItems()
                } label: {
                    HStack(spacing: 4) {
                        Text(store.activeProfile?.name ?? "Automatic")
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                    }
                }
                .accessibilityLabel("Profile")
                .accessibilityValue(store.activeProfile?.name ?? "Automatic")
            }
        }
    }
}

/// Menu entries for choosing the active profile: Automatic, then each saved profile.
struct ProfileMenuItems: View {
    @Environment(ProfileStore.self) private var store

    var body: some View {
        Button {
            store.activeProfileID = nil
        } label: {
            if store.activeProfile == nil {
                Label("Automatic (recent median)", systemImage: "checkmark")
            } else {
                Text("Automatic (recent median)")
            }
        }
        if !store.matchProfiles.isEmpty {
            Section("Profiles") {
                ForEach(store.matchProfiles) { profile in
                    Button {
                        store.activeProfileID = profile.id
                    } label: {
                        let count = store.matches(in: profile).count
                        let detail = "\(count) match\(count == 1 ? "" : "es")"
                        if store.activeProfileID == profile.id {
                            Label("\(profile.name) · \(detail)", systemImage: "checkmark")
                        } else {
                            Text("\(profile.name) · \(detail)")
                        }
                    }
                }
            }
        }
    }
}
