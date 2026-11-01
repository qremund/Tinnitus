import SwiftUI
import TinnitusCore

struct ProfileView: View {
    @Environment(ProfileStore.self) private var store
    @AppStorage("notchWidthOctaves") private var notchWidthOctaves = 1.0
    @State private var renaming: TinnitusProfile?
    @State private var newName = ""

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            List {
                let ears = store.ears
                if !ears.isEmpty {
                    Section {
                        Toggle("Same notch in both ears", isOn: $store.sameForBothEars)
                    } footer: {
                        Text(store.sameForBothEars
                             ? "Both ears use the median of your last three sessions, whichever ear they were for."
                             : "Each ear uses its own sessions. Sessions for both ears count toward each side.")
                    }

                    if store.sameForBothEars || ears.left == ears.right {
                        earSection("Both ears", ears.left)
                    } else {
                        earSection("Left ear", ears.left)
                        earSection("Right ear", ears.right)
                    }
                } else {
                    ContentUnavailableView(
                        "No profile yet",
                        systemImage: "waveform",
                        description: Text("Use the Match tab to measure your tinnitus.")
                    )
                }

                if !store.profiles.isEmpty {
                    Section {
                        ForEach(store.profiles) { profile in
                            VStack(alignment: .leading) {
                                Text(Format.matchTitle(profile)).font(.headline)
                                if profile.name != nil {
                                    Text(profile.date, format: .dateTime.month().day().hour().minute())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text("\(profile.ear.shortTitle): \(Format.frequency(profile.centerFrequencyHz)), \(Format.bandwidth(profile.bandwidthOctaves)), \(Format.level(profile.sensationLevelDB)) above threshold")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                if !profile.notes.isEmpty {
                                    Text(profile.notes).font(.caption)
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button("Rename") {
                                    newName = profile.name ?? ""
                                    renaming = profile
                                }
                                .tint(.blue)
                            }
                        }
                        .onDelete(perform: store.delete)
                    } header: {
                        Text("Saved matches")
                    } footer: {
                        Text("Swipe right to rename, left to delete. Choose which match each ear uses in Play or Music.")
                    }
                }
            }
            .navigationTitle("Profile")
            .alert("Rename match", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") {
                    if let profile = renaming { store.rename(profile.id, to: newName) }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    @ViewBuilder
    private func earSection(_ title: String, _ profile: TinnitusProfile?) -> some View {
        Section(title) {
            if let profile {
                LabeledContent("Pitch", value: Format.frequency(profile.centerFrequencyHz))
                LabeledContent("Width", value: Format.bandwidth(profile.bandwidthOctaves))
                LabeledContent("Loudness", value: "\(Format.level(profile.sensationLevelDB)) above threshold")
                LabeledContent("Notch removes", value: Format.notchRange(centerHz: profile.centerFrequencyHz, widthOctaves: notchWidthOctaves))
                if profile.notes.hasPrefix("Median") {
                    Text(profile.notes).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("No sessions for this ear yet, so it plays unfiltered. Match it in the Match tab.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
