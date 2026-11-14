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
    @State private var undoDismissal: Task<Void, Never>?

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
                    filterSection
                    backupSection
                }
            }
            .navigationTitle("Profile")
            .safeAreaInset(edge: .bottom) {
                if let deletion = store.recentDeletion {
                    undoBanner(deletion)
                }
            }
            .onChange(of: store.recentDeletion?.id) {
                // Offer undo for a few seconds after each delete.
                undoDismissal?.cancel()
                guard store.recentDeletion != nil else { return }
                undoDismissal = Task {
                    try? await Task.sleep(for: .seconds(8))
                    if !Task.isCancelled { store.clearRecentDeletion() }
                }
            }
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
                 ? "Automatic groups each ear's recent matches by pitch and notches the median of each group, so two different pitches each get a notch. A profile combines the matches you choose, up to \(NotchDesign.maxNotchesPerEar) per ear, with a notch for each."
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
                LabeledContent("Notch removes", value: Format.earNotch(matches: matches, minimumWidthOctaves: notchWidthOctaves))
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
            earSection("Both ears", ears.left)
        } else {
            earSection("Left ear", ears.left)
            earSection("Right ear", ears.right)
        }
    }

    /// One ear's automatic notches: one per group of matches with a similar pitch.
    @ViewBuilder
    private func earSection(_ title: String, _ groups: [TinnitusProfile]) -> some View {
        Section {
            if groups.isEmpty {
                Text("No sessions for this ear yet, so it plays unfiltered. Match it in the Match tab.")
                    .foregroundStyle(.secondary)
            }
            ForEach(groups) { profile in
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Pitch", value: Format.frequency(profile.centerFrequencyHz))
                    LabeledContent("Width", value: Format.bandwidth(profile.bandwidthOctaves))
                    LabeledContent("Loudness", value: "\(Format.level(profile.sensationLevelDB)) above threshold")
                    if profile.notes.hasPrefix("Median") {
                        Text(profile.notes).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !groups.isEmpty {
                LabeledContent("Notch removes", value: Format.earNotch(matches: groups, minimumWidthOctaves: notchWidthOctaves))
            }
        } header: {
            Text(title)
        } footer: {
            if groups.count > 1 {
                Text("Your recent matches here have \(groups.count) different pitches, so each gets its own notch.")
            }
        }
    }

    // MARK: Filter and backup

    private var filterSection: some View {
        Section {
            Picker("Smallest notch", selection: $notchWidthOctaves) {
                Text("1 octave").tag(1.0)
                Text("1/2 octave").tag(0.5)
            }
        } header: {
            Text("Filter")
        } footer: {
            Text("Each notch is your matched width plus 1/2 octave, so the edges of a hiss are cut deeply, and never narrower than this. 1 octave is the width used in most published studies. 1/2 octave keeps more of the sound around a pure tone.")
        }
    }

    private var backupSection: some View {
        Section {
            ShareLink(item: store.export, preview: SharePreview("Tinnitus matches")) {
                Label("Export Matches", systemImage: "square.and.arrow.up")
            }
        } footer: {
            Text("Saves every match and profile as a file, for example to Files or iCloud Drive, as a backup.")
        }
    }

    private func undoBanner(_ deletion: ProfileStore.RecentDeletion) -> some View {
        let profileNames = store.matchProfiles.filter { deletion.memberships[$0.id] != nil }.map(\.name)
        let detail = profileNames.isEmpty ? "" : " Also taken out of \(profileNames.formatted(.list(type: .and)))."
        return HStack(spacing: 12) {
            Text("Deleted \(deletion.title).\(detail)")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Undo") {
                undoDismissal?.cancel()
                store.undoDelete()
            }
            .font(.callout.bold())
        }
        .padding()
        .background(.bar)
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
            Text(store.activeProfile.map { "Tap + to load a match into \($0.name), or the check mark to take it out. Swipe right to rename, left to delete. You can undo a delete." }
                 ?? "Swipe right to rename, left to delete. You can undo a delete. Pick or make a profile above to combine matches.")
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
