import Foundation
import Observation
import TinnitusCore

/// State for the one-screen tuner. The controls edit one match at a time: a saved match from the
/// active profile, or a new one. Each match can be on or off, so several can play together.
@MainActor
@Observable
final class TunerModel {
    enum Phase {
        case tuning
        /// After Save: find the faintest audible level at the tuned sound, so loudness can be saved relative to it.
        case threshold
    }

    /// What the controls are editing.
    enum Selection: Hashable {
        /// A match that hasn't been saved yet.
        case new
        /// A saved match in the active profile.
        case match(UUID)
    }

    /// The four things a match's controls set, to tell whether they were changed.
    struct Settings: Equatable {
        var pitchHz: Double
        var widthPosition: Double
        var levelDBFS: Double
        var ear: Ear
    }

    var pitchHz = 3000.0 { didSet { updateSound() } }
    /// 0...1, mapped to bandwidth by `PitchMatching.bandwidth(sliderPosition:)`. 0 is a pure tone.
    var widthPosition = PitchMatching.sliderPosition(bandwidthOctaves: 1.0 / 8) { didSet { updateSound() } }
    var levelDBFS = -50.0 { didSet { updateSound() } }
    /// Changing the ear keeps the current tuning, so a match can be carried over and checked in the other ear.
    var ear: Ear = .both { didSet { updateSound() } }

    private(set) var selection: Selection = .new
    /// Saved matches that are on. Each plays at its saved settings, except the selected one, which
    /// plays the controls.
    private(set) var playing: Set<UUID> = []
    /// Whether the new match is on.
    private(set) var newIsOn = true
    /// The selected match's settings when it was selected or last saved. Edits are measured against these.
    private var baseline: Settings

    /// The active profile's matches, which the diagrams show and which can play together.
    private(set) var profileMatches: [TinnitusProfile] = []

    /// Add a new match to the active profile when it's saved.
    var addToProfile = true

    private(set) var phase: Phase = .tuning
    var thresholdDBFS = -80.0 { didSet { updateSound() } }

    /// Name for the match being saved.
    var matchName = ""

    @ObservationIgnored private let audio: TestToneEngine
    /// Every saved match, for hearing thresholds and the last phone volume.
    @ObservationIgnored private var saved: EarProfiles
    @ObservationIgnored private var isLoading = false

    init(audio: TestToneEngine, saved: EarProfiles, profileMatches: [TinnitusProfile]) {
        self.audio = audio
        self.saved = saved
        self.profileMatches = profileMatches
        baseline = Settings(pitchHz: 3000, widthPosition: PitchMatching.sliderPosition(bandwidthOctaves: 1.0 / 8), levelDBFS: -50, ear: .both)
        // Start on the newest match in the profile, playing. With none, start a new match from the
        // newest saved match anywhere.
        if let newest = profileMatches.max(by: { $0.date < $1.date }) {
            playing = [newest.id]
            select(.match(newest.id))
        } else {
            loadNewestSaved()
            baseline = settings
            updateSound()
        }
    }

