import SwiftUI
import TinnitusCore

struct ProfileView: View {
    @Environment(ProfileStore.self) private var store
    @AppStorage("notchWidthOctaves") private var notchWidthOctaves = 1.0
    @State private var renaming: TinnitusProfile?
    @State private var renamingProfile: MatchProfile?
    @State private var newName = ""
    @State private var creatingProfile = false
    @State private var deletingProfile: MatchProfile?
    @State private var problem: String?

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            List {
                if store.profiles.isEmpty {
                    ContentUnavailableView(
                        "No matches yet",
                        systemImage: "waveform",
                        description: Text("Use the Match tab to measure your tinnitus.")
                    )
                } else {
                    profileChoice
                    if let profile = store.activeProfile {
                        activeProfileSections(profile)
                    } else {
                        automaticSections
                    }

                    Section {
                        Toggle("Same notch in both ears", isOn: $store.sameForBothEars)
                    } footer: {
                        Text(store.sameForBothEars
                             ? "Every match notches both ears, whichever ear it was for."
                             : "Each match notches its own ear. Matches for both ears notch each side.")
                    }

                    savedMatches
                }
            }
            .navigationTitle("Profile")
            .alert("Rename match", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") {
                    if let match = renaming { store.rename(match.id, to: newName) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename profile", isPresented: Binding(get: { renamingProfile != nil }, set: { if !$0 { renamingProfile = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") {
                    if let profile = renamingProfile { store.renameProfile(profile.id, to: newName) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("New profile", isPresented: $creatingProfile) {
                TextField("Name", text: $newName)
                Button("Create") { store.createProfile(named: newName) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Then load saved matches into it below, or save new ones from the Match tab.")
            }
            .confirmationDialog(
                "Delete \(deletingProfile?.name ?? "profile")?",
                isPresented: Binding(get: { deletingProfile != nil }, set: { if !$0 { deletingProfile = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Profile", role: .destructive) {
                    if let profile = deletingProfile { store.deleteProfile(profile.id) }
                }
            } message: {
                Text("Its matches stay saved.")
            }
            .alert("Can't add match", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
        }
    }

    // MARK: Choosing a profile

    private var profileChoice: some View {
        Section {
            Picker("Profile in use", selection: Binding(get: { store.activeProfileID }, set: { store.activeProfileID = $0 })) {
                Text("Automatic").tag(UUID?.none)
                ForEach(store.matchProfiles) { profile in
                    Text(profile.name).tag(UUID?.some(profile.id))
                }
            }
            Button("New Profile", systemImage: "plus") {
                newName = store.nextProfileName
                creatingProfile = true
            }
        } footer: {
            Text(store.activeProfile == nil
                 ? "Automatic uses the median of each ear's last three matches. A profile combines the matches you choose, up to \(NotchDesign.maxNotchesPerEar) per ear, with a notch for each."
                 : "Play, Music, and the match screens use this profile.")
        }
    }

    // MARK: Active profile

    @ViewBuilder
    private func activeProfileSections(_ profile: MatchProfile) -> some View {
        let ears = store.ears(for: profile)
        if ears.isEmpty {
            Section(profile.name) {
                Text("No matches in this profile yet, so it plays unfiltered. Tap + next to a saved match below, or save a new match from the Match tab.")
                    .foregroundStyle(.secondary)
            }
        } else if store.sameForBothEars || ears.left == ears.right {
            profileEarSection("\(profile.name): both ears", ears.left, profile: profile)
        } else {
            profileEarSection("\(profile.name): left ear", ears.left, profile: profile)
            profileEarSection("\(profile.name): right ear", ears.right, profile: profile)
        }
        Section {
            Button("Rename Profile", systemImage: "pencil") {
                newName = profile.name
                renamingProfile = profile
            }
            Button("Delete Profile", systemImage: "trash", role: .destructive) {
                deletingProfile = profile
            }
        }
    }

    private func profileEarSection(_ title: String, _ matches: [TinnitusProfile], profile: MatchProfile) -> some View {
        Section {
            if matches.isEmpty {
                Text("No matches for this ear, so it plays unfiltered.")
                    .foregroundStyle(.secondary)
            }
            ForEach(matches) { match in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Format.matchTitle(match)).font(.headline)
                    Text(Format.matchSummary(match))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button("Remove") { store.unload(match.id, from: profile.id) }
                        .tint(.orange)
                }
            }
            if !matches.isEmpty {
                LabeledContent("Notch removes", value: Format.earNotch(matches.map(\.centerFrequencyHz), widthOctaves: notchWidthOctaves))
            }
        } header: {
            Text(title)
        } footer: {
            if !matches.isEmpty {
                Text("Swipe left to take a match out of \(profile.name). The match stays saved.")
            }
        }
    }

    // MARK: Automatic

    @ViewBuilder
    private var automaticSections: some View {
        let ears = store.automaticEars
        if store.sameForBothEars || ears.left == ears.right {
            earSection("Both ears", ears.left.first)
        } else {
            earSection("Left ear", ears.left.first)
            earSection("Right ear", ears.right.first)
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

    // MARK: Saved matches

    private var savedMatches: some View {
        Section {
            ForEach(store.profiles) { match in
                HStack(alignment: .top) {
                    VStack(alignment: .leading) {
                        Text(Format.matchTitle(match)).font(.headline)
                        if match.name != nil {
                            Text(match.date, format: .dateTime.month().day().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(match.ear.shortTitle): \(Format.frequency(match.centerFrequencyHz)), \(Format.bandwidth(match.bandwidthOctaves)), \(Format.level(match.sensationLevelDB)) above threshold")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if !match.notes.isEmpty {
                            Text(match.notes).font(.caption)
                        }
                    }
                    Spacer()
                    if let profile = store.activeProfile {
                        loadButton(match, profile: profile)
                    }
                }
                .swipeActions(edge: .leading) {
                    Button("Rename") {
                        newName = match.name ?? ""
                        renaming = match
                    }
                    .tint(.blue)
                }
            }
            .onDelete(perform: store.delete)
        } header: {
            Text("Saved matches")
        } footer: {
            Text(store.activeProfile.map { "Tap + to load a match into \($0.name), or the check mark to take it out. Swipe right to rename, left to delete." }
                 ?? "Swipe right to rename, left to delete. Pick or make a profile above to combine matches.")
        }
    }

    private func loadButton(_ match: TinnitusProfile, profile: MatchProfile) -> some View {
        let loaded = profile.contains(match.id)
        return Button {
            if loaded {
                store.unload(match.id, from: profile.id)
            } else {
                problem = store.load(match.id, into: profile.id)
            }
        } label: {
            Image(systemName: loaded ? "checkmark.circle.fill" : "plus.circle")
                .font(.title2)
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(loaded ? "Remove \(Format.matchTitle(match)) from \(profile.name)" : "Add \(Format.matchTitle(match)) to \(profile.name)")
    }
}
