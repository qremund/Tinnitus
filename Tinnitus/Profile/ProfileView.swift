import SwiftUI
import TinnitusCore

struct ProfileView: View {
    @Environment(ProfileStore.self) private var store
    @AppStorage("notchWidthOctaves") private var notchWidthOctaves = NotchDesign.followMatchMinimumOctaves
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
                profileChoice
                Section {
                    EarNotchDiagrams(ears: store.ears, minimumWidthOctaves: notchWidthOctaves)
                        .padding(.vertical, 4)
                } footer: {
                    Text("Shaded areas are removed from Play and Music. Ticks mark each match's pitch.")
                }
                activeProfileSections(store.activeProfile)

                Section {
                    Toggle("Same notch in both ears", isOn: $store.sameForBothEars)
                } footer: {
                    Text(store.sameForBothEars
                         ? "Every match notches both ears, whichever ear it was for."
                         : "Each match notches its own ear. Matches for both ears notch each side.")
                }

                if store.profiles.isEmpty {
                    ContentUnavailableView(
                        "No matches yet",
                        systemImage: "waveform",
                        description: Text("Use the Match tab to measure your tinnitus.")
                    )
                } else {
                    savedMatches
                }
                filterSection
                backupSection
            }
            .navigationTitle("Notch Profile")
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
                Text(store.matchProfiles.count > 1 ? "Its matches stay saved." : "Its matches stay saved, and a new empty profile takes its place.")
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
            Picker("Profile in use", selection: Binding(get: { store.activeProfile.id }, set: { store.activeProfileID = $0 })) {
                ForEach(store.matchProfiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            Button("New Profile", systemImage: "plus") {
                newName = store.nextProfileName
                creatingProfile = true
            }
            Button("Rename Profile", systemImage: "pencil") {
                newName = store.activeProfile.name
                renamingProfile = store.activeProfile
            }
            Button("Delete Profile", systemImage: "trash", role: .destructive) {
                deletingProfile = store.activeProfile
            }
        } footer: {
            Text("Play, Music, and the match screens use this profile. It combines the matches you choose, up to \(NotchDesign.maxNotchesPerEar) per ear, with a notch for each.")
        }
    }

    // MARK: Active profile

    @ViewBuilder
    private func activeProfileSections(_ profile: MatchProfile) -> some View {
        let ears = store.ears(for: profile)
        if ears.isEmpty {
            Section {
                Text("No matches in this profile yet, so it plays unfiltered. Tap + next to a saved match below, or save a new match from the Match tab.")
                    .foregroundStyle(.secondary)
            } header: {
                sectionTitle(profile.name)
            }
        } else if store.sameForBothEars || ears.left == ears.right {
            profileEarSection("\(profile.name): Both Ears", ears.left, profile: profile)
        } else {
            profileEarSection("\(profile.name): Left Ear", ears.left, profile: profile)
            profileEarSection("\(profile.name): Right Ear", ears.right, profile: profile)
        }
    }

    /// Larger, darker than a normal list header, so each ear section stands out.
    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.title3.bold())
            .foregroundStyle(.primary)
            .textCase(nil)
            .padding(.top, 8)
    }

    private func profileEarSection(_ title: String, _ matches: [TinnitusProfile], profile: MatchProfile) -> some View {
        Section {
            if matches.isEmpty {
                Text("No matches for this ear, so it plays unfiltered.")
                    .foregroundStyle(.secondary)
            }
            ForEach(matches.sorted(by: TinnitusProfile.displayOrder)) { match in
                MatchRow(match: match, minimumWidthOctaves: notchWidthOctaves)
                    .padding(.vertical, 4)
                    .swipeActions {
                        Button("Remove") { store.unload(match.id, from: profile.id) }
                            .tint(.orange)
                    }
            }
        } header: {
            sectionTitle(title)
        } footer: {
            if !matches.isEmpty {
                Text("Swipe left to take a match out of \(profile.name). The match stays saved.")
            }
        }
    }

    // MARK: Filter and backup

    private var filterSection: some View {
        Section {
            Picker("Smallest notch", selection: $notchWidthOctaves) {
                Text("Follow my match").tag(NotchDesign.followMatchMinimumOctaves)
                Text("1/2 octave").tag(0.5)
                Text("1 octave").tag(1.0)
            }
        } header: {
            Text("Filter")
        } footer: {
            Text("Each notch is twice your matched width, so the edges of a hiss are cut deeply, but never more than 1/2 octave wider than the match. Follow my match keeps notches that tight, with at least 1/6 octave for a pure tone. 1 octave is the width used in most published studies, and 1/2 octave is in between.")
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
        let profile = store.activeProfile
        let sorted = store.sortedMatches
        return Section {
            ForEach(sorted) { match in
                HStack(spacing: 6) {
                    MatchRow(match: match, minimumWidthOctaves: notchWidthOctaves)
                    loadButton(match, profile: profile)
                }
                .padding(.vertical, 4)
            }
            .onDelete { offsets in
                store.delete(ids: offsets.map { sorted[$0].id })
            }
        } header: {
            Text("Saved matches")
        } footer: {
            Text("Tap + to load a match into \(profile.name), or the check mark to take it out. Swipe left to delete. You can undo a delete.")
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
