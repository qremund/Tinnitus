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
    let layout: TunerLayout
    @State private var model: TunerModel?
    @State private var savedMessage: String?
    @State private var creatingProfile = false
    @State private var newProfileName = ""

    /// Every saved match, so the tuner can start from the newest one and know your threshold near each pitch.
    private var allMatches: EarProfiles {
        EarProfiles.combining(store.profiles, sameForBothEars: false)
    }

    /// The active profile's matches, which can play alongside the test sound.
    private var profileMatches: [TinnitusProfile] {
        store.activeProfile.map { store.matches(in: $0) } ?? []
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
        .onChange(of: profileMatches, initial: true) {
            model?.setCompanions(profileMatches, sameForBothEars: store.sameForBothEars)
        }
        .onChange(of: store.sameForBothEars) {
            model?.setCompanions(profileMatches, sameForBothEars: store.sameForBothEars)
        }
        .alert("Match saved", isPresented: Binding(get: { savedMessage != nil }, set: { if !$0 { savedMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(savedMessage ?? "")
        }
        .onAppear {
            // Sleep sounds and music would drown out the test sound.
            player.pause()
            music.pause()
            if model == nil {
                let created = TunerModel(audio: audio, saved: allMatches)
                created.setCompanions(profileMatches, sameForBothEars: store.sameForBothEars)
                model = created
            } else {
                model?.updateSound()
            }
        }
        .onDisappear {
            model?.stopSound()
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
            if let model, store.activeProfile != nil {
                Section {
                    Toggle("Hear Its Other Matches", isOn: Binding(get: { model.hearProfile }, set: { model.hearProfile = $0 }))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.up")
                Text(store.activeProfile?.name ?? "No profile")
                    .lineLimit(1)
                    .frame(maxWidth: 80)
            }
            .font(.subheadline)
        }
        .accessibilityLabel("Profile")
        .accessibilityValue(store.activeProfile?.name ?? "None")
    }

    @ViewBuilder
    private func content(_ model: TunerModel) -> some View {
        VStack(spacing: 12) {
            if !audio.headphonesConnected {
                Label("Connect your earbuds or headphones", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            EarPicker(model: model)
            switch layout {
            case .sliders:
                ScrollView { SlidersLayout(model: model) }
            case .pad:
                PadLayout(model: model)
            case .band:
                BandLayout(model: model)
            case .dial:
                DialLayout(model: model)
            }
            Spacer(minLength: 0)
            TunerBottomBar(model: model, defaultName: store.nextMatchName)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .sheet(isPresented: Binding(
            get: { model.phase == .threshold },
            set: { if !$0, model.phase == .threshold { model.cancelThreshold() } }
        )) {
            ThresholdSheet(model: model, profileName: store.activeProfile?.name) {
                let match = model.makeProfile()
                store.add(match)
                var added: String?
                var problem: String?
                if model.addToProfile, let profile = store.activeProfile {
                    problem = store.load(match.id, into: profile.id)
                    if problem == nil { added = profile.name }
                }
                model.didSave(allMatches)
                let earText = match.ear == .both ? "both ears" : "your \(match.ear.shortTitle.lowercased()) ear"
                var message = "\(Format.matchTitle(match)) saved for \(earText): \(Format.frequency(match.centerFrequencyHz)), \(Format.bandwidth(match.bandwidthOctaves)), \(Format.level(match.sensationLevelDB)) above threshold."
                if let added { message += " Added to \(added)." }
                if let problem { message += " Not added to the profile: \(problem)" }
                savedMessage = message
            }
            .presentationDetents([.large])
        }
    }
}

private struct TunerBottomBar: View {
    @Bindable var model: TunerModel
    let defaultName: String

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.isSoundOn.toggle()
            } label: {
                Image(systemName: model.isSoundOn ? "pause.fill" : "play.fill")
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(model.isSoundOn ? "Pause test sound" : "Play test sound")

            Button {
                model.beginThreshold(defaultName: defaultName)
            } label: {
                Text("Save Match")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// After Accept: one quick check of the faintest audible level, so loudness is saved relative to your hearing.
private struct ThresholdSheet: View {
    @Bindable var model: TunerModel
    /// The active profile, which the match can be added to.
    let profileName: String?
    let onSave: () -> Void

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
                if let profileName {
                    Toggle("Add to \(profileName)", isOn: $model.addToProfile)
                }
                Spacer()
                Button(action: onSave) {
                    Text("Save Match")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("Save Match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back", action: model.cancelThreshold)
                }
            }
        }
    }
}
