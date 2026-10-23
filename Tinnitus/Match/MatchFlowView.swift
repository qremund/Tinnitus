import SwiftUI
import TinnitusCore

struct MatchFlowView: View {
    @Environment(TestToneEngine.self) private var audio
    @Environment(ProfileStore.self) private var store
    @Environment(SleepPlayer.self) private var player
    @Environment(MusicPlayer.self) private var music
    @State private var model: MatchModel?
    @State private var savedMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    MatchStepView(model: model) { profile in
                        store.add(profile)
                        savedMessage = "Saved: \(Format.frequency(profile.centerFrequencyHz)), \(Format.bandwidth(profile.bandwidthOctaves))."
                        self.model = MatchModel(audio: audio)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Match")
            .alert("Profile saved", isPresented: Binding(get: { savedMessage != nil }, set: { if !$0 { savedMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(savedMessage ?? "")
            }
        }
        .onAppear {
            // Sleep sounds and music would drown out the test tones.
            player.pause()
            music.pause()
            if model == nil {
                model = MatchModel(audio: audio)
            }
            model?.updateSound()
        }
        .onDisappear {
            model?.stopSound()
        }
    }
}

struct MatchStepView: View {
    @Bindable var model: MatchModel
    @Environment(TestToneEngine.self) private var audio
    let onSave: (TinnitusProfile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProgressView(value: Double(model.stepNumber), total: Double(model.stepCount))
            Text("Step \(model.stepNumber) of \(model.stepCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(model.step.title)
                .font(.title2.bold())

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    stepContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            navigation
        }
        .padding()
    }

    // MARK: Step content

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .setup: setup
        case .ear: earChoice
        case .soundType: soundTypeChoice
        case .coarse: coarse
        case .fine: fine
        case .octave: octave
        case .bandwidth: bandwidth
        case .threshold: threshold
        case .loudness: loudness
        case .review: review
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                audio.headphonesConnected ? "Headphones connected" : "Connect your earbuds or headphones",
                systemImage: audio.headphonesConnected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(audio.headphonesConnected ? .green : .orange)
            Text("Find a quiet room. The session takes about 10 to 15 minutes.")
            Text("Set your phone volume to about half and use the same setting every session, so results are comparable.")
            Text("Turn off any EQ, HearID, or transparency mode in your earbuds' app.")
            Text("Sounds fade in quietly and are capped well below full volume. Stop if anything is uncomfortable.")
            if let error = audio.errorMessage {
                Text(error).foregroundStyle(.red)
            }
        }
    }

    private var earChoice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where do you hear your tinnitus? Test sounds will play on that side.")
            Picker("Ear", selection: $model.ear) {
                ForEach(Ear.allCases, id: \.self) { ear in
                    Text(ear.title).tag(ear)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    private var soundTypeChoice: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(TinnitusSoundType.allCases, id: \.self) { type in
                Button {
                    model.soundType = type
                } label: {
                    HStack(alignment: .top) {
                        Image(systemName: model.soundType == type ? "largecircle.fill.circle" : "circle")
                        VStack(alignment: .leading) {
                            Text(type.title).bold()
                            Text(type.detail).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var coarse: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let trial = model.ratingSession.currentTrial {
                Text("Sound \(model.ratingSession.currentIndex + 1) of \(model.ratingSession.trials.count)")
                    .font(.headline)
                Text("How much does this sound like your tinnitus? Judge the pitch, not the loudness.")
                Text("\(Int(model.pendingRating.rounded())) / 10")
                    .font(.largeTitle.monospacedDigit())
                Slider(value: $model.pendingRating, in: 0...10, step: 1) {
                    Text("Likeness")
                } minimumValueLabel: {
                    Text("Not at all")
                } maximumValueLabel: {
                    Text("Exactly")
                }
                HStack {
                    Button("Previous", action: model.previousSound)
                        .disabled(model.ratingSession.currentIndex == 0)
                    Spacer()
                    Button("Next sound", action: model.rateCurrentSound)
                        .buttonStyle(.borderedProminent)
                }
                .accessibilityHint(Text("Playing \(Format.frequency(trial.frequencyHz))"))
            }
            levelSlider
            Divider()
            Text("Already know roughly where it is? Skip the search and start fine-tuning near:")
                .font(.callout)
            HStack {
                TextField("Hz", value: $model.skipToFrequencyHz, format: .number)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                Text("Hz")
                Spacer()
                Button("Skip ahead", action: model.skipCoarseSearch)
            }
        }
    }

    private var fine: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Slide until the pitch sounds most like your tinnitus.")
            Text(Format.frequency(model.fineFrequencyHz))
                .font(.largeTitle.monospacedDigit())
            Slider(value: $model.fineOffsetSemitones, in: -6...6, step: 0.25) {
                Text("Pitch")
            } minimumValueLabel: {
                Text("Lower")
            } maximumValueLabel: {
                Text("Higher")
            }
            levelSlider
        }
    }

    private var octave: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pitches an octave apart are easy to confuse. Tap each one and pick the closest.")
            Picker("Octave", selection: $model.octaveChoice) {
                ForEach(Array(model.octaveCandidates.enumerated()), id: \.offset) { index, hz in
                    Text(Format.frequency(hz)).tag(index)
                }
            }
            .pickerStyle(.segmented)
            levelSlider
        }
    }

