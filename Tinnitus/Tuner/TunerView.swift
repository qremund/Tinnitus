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
        case .dial: "Tiles and one dial"
        }
    }

    var detail: String {
        switch self {
        case .sliders: "Everything at once"
        case .pad: "One drag for pitch and width"
        case .band: "See the shape you match"
        case .dial: "Most precise"
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
        .alert("Profile saved", isPresented: Binding(get: { savedMessage != nil }, set: { if !$0 { savedMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(savedMessage ?? "")
        }
        .onAppear {
            // Sleep sounds and music would drown out the test sound.
            player.pause()
            music.pause()
            if model == nil {
                model = TunerModel(audio: audio, saved: store.ears)
            } else {
                model?.updateSound()
            }
        }
        .onDisappear {
            model?.stopSound()
        }
    }

    @ViewBuilder
    private func content(_ model: TunerModel) -> some View {
        VStack(spacing: 12) {
            if !audio.headphonesConnected {
                Label("Connect your earbuds or headphones", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
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
            ThresholdSheet(model: model) {
                let profile = model.makeProfile()
                store.add(profile)
                model.didSave(store.ears)
                savedMessage = "\(Format.matchTitle(profile)) saved for \(profile.ear == .both ? "both ears" : "your \(profile.ear.shortTitle.lowercased()) ear"): \(Format.frequency(profile.centerFrequencyHz)), \(Format.bandwidth(profile.bandwidthOctaves)), \(Format.level(profile.sensationLevelDB)) above threshold."
            }
            .presentationDetents([.medium])
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
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Lower the sound until you can only just hear it. This lets loudness be saved relative to your hearing.")
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
                    .submitLabel(.done)
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
