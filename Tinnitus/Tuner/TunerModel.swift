import Foundation
import Observation
import TinnitusCore

/// State for the one-screen tuner. Every change plays the updated test sound right away.
@Observable
final class TunerModel {
    enum Phase {
        case tuning
        /// After Accept: find the faintest audible level at the tuned sound, so loudness can be saved relative to it.
        case threshold
    }

    var pitchHz = 3000.0 { didSet { updateSound() } }
    /// 0...1, mapped to bandwidth by `PitchMatching.bandwidth(sliderPosition:)`. 0 is a pure tone.
    var widthPosition = PitchMatching.sliderPosition(bandwidthOctaves: 1.0 / 8) { didSet { updateSound() } }
    var levelDBFS = -50.0 { didSet { updateSound() } }
    /// Changing the ear keeps the current tuning, so a match can be carried over and checked in the other ear.
    var ear: Ear = .both { didSet { updateSound() } }
    var isSoundOn = true { didSet { updateSound() } }

    /// Play the active profile's other matches quietly while tuning, to hear them together.
    var hearProfile = UserDefaults.standard.object(forKey: "tunerHearProfile") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(hearProfile, forKey: "tunerHearProfile")
            updateSound()
        }
    }
    /// Add the saved match to the active profile.
    var addToProfile = true

    private(set) var phase: Phase = .tuning
    var thresholdDBFS = -80.0 { didSet { updateSound() } }

    @ObservationIgnored private let audio: TestToneEngine
    @ObservationIgnored private var saved: EarProfiles
    @ObservationIgnored private var isLoading = false
    /// The active profile's matches, played alongside the test sound when `hearProfile` is on.
    @ObservationIgnored private var companions: [TestSoundParameters] = []

    init(audio: TestToneEngine, saved: EarProfiles) {
        self.audio = audio
        self.saved = saved
        loadSaved(for: ear)
    }

    var bandwidthOctaves: Double { PitchMatching.bandwidth(sliderPosition: widthPosition) }

    var pitchPosition: Double {
        get { TunerMath.pitchPosition(pitchHz) }
        set { pitchHz = TunerMath.pitch(atPosition: newValue) }
    }

    var levelPosition: Double {
        get { TunerMath.levelPosition(levelDBFS) }
        set { levelDBFS = TunerMath.level(atPosition: newValue) }
    }

    /// The saved threshold for this ear, if any, so loudness can be shown relative to it while tuning.
    var knownThresholdDBFS: Double? { savedProfile(for: ear)?.thresholdDBFS }

    var soundType: TinnitusSoundType { TunerMath.soundType(forBandwidthOctaves: bandwidthOctaves) }

    // MARK: Adjusting

    func nudgePitch(semitones: Double) {
        pitchHz = TunerMath.clampPitch(PitchMatching.shift(pitchHz, semitones: semitones))
    }

    func octave(up: Bool) {
        pitchHz = TunerMath.clampPitch(up ? pitchHz * 2 : pitchHz / 2)
    }

    /// Halves or doubles the width in octaves. Narrower than 1/32 octave becomes a pure tone; wider than a tone starts at 1/32.
    func scaleWidth(by factor: Double) {
        let width = bandwidthOctaves
        if width <= 0 {
            if factor > 1 { widthPosition = PitchMatching.sliderPosition(bandwidthOctaves: 1.0 / 32) }
            return
        }
        let scaled = width * factor
        widthPosition = scaled < 1.0 / 32 - 1e-9 ? 0 : PitchMatching.sliderPosition(bandwidthOctaves: min(scaled, 1))
    }

    func nudgeWidth(by step: Double) {
        widthPosition = min(max(widthPosition + step, 0), 1)
    }

    func nudgeLevel(by db: Double) {
        levelDBFS = min(max(levelDBFS + db, TunerMath.minLevelDBFS), TunerMath.maxLevelDBFS)
    }

    func cycleEar() {
        switch ear {
        case .left: ear = .both
        case .both: ear = .right
        case .right: ear = .left
        }
    }

    // MARK: Accepting

    func beginThreshold(defaultName: String) {
        if matchName.isEmpty { matchName = defaultName }
        beginThreshold()
    }

    func beginThreshold() {
        thresholdDBFS = max(min(knownThresholdDBFS ?? levelDBFS - 15, levelDBFS), SafetyLimits.minTestLevelDBFS)
        phase = .threshold
        isSoundOn = true
        updateSound()
    }

    func cancelThreshold() {
        phase = .tuning
        updateSound()
    }

    /// Name for the match being saved.
    var matchName = ""

    func makeProfile() -> TinnitusProfile {
        TinnitusProfile(
            ear: ear,
            soundType: soundType,
            centerFrequencyHz: pitchHz,
            bandwidthOctaves: bandwidthOctaves,
            thresholdDBFS: thresholdDBFS,
            matchLevelDBFS: levelDBFS,
            notes: "Quick tune",
            name: matchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : matchName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Back to tuning after a save, with the new result as the starting point.
    func didSave(_ profiles: EarProfiles) {
        saved = profiles
        matchName = ""
        addToProfile = true
        phase = .tuning
        updateSound()
    }

    // MARK: Sound

    /// Sets the matches to play alongside the test sound, a little quieter than they were matched.
    func setCompanions(_ matches: [TinnitusProfile], sameForBothEars: Bool) {
        let next = matches.map { match in
            TestSoundParameters(
                frequencyHz: match.centerFrequencyHz,
                kind: TestSoundKind(bandwidthOctaves: match.bandwidthOctaves),
                levelDBFS: min(match.matchLevelDBFS - 6, SafetyLimits.maxTestLevelDBFS - 12),
                ear: sameForBothEars ? .both : match.ear,
                isPlaying: true
            )
        }
        guard next != companions else { return }
        companions = next
        updateSound()
    }

    var hasCompanions: Bool { !companions.isEmpty }

    func updateSound() {
        guard !isLoading else { return }
        guard isSoundOn else {
            audio.stop()
            return
        }
        let level = phase == .threshold ? thresholdDBFS : levelDBFS
        // The threshold check needs the new sound alone.
        let others = phase == .tuning && hearProfile ? companions : []
        audio.play(TestSoundParameters(
            frequencyHz: pitchHz,
            kind: TestSoundKind(bandwidthOctaves: bandwidthOctaves),
            levelDBFS: min(level, SafetyLimits.maxTestLevelDBFS),
            ear: ear
        ), companions: others)
    }

    func stopSound() {
        audio.stop()
    }

    /// The saved match for that ear nearest the current pitch, since hearing thresholds change with pitch.
    private func savedProfile(for ear: Ear) -> TinnitusProfile? {
        savedMatches(for: ear).min { abs(log2($0.centerFrequencyHz / pitchHz)) < abs(log2($1.centerFrequencyHz / pitchHz)) }
    }

    private func savedMatches(for ear: Ear) -> [TinnitusProfile] {
        switch ear {
        case .left: saved.left
        case .right: saved.right
        case .both: saved.left + saved.right
        }
    }

    /// Starts from the newest saved match for that ear.
    private func loadSaved(for ear: Ear) {
        guard let profile = savedMatches(for: ear).max(by: { $0.date < $1.date }) else {
            updateSound()
            return
        }
        isLoading = true
        pitchHz = TunerMath.clampPitch(profile.centerFrequencyHz)
        widthPosition = PitchMatching.sliderPosition(bandwidthOctaves: profile.bandwidthOctaves)
        levelDBFS = min(profile.matchLevelDBFS, TunerMath.maxLevelDBFS)
        isLoading = false
        updateSound()
    }
}