    private var bandwidth: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Make the sound narrower or wider until its texture matches. All the way left is a pure tone.")
            Text(Format.bandwidth(model.bandwidthOctaves))
                .font(.largeTitle.monospacedDigit())
            Slider(value: $model.bandwidthPosition, in: 0...1) {
                Text("Width")
            } minimumValueLabel: {
                Text("Tone")
            } maximumValueLabel: {
                Text("Wide")
            }
            levelSlider
        }
    }

    private var threshold: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Lower the sound until you can only just hear it, then continue. This lets loudness be saved relative to your own hearing.")
            Text(Format.level(model.thresholdDBFS))
                .font(.largeTitle.monospacedDigit())
            Slider(value: $model.thresholdDBFS, in: SafetyLimits.minTestLevelDBFS...(-30), step: 1) {
                Text("Level")
            } minimumValueLabel: {
                Text("Quieter")
            } maximumValueLabel: {
                Text("Louder")
            }
        }
    }

    private var loudness: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Raise the sound until it is as loud as your tinnitus.")
            Text("\(Format.level(model.matchLevelDBFS - model.thresholdDBFS)) above your threshold")
                .font(.title.monospacedDigit())
            Slider(value: $model.matchLevelDBFS, in: model.thresholdDBFS...SafetyLimits.maxTestLevelDBFS, step: 1) {
                Text("Level")
            } minimumValueLabel: {
                Text("Quieter")
            } maximumValueLabel: {
                Text("Louder")
            }
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Ear", value: model.ear.title)
            LabeledContent("Sound", value: model.soundType.title)
            LabeledContent("Pitch", value: Format.frequency(model.matchedFrequencyHz))
            LabeledContent("Width", value: Format.bandwidth(model.bandwidthOctaves))
            LabeledContent("Loudness", value: "\(Format.level(model.matchLevelDBFS - model.thresholdDBFS)) above threshold")
            TextField("Notes (optional), e.g. how sure you are", text: $model.notes, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            Text("Matching on two or three different days and using the median gives a steadier result. The Profile tab does that for you.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var levelSlider: some View {
        VStack(alignment: .leading) {
            Text("Listening volume: keep it soft and comfortable")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: $model.listeningLevelDBFS, in: -70...SafetyLimits.maxTestLevelDBFS, step: 1)
        }
    }

    // MARK: Navigation

    @ViewBuilder
    private var navigation: some View {
        switch model.step {
        case .coarse:
            Button("Back", action: model.back)
        case .review:
            HStack {
                Button("Back", action: model.back)
                Spacer()
                Button("Save profile") { onSave(model.makeProfile()) }
                    .buttonStyle(.borderedProminent)
            }
        default:
            HStack {
                Button("Back", action: model.back)
                    .disabled(model.step == .setup)
                Spacer()
                Button(nextTitle, action: model.advance)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdvance)
            }
        }
    }

    private var nextTitle: String {
        switch model.step {
        case .threshold: "I can just hear it"
        case .loudness: "Same as my tinnitus"
        default: "Continue"
        }
    }

    private var canAdvance: Bool {
        guard model.step == .setup else { return true }
        #if targetEnvironment(simulator)
        return true
        #else
        return audio.headphonesConnected
        #endif
    }
}
