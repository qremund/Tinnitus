import SwiftUI
import TinnitusCore

struct ProfileView: View {
    @Environment(ProfileStore.self) private var store
    @AppStorage("notchWidthOctaves") private var notchWidthOctaves = 1.0

    var body: some View {
        NavigationStack {
            List {
                if let profile = store.current {
                    Section {
                        LabeledContent("Pitch", value: Format.frequency(profile.centerFrequencyHz))
                        LabeledContent("Width", value: Format.bandwidth(profile.bandwidthOctaves))
                        LabeledContent("Loudness", value: "\(Format.level(profile.sensationLevelDB)) above threshold")
                        LabeledContent("Ear", value: profile.ear.title)
                    } header: {
                        Text("Your tinnitus")
                    } footer: {
                        Text(store.profiles.count > 1 ? "Median of your last \(min(store.profiles.count, 3)) sessions." : "From one session. Match again on another day for a steadier result.")
                    }

                    Section("Notch filter") {
                        let edges = PitchMatching.notchEdges(centerHz: profile.centerFrequencyHz, widthOctaves: notchWidthOctaves)
                        LabeledContent("Removes", value: "\(Format.frequency(edges.low)) to \(Format.frequency(edges.high))")
                        LabeledContent("Width", value: Format.bandwidth(notchWidthOctaves))
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
                                Text("\(Format.frequency(profile.centerFrequencyHz)), \(Format.bandwidth(profile.bandwidthOctaves)), \(Format.level(profile.sensationLevelDB)) above threshold")
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
}