    var settings: Settings {
        Settings(pitchHz: pitchHz, widthPosition: widthPosition, levelDBFS: levelDBFS, ear: ear)
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

    var soundType: TinnitusSoundType { TunerMath.soundType(forBandwidthOctaves: bandwidthOctaves) }

    /// The saved match being edited, if one is selected.
    var selectedMatch: TinnitusProfile? {
        guard case let .match(id) = selection else { return nil }
        return profileMatches.first { $0.id == id }
    }

    var isNew: Bool { selection == .new }

    /// The controls differ from the selected match's saved settings. A new match counts once it's
    /// been changed from where it started.
    var hasUnsavedChanges: Bool { settings != baseline }

    /// The selected match is on.
    var isSoundOn: Bool {
        get {
            switch selection {
            case .new: newIsOn
            case let .match(id): playing.contains(id)
            }
        }
        set {
            switch selection {
            case .new: newIsOn = newValue
            case let .match(id):
                if newValue { playing.insert(id) } else { playing.remove(id) }
            }
            updateSound()
        }
    }

    func isOn(_ id: UUID) -> Bool { playing.contains(id) }

    /// The selected match's own threshold, or else the saved threshold for this ear nearest the
    /// current pitch, since hearing thresholds change with pitch.
    var knownThresholdDBFS: Double? {
        if let match = selectedMatch, match.ear == ear { return match.thresholdDBFS }
        return savedProfile(for: ear)?.thresholdDBFS
    }

    // MARK: Choosing what to edit

    /// Loads a match into the controls. Unsaved edits to the previous one are dropped, so ask first.
    func select(_ next: Selection) {
        switch next {
        case .new:
            startNew()
        case let .match(id):
            guard let match = profileMatches.first(where: { $0.id == id }) else { return }
            selection = next
            load(match)
            baseline = settings
            updateSound()
        }
    }

    /// Starts a new match from the current settings, and turns it on.
    func startNew() {
        selection = .new
        newIsOn = true
        baseline = settings
        matchName = ""
        addToProfile = true
        updateSound()
    }

    /// Puts the selected match back the way it was saved.
    func discardChanges() {
        isLoading = true
        pitchHz = baseline.pitchHz
        widthPosition = baseline.widthPosition
        levelDBFS = baseline.levelDBFS
        ear = baseline.ear
        isLoading = false
        updateSound()
    }

    /// The active profile changed: new matches, or the same ones edited or taken out.
    func setProfileMatches(_ matches: [TinnitusProfile]) {
        guard matches != profileMatches else { return }
        profileMatches = matches
        let ids = Set(matches.map(\.id))
        playing.formIntersection(ids)
        if case let .match(id) = selection, !ids.contains(id) {
            // The selected match left the profile, or another profile became active.
            if let newest = matches.max(by: { $0.date < $1.date }) {
                select(.match(newest.id))
            } else {
                startNew()
            }
            return
        }
        updateSound()
    }

    /// Turns every match off, for example when the app goes to the background.
    func stopAll() {
        playing = []
        newIsOn = false
        updateSound()
    }

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

    // MARK: Saving

    /// Starts the faintest-level check, with only the selected match playing.
    func beginThreshold(defaultName: String) {
        if let match = selectedMatch {
            matchName = match.name ?? ""
        } else if matchName.isEmpty {
            matchName = defaultName
        }
        thresholdDBFS = max(min(knownThresholdDBFS ?? levelDBFS - 15, levelDBFS), SafetyLimits.minTestLevelDBFS)
        phase = .threshold
        updateSound()
    }

    func cancelThreshold() {
        phase = .tuning
        updateSound()
    }

    /// The phone volume of the newest saved match, so the screen can warn when today's differs.
    var lastPhoneVolume: Double? {
        (saved.left + saved.right).filter { $0.phoneVolume != nil }.max { $0.date < $1.date }?.phoneVolume
    }

    /// The match to save: a new one, or the selected match with the new settings.
    func makeProfile(phoneVolume: Double? = nil) -> TinnitusProfile {
        let trimmed = matchName.trimmingCharacters(in: .whitespacesAndNewlines)
        var match = selectedMatch ?? TinnitusProfile(
            ear: ear,
            soundType: soundType,
            centerFrequencyHz: pitchHz,
            bandwidthOctaves: bandwidthOctaves,
            thresholdDBFS: thresholdDBFS,
            matchLevelDBFS: levelDBFS,
            notes: "Quick tune"
        )
        match.date = Date()
        match.ear = ear
        match.soundType = soundType
        match.centerFrequencyHz = pitchHz
        match.bandwidthOctaves = bandwidthOctaves
        match.thresholdDBFS = thresholdDBFS
        match.matchLevelDBFS = levelDBFS
        match.name = trimmed.isEmpty ? nil : trimmed
        match.phoneVolume = phoneVolume
        return match
    }

    /// Back to tuning after a save. `id` is the saved match, now selected, if it's in the profile;
    /// `wasOn` is whether the sound was on, so it stays on.
    func didSave(_ allMatches: EarProfiles, savedID id: UUID?, profileMatches matches: [TinnitusProfile]) {
        let wasOn = isSoundOn
        saved = allMatches
        phase = .tuning
        matchName = ""
        addToProfile = true
        profileMatches = matches
        playing.formIntersection(Set(matches.map(\.id)))
        if let id, matches.contains(where: { $0.id == id }) {
            selection = .match(id)
            if wasOn { playing.insert(id) }
        } else {
            // Saved, but not into the profile: keep tuning it as a new match.
            selection = .new
            newIsOn = wasOn
        }
        baseline = settings
        updateSound()
    }

    /// Back to tuning without saving, for example when the profile was full.
    func didNotSave() {
        phase = .tuning
        updateSound()
    }

    // MARK: Sound

    func updateSound() {
        guard !isLoading else { return }
        let live = TestSoundParameters(
            frequencyHz: pitchHz,
            kind: TestSoundKind(bandwidthOctaves: bandwidthOctaves),
            levelDBFS: phase == .threshold ? thresholdDBFS : levelDBFS,
            ear: ear
        )
        // The threshold check needs the selected sound alone.
        guard phase == .tuning else {
            audio.play(live.cappedForTest)
            return
        }
        var sounds: [TestSoundParameters] = isSoundOn ? [live] : []
        for match in profileMatches where playing.contains(match.id) && selection != .match(match.id) {
            sounds.append(TestSoundParameters(
                frequencyHz: match.centerFrequencyHz,
                kind: TestSoundKind(bandwidthOctaves: match.bandwidthOctaves),
                levelDBFS: match.matchLevelDBFS,
                ear: match.ear
            ))
        }
        let levels = SafetyLimits.combinedTestLevels(sounds.map(\.levelDBFS))
        for index in sounds.indices { sounds[index].levelDBFS = levels[index] }
        guard let first = sounds.first else {
            audio.stop()
            return
        }
        audio.play(first, companions: Array(sounds.dropFirst()))
    }

    func stopSound() {
        audio.stop()
    }

    private func load(_ match: TinnitusProfile) {
        isLoading = true
        pitchHz = TunerMath.clampPitch(match.centerFrequencyHz)
        widthPosition = PitchMatching.sliderPosition(bandwidthOctaves: match.bandwidthOctaves)
        levelDBFS = min(max(match.matchLevelDBFS, TunerMath.minLevelDBFS), TunerMath.maxLevelDBFS)
        ear = match.ear
        isLoading = false
    }

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

    /// Starts a new match from the newest saved match, if there is one.
    private func loadNewestSaved() {
        guard let newest = (saved.left + saved.right).max(by: { $0.date < $1.date }) else { return }
        load(newest)
    }
}

private extension TestSoundParameters {
    var cappedForTest: TestSoundParameters {
        var p = self
        p.levelDBFS = min(p.levelDBFS, SafetyLimits.maxTestLevelDBFS)
        return p
    }
}
