import SwiftUI
import TinnitusCore

/// The four interchangeable layouts of the one-screen tuner.
enum TunerLayout: String, CaseIterable, Identifiable {
    case sliders, pad, band, dial

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sliders: "Four sliders"
        case .pad: "Pitch and width pad"
        case .band: "Drag the band"
        case .dial: "Two dials"
        }
    }

    var detail: String {
        switch self {
        case .sliders: "Everything at once"
        case .pad: "Drag pitch and width"
        case .band: "See the shape you match"
        case .dial: "Pitch and width dials"
        }
    }

    var systemImage: String {
        switch self {
        case .sliders: "slider.horizontal.3"
        case .pad: "scope"
        case .band: "waveform.path"
        case .dial: "dial.medium"
        }
    }
}

/// Tune pitch, width, loudness, and ear on one screen while the test sound plays, then accept.
struct TunerView: View {
    @Environment(TestToneEngine.self) private var audio
    @Environment(ProfileStore.self) private var store
    @Environment(SleepPlayer.self) private var player
    @Environment(MusicPlayer.self) private var music
    @Environment(\.scenePhase) private var scenePhase
    let layout: TunerLayout
    @State private var model: TunerModel?
    @State private var savedMessage: String?
    @State private var savedTitle = "Match saved"
    /// Where to go after "Save changes?" is answered: another match, or a new one.
    @State private var pendingSelection: TunerModel.Selection?
    /// Go there once the save in progress finishes.
    @State private var afterSave: TunerModel.Selection?
    @State private var creatingProfile = false
    @State private var newProfileName = ""

    /// Every saved match, so the tuner can start from the newest one and know your threshold near each pitch.
    private var allMatches: EarProfiles {
        EarProfiles.combining(store.profiles, sameForBothEars: false)
    }

