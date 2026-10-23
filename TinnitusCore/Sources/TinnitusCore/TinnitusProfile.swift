import Foundation

public enum TinnitusSoundType: String, Codable, CaseIterable, Sendable {
    case tone
    case narrowHiss
    case broadHiss

    /// Test sound used while searching for the pitch, before bandwidth is matched.
    public var searchSound: TestSoundKind {
        switch self {
        case .tone: .tone
        case .narrowHiss: .narrowbandNoise(bandwidthOctaves: 1.0 / 16)
        case .broadHiss: .narrowbandNoise(bandwidthOctaves: 1.0 / 3)
        }
    }
}

public struct TinnitusProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var ear: Ear
    public var soundType: TinnitusSoundType
    public var centerFrequencyHz: Double
    /// 0 means it matched a pure tone.
    public var bandwidthOctaves: Double
    /// Faintest level heard at the center frequency.
    public var thresholdDBFS: Double
    /// Level that matched the tinnitus loudness.
    public var matchLevelDBFS: Double
    public var coarseRatings: [FrequencyRating]
    public var notes: String

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        ear: Ear,
        soundType: TinnitusSoundType,
        centerFrequencyHz: Double,
        bandwidthOctaves: Double,
        thresholdDBFS: Double,
        matchLevelDBFS: Double,
        coarseRatings: [FrequencyRating] = [],
        notes: String = ""
    ) {
        self.id = id
        self.date = date
        self.ear = ear
        self.soundType = soundType
        self.centerFrequencyHz = centerFrequencyHz
        self.bandwidthOctaves = bandwidthOctaves
        self.thresholdDBFS = thresholdDBFS
        self.matchLevelDBFS = matchLevelDBFS
        self.coarseRatings = coarseRatings
        self.notes = notes
    }

    /// Loudness above your own hearing threshold at that pitch.
    public var sensationLevelDB: Double { matchLevelDBFS - thresholdDBFS }

    /// Median across sessions (pitch on a log scale). Ear, sound type, and id come from the newest session.
    public static func consensus(of profiles: [TinnitusProfile]) -> TinnitusProfile? {
        guard let newest = profiles.max(by: { $0.date < $1.date }) else { return nil }
        guard profiles.count > 1 else { return newest }
        var result = newest
        result.centerFrequencyHz = pow(2, median(profiles.map { log2($0.centerFrequencyHz) }))
        result.bandwidthOctaves = median(profiles.map(\.bandwidthOctaves))
        result.thresholdDBFS = median(profiles.map(\.thresholdDBFS))
        result.matchLevelDBFS = median(profiles.map(\.matchLevelDBFS))
        result.notes = "Median of \(profiles.count) sessions"
        return result
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
