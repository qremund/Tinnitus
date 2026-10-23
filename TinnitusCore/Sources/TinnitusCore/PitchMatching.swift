import Foundation

public enum PitchMatching {
    public static let minFrequencyHz = 125.0
    public static let maxFrequencyHz = 16_000.0

    /// Half-octave steps from 250 Hz to 16 kHz (13 frequencies).
    public static let coarseFrequencies: [Double] = (0...12).map { 250 * pow(2, Double($0) / 2) }

    public static func shift(_ frequencyHz: Double, semitones: Double) -> Double {
        frequencyHz * pow(2, semitones / 12)
    }

    /// Half, same, and double the frequency, dropping any outside the playable range.
    public static func octaveCandidates(for frequencyHz: Double) -> [Double] {
        [frequencyHz / 2, frequencyHz, frequencyHz * 2].filter { (minFrequencyHz...maxFrequencyHz).contains($0) }
    }

    /// Notch edges centered on a log scale: f * 2^(-w/2) to f * 2^(+w/2).
    public static func notchEdges(centerHz: Double, widthOctaves: Double) -> (low: Double, high: Double) {
        (centerHz * pow(2, -widthOctaves / 2), centerHz * pow(2, widthOctaves / 2))
    }

    /// Maps a 0...1 slider to a bandwidth: 0 is a pure tone, then 1/32 octave up to 1 octave on a log scale.
    public static func bandwidth(sliderPosition: Double) -> Double {
        let p = min(max(sliderPosition, 0), 1)
        return p == 0 ? 0 : pow(32, p) / 32
    }

    public static func sliderPosition(bandwidthOctaves: Double) -> Double {
        bandwidthOctaves <= 0 ? 0 : min(max(log(bandwidthOctaves * 32) / log(32), 0), 1)
    }
}

public struct FrequencyRating: Codable, Equatable, Sendable {
    public var frequencyHz: Double
    public var meanRating: Double

    public init(frequencyHz: Double, meanRating: Double) {
        self.frequencyHz = frequencyHz
        self.meanRating = meanRating
    }
}

/// Tinnitus likeness rating (Hébert, 2018): each frequency is played several times in random order
/// and rated 0 to 10 for how much it sounds like the tinnitus.
public struct LikenessRatingSession: Equatable, Sendable {
    public struct Trial: Equatable, Sendable {
        public let frequencyHz: Double
        public var rating: Int?
    }

    public private(set) var trials: [Trial]
    public private(set) var currentIndex = 0

    public init<G: RandomNumberGenerator>(
        frequencies: [Double] = PitchMatching.coarseFrequencies,
        repetitions: Int = 3,
        using generator: inout G
    ) {
        var all: [Trial] = []
        for _ in 0..<repetitions {
            all += frequencies.map { Trial(frequencyHz: $0, rating: nil) }
        }
        all.shuffle(using: &generator)
        trials = all
    }

    public init(frequencies: [Double] = PitchMatching.coarseFrequencies, repetitions: Int = 3) {
        var generator = SystemRandomNumberGenerator()
        self.init(frequencies: frequencies, repetitions: repetitions, using: &generator)
    }

    public var currentTrial: Trial? {
        trials.indices.contains(currentIndex) ? trials[currentIndex] : nil
    }

    public var isComplete: Bool { currentIndex >= trials.count }

    public mutating func rate(_ rating: Int) {
        guard trials.indices.contains(currentIndex) else { return }
        trials[currentIndex].rating = min(max(rating, 0), 10)
        currentIndex += 1
    }

    public mutating func goBack() {
        currentIndex = max(currentIndex - 1, 0)
    }

    /// Mean rating per frequency, lowest frequency first. Unrated frequencies are left out.
    public var meanRatings: [FrequencyRating] {
        var sums: [Double: (total: Double, count: Int)] = [:]
        for trial in trials {
            guard let rating = trial.rating else { continue }
            let entry = sums[trial.frequencyHz, default: (0, 0)]
            sums[trial.frequencyHz] = (entry.total + Double(rating), entry.count + 1)
        }
        return sums
            .map { FrequencyRating(frequencyHz: $0.key, meanRating: $0.value.total / Double($0.value.count)) }
            .sorted { $0.frequencyHz < $1.frequencyHz }
    }

    /// Highest mean rating. Ties go to the geometric middle of the tied frequencies.
    public var bestFrequencyHz: Double? {
        let ratings = meanRatings
        guard let top = ratings.map(\.meanRating).max() else { return nil }
        let tied = ratings.filter { $0.meanRating == top }.map(\.frequencyHz)
        let meanLog = tied.map { log2($0) }.reduce(0, +) / Double(tied.count)
        return pow(2, meanLog)
    }
}