    /// The active profile's matches, which the diagrams show and which can play together.
    private var profileMatches: [TinnitusProfile] {
        store.matches(in: store.activeProfile)
    }

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(layout.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                profileMenu
            }
        }
        .alert("New profile", isPresented: $creatingProfile) {
            TextField("Name", text: $newProfileName)
            Button("Create") { store.createProfile(named: newProfileName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Matches you save here will be added to it.")
        }
        .onChange(of: profileMatches) {
            model?.setProfileMatches(profileMatches)
        }
        .alert(savedTitle, isPresented: Binding(get: { savedMessage != nil }, set: { if !$0 { savedMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(savedMessage ?? "")
        }
        .onAppear {
            // Sleep sounds and music would drown out the test sound.
            player.pause()
            music.pause()
            audio.refreshVolume()
            if model == nil {
                model = TunerModel(audio: audio, saved: allMatches, profileMatches: profileMatches)
            } else {
                model?.setProfileMatches(profileMatches)
                model?.updateSound()
            }
        }
        .onDisappear {
            model?.stopSound()
        }
        .onChange(of: scenePhase) {
            // Never leave a test sound playing in the background or on the lock screen.
            // Tap play to hear it again on return.
            if scenePhase != .active {
                model?.stopAll()
            }
        }
    }

    /// Shows which profile new matches go into, and switches or creates profiles.
    private var profileMenu: some View {
        Menu {
            ProfileMenuItems()
            Button("New Profile…", systemImage: "plus") {
                newProfileName = store.nextProfileName
                creatingProfile = true
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.up")
                Text(store.activeProfile.name)
                    .lineLimit(1)
                    .frame(maxWidth: 80)
            }
            .font(.subheadline)
        }
        .accessibilityLabel("Profile")
        .accessibilityValue(store.activeProfile.name)
    }

    /// The layout's own controls, then the Left and Right diagrams.
    private func controls(_ model: TunerModel) -> some View {
        VStack(spacing: 8) {
            switch layout {
            case .sliders:
                SlidersLayout(model: model)
            case .pad:
                PadLayout(model: model)
            case .band:
                BandLayout(model: model)
            case .dial:
                DialLayout(model: model)
            }
            TunerDiagrams(model: model, sameForBothEars: store.sameForBothEars) { next in
                request(next, model: model)
            }
        }
    }

    @ViewBuilder
    private func content(_ model: TunerModel) -> some View {
        VStack(spacing: 8) {
            if !audio.headphonesConnected {
                Label("Connect your earbuds or headphones", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let warning = volumeWarning(model) {
                Label(warning, systemImage: "speaker.wave.3.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            EarPicker(model: model)
            // Scrolls only on screens too short for everything, so drags on the pad, band, and dials
            // never fight a scroll view.
            ViewThatFits(in: .vertical) {
                controls(model)
                ScrollView { controls(model) }
            }
            Spacer(minLength: 0)
            TunerBottomBar(model: model, defaultName: store.nextMatchName) {
                request(.new, model: model)
            }
        }
        .confirmationDialog(
            "Save changes?",
            isPresented: Binding(get: { pendingSelection != nil }, set: { if !$0 { pendingSelection = nil } }),
            titleVisibility: .visible
        ) {
            Button(model.isNew ? "Save Match" : "Save Changes") {
                afterSave = pendingSelection
                model.beginThreshold(defaultName: store.nextMatchName)
            }
            Button("Discard Changes", role: .destructive) {
                if let next = pendingSelection {
                    model.discardChanges()
                    model.select(next)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.isNew ? "This new match hasn't been saved." : "You changed \(model.selectedMatch.map(Format.matchTitle) ?? "this match") since it was saved.")
        }
        .onChange(of: model.phase) {
            // Going back from the faintest-level check cancels the move to another match.
            if model.phase == .tuning { afterSave = nil }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .sheet(isPresented: Binding(
            get: { model.phase == .threshold },
            set: { if !$0, model.phase == .threshold { model.cancelThreshold() } }
        )) {
            ThresholdSheet(model: model, profileName: store.activeProfile.name) {
                save(model)
            }
            .presentationDetents([.large])
        }
    }
}

extension TunerView {
    /// Moves the controls to another match, or to a new one, asking first if there are unsaved changes.
    func request(_ next: TunerModel.Selection, model: TunerModel) {
        guard next != model.selection || next == .new else { return }
        if model.hasUnsavedChanges {
            pendingSelection = next
        } else {
            model.select(next)
        }
    }

    /// Saves a new match, or the selected match's changes in the active profile only.
    func save(_ model: TunerModel) {
        let match = model.makeProfile(phoneVolume: audio.outputVolume)
        let profile = store.activeProfile
        let earText = match.ear == .both ? "both ears" : "your \(match.ear.shortTitle.lowercased()) ear"
        let summary = "\(Format.frequency(match.centerFrequencyHz)), \(Format.bandwidth(match.bandwidthOctaves)), \(Format.level(match.sensationLevelDB)) above threshold."
        var savedID: UUID?
        var message: String
        if let original = model.selectedMatch {
            switch store.update(original.id, to: match, in: profile.id) {
            case let .success(id):
                savedID = id
                savedTitle = "Changes saved"
                message = "\(Format.matchTitle(match)) for \(earText): \(summary)"
                if id != original.id { message += " Other profiles keep the earlier version." }
            case let .failure(problem):
                afterSave = nil
                model.didNotSave()
                savedTitle = "Changes not saved"
                savedMessage = problem.message
                return
            }
        } else {
            store.add(match)
            savedTitle = "Match saved"
            message = "\(Format.matchTitle(match)) saved for \(earText): \(summary)"
            if model.addToProfile {
                if let problem = store.load(match.id, into: profile.id) {
                    message += " Not added to the profile: \(problem)"
                } else {
                    savedID = match.id
                    message += " Added to \(profile.name)."
                }
            }
        }
        model.didSave(allMatches, savedID: savedID, profileMatches: store.matches(in: store.activeProfile))
        if let next = afterSave {
            afterSave = nil
            model.select(next)
        }
        savedMessage = message
    }

    /// Warns when the phone is loud enough that capped test sounds could still be uncomfortable, or when
    /// its volume differs from the last match, which would make loudness matches hard to compare.
    func volumeWarning(_ model: TunerModel) -> String? {
        let volume = audio.outputVolume
        if volume > TestToneEngine.comfortableVolume + 0.01 {
            return "Your phone volume is at \(Format.volume(volume)). Turn it down to \(Format.volume(TestToneEngine.comfortableVolume)) or less to protect your hearing."
        }
        if let last = model.lastPhoneVolume, abs(last - volume) > 0.07 {
            return "Your last match was at \(Format.volume(last)) phone volume and it's \(Format.volume(volume)) now. Use the same volume so loudness matches compare."
        }
        return nil
    }
}

/// Play turns the selected match on or off, New starts a new match, and Save saves it.
private struct TunerBottomBar: View {
    @Bindable var model: TunerModel
    let defaultName: String
    let onNew: () -> Void

    private var saveTitle: String {
        if model.isNew { return "Save Match" }
        return model.hasUnsavedChanges ? "Save Changes" : "Saved"
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.isSoundOn.toggle()
            } label: {
                Image(systemName: model.isSoundOn ? "pause.fill" : "play.fill")
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(model.isSoundOn ? "Turn selected match off" : "Turn selected match on")

            Button(action: onNew) {
                Label("New", systemImage: "plus")
                    .font(.headline)
                    .frame(minHeight: 48)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("New match")

            Button {
                model.beginThreshold(defaultName: defaultName)
            } label: {
                Text(saveTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.isNew && !model.hasUnsavedChanges)
        }
    }
}

/// After Save: one quick check of the faintest audible level, with only this match playing, so
/// loudness is saved relative to your hearing.
private struct ThresholdSheet: View {
    @Bindable var model: TunerModel
    /// The active profile, which a new match can be added to.
    let profileName: String?
    let onSave: () -> Void

    private var saveTitle: String { model.isNew ? "Save Match" : "Save Changes" }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Lower the sound until you can only just hear it. This lets loudness be saved relative to your hearing.")
                    .fixedSize(horizontal: false, vertical: true)
                Text(Format.level(model.thresholdDBFS))
                    .font(.largeTitle.monospacedDigit())
                Slider(
                    value: $model.thresholdDBFS,
                    in: SafetyLimits.minTestLevelDBFS...max(model.levelDBFS, SafetyLimits.minTestLevelDBFS + 1),
                    step: 1
                ) {
                    Text("Threshold level")
                } minimumValueLabel: {
                    Text("Quieter")
                } maximumValueLabel: {
                    Text("Louder")
                }
                Text("Your match is \(Format.level(model.levelDBFS - model.thresholdDBFS)) above this.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("Match name", text: $model.matchName)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.done)
                if let profileName, model.isNew {
                    Toggle("Add to \(profileName)", isOn: $model.addToProfile)
                }
                Spacer()
                Button(action: onSave) {
                    Text(saveTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle(saveTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back", action: model.cancelThreshold)
                }
            }
        }
    }
}
