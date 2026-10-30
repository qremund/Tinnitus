import SwiftUI
import TinnitusCore

struct ProfileView: View {
    @Environment(ProfileStore.self) private var store
    @AppStorage("notchWidthOctaves") private var notchWidthOctaves = 1.0

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
                    Section("Sessions") {
                        ForEach(store.profiles) { profile in
                            VStack(alignment: .leading) {
                                Text(profile.date, format: .dateTime.month().day().hour().minute())
                                Text("\(profile.ear.shortTitle): \(Format.frequency(profile.centerFrequencyHz)), \(Format.bandwidth(profile.bandwidthOctaves)), \(Format.level(profile.sensationLevelDB)) above threshold")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                if !profile.notes.isEmpty {
                                    Text(profile.notes).font(.caption)
                                }
                            }
                        }
                        .onDelete(perform: store.delete)
                    }
                }
            }
            .navigationTitle("Profile")
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
