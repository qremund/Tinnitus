import Foundation
import Observation
import TinnitusCore

/// State for the guided matching session. Every change re-sends the right test sound to the engine.
@Observable
final class MatchModel {
    enum Step: Int, CaseIterable {
        case setup, ear, soundType, coarse, fine, octave, bandwidth, threshold, loudness, review

        var title: String {
            switch self {
            case .setup: "Get ready"
            case .ear: "Which ear?"
            case .soundType: "What does it sound like?"
            case .coarse: "Rate each sound"
            case .fine: "Fine-tune the pitch"
            case .octave: "Check the octave"
            case .bandwidth: "Match the width"
            case .threshold: "Find your hearing threshold"
            case .loudness: "Match the loudness"
            case .review: "Review and save"
            }
        }
    }

    private(set) var step: Step = .setup
    var ear: Ear = .both
    var soundType: TinnitusSoundType = .tone
    var listeningLevelDBFS = -40.0 { didSet { updateSound() } }

    private(set) var ratingSession = LikenessRatingSession()
    var pendingRating = 5.0
    var skipToFrequencyHz = 3000.0

    private(set) var fineCenterHz = 3000.0
    var fineOffsetSemitones = 0.0 { didSet { updateSound() } }
    var octaveChoice = 1 { didSet { updateSound() } }
    var bandwidthPosition = 0.0 { didSet { updateSound() } }
    var thresholdDBFS = -80.0 { didSet { updateSound() } }
    var matchLevelDBFS = -60.0 { didSet { updateSound() } }
    var notes = ""

    @ObservationIgnored private let audio: TestToneEngine

    init(audio: TestToneEngine) {
        self.audio = audio
    }

    // MARK: Derived values

    var fineFrequencyHz: Double {
        PitchMatching.shift(fineCenterHz, semitones: fineOffsetSemitones)
    }

    var octaveCandidates: [Double] {
        PitchMatching.octaveCandidates(for: fineFrequencyHz)
    }

    var matchedFrequencyHz: Double {
        octaveCandidates.indices.contains(octaveChoice) ? octaveCandidates[octaveChoice] : fineFrequencyHz
    }

    var bandwidthOctaves: Double {
        PitchMatching.bandwidth(sliderPosition: bandwidthPosition)
    }

    var stepNumber: Int { step.rawValue + 1 }
    var stepCount: Int { Step.allCases.count }

    // MARK: Navigation

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        go(to: next)
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        go(to: previous)
    }

    func rateCurrentSound() {
        ratingSession.rate(Int(pendingRating.rounded()))
        pendingRating = 5
        if ratingSession.isComplete {
            go(to: .fine)
        } else {
            updateSound()
        }
    }

    func previousSound() {
        ratingSession.goBack()
        updateSound()
    }

    func skipCoarseSearch() {
        fineCenterHz = min(max(skipToFrequencyHz, PitchMatching.minFrequencyHz), PitchMatching.maxFrequencyHz)
        fineOffsetSemitones = 0
        go(to: .fine)
    }

    private func go(to newStep: Step) {
        switch newStep {
        case .coarse where ratingSession.isComplete:
            ratingSession = LikenessRatingSession()
        case .fine where step == .coarse:
            fineCenterHz = ratingSession.bestFrequencyHz ?? fineCenterHz
            fineOffsetSemitones = 0
        case .octave where step == .fine:
            octaveChoice = octaveCandidates.firstIndex { abs($0 - fineFrequencyHz) < 0.01 } ?? 0
        case .bandwidth where step == .octave:
            bandwidthPosition = PitchMatching.sliderPosition(bandwidthOctaves: soundType.searchSound.bandwidthOctaves)
        case .loudness where step == .threshold:
            matchLevelDBFS = min(thresholdDBFS + 6, SafetyLimits.maxTestLevelDBFS)
        default:
            break
        }
        step = newStep
        updateSound()
    }

    // MARK: Sound

    func updateSound() {
        let search = soundType.searchSound
        let matched = TestSoundKind(bandwidthOctaves: bandwidthOctaves)
        switch step {
        case .setup, .ear, .soundType, .review:
            audio.stop()
        case .coarse:
            if let trial = ratingSession.currentTrial {
                play(trial.frequencyHz, search, listeningLevelDBFS)
            } else {
                audio.stop()
            }
        case .fine:
            play(fineFrequencyHz, search, listeningLevelDBFS)
        case .octave:
            play(matchedFrequencyHz, search, listeningLevelDBFS)
        case .bandwidth:
            play(matchedFrequencyHz, matched, listeningLevelDBFS)
        case .threshold:
            play(matchedFrequencyHz, matched, thresholdDBFS)
        case .loudness:
            play(matchedFrequencyHz, matched, matchLevelDBFS)
        }
    }

    func stopSound() {
        audio.stop()
    }

    private func play(_ frequencyHz: Double, _ kind: TestSoundKind, _ level: Double) {
        audio.play(TestSoundParameters(frequencyHz: frequencyHz, kind: kind, levelDBFS: level, ear: ear))
    }

    // MARK: Result

    func makeProfile() -> TinnitusProfile {
        TinnitusProfile(
            ear: ear,
            soundType: soundType,
            centerFrequencyHz: matchedFrequencyHz,
            bandwidthOctaves: bandwidthOctaves,
            thresholdDBFS: thresholdDBFS,
            matchLevelDBFS: matchLevelDBFS,
            coarseRatings: ratingSession.meanRatings,
            notes: notes
        )
    }
}

private extension TestSoundKind {
    var bandwidthOctaves: Double {
        switch self {
        case .tone: 0
        case let .narrowbandNoise(bandwidth): bandwidth
        }
    }
}
