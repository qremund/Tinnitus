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
    /// Optional name the user gave this match. Older saved matches have none.
    public var name: String?

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
        notes: String = "",
        name: String? = nil
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
        self.name = name
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
        result.name = nil
        return result
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

/// The profile that sets the notch in each ear. A side with no profile plays unfiltered.
public struct EarProfiles: Equatable, Sendable {
    public var left: TinnitusProfile?
    public var right: TinnitusProfile?

    public init(left: TinnitusProfile?, right: TinnitusProfile?) {
        self.left = left
        self.right = right
    }

    /// Notch centers for each ear.
    public var pitches: EarPitches {
        EarPitches(left: left?.centerFrequencyHz, right: right?.centerFrequencyHz)
    }

    public var isEmpty: Bool { left == nil && right == nil }

    /// Builds each ear's profile from the newest `sessions` matches that apply to it. Left and right
    /// matches count for their own ear and "both" matches count for both. With `sameForBothEars`,
    /// every match counts for both ears and the two sides get the same profile.
    public static func from(_ profiles: [TinnitusProfile], sameForBothEars: Bool, sessions: Int = 3) -> EarProfiles {
        let newestFirst = profiles.sorted { $0.date > $1.date }
        if sameForBothEars {
            let shared = TinnitusProfile.consensus(of: Array(newestFirst.prefix(sessions)))
            return EarProfiles(left: shared, right: shared)
        }
        func side(_ ear: Ear) -> TinnitusProfile? {
            TinnitusProfile.consensus(of: Array(newestFirst.filter { $0.ear == ear || $0.ear == .both }.prefix(sessions)))
        }
        return EarProfiles(left: side(.left), right: side(.right))
    }

    /// Like `from`, but an ear with a chosen match uses exactly that match instead of the recent median.
    /// A chosen id that no longer exists falls back to the median.
    public static func resolve(
        _ profiles: [TinnitusProfile],
        sameForBothEars: Bool,
        leftChoice: UUID?,
        rightChoice: UUID?,
        sessions: Int = 3
    ) -> EarProfiles {
        var result = from(profiles, sameForBothEars: sameForBothEars, sessions: sessions)
        if let id = leftChoice, let chosen = profiles.first(where: { $0.id == id }) {
            result.left = chosen
        }
        if let id = rightChoice, let chosen = profiles.first(where: { $0.id == id }) {
            result.right = chosen
        }
        return result
    }
}

/// Notch center for each ear in Hz. nil leaves that ear unfiltered.
public struct EarPitches: Equatable, Hashable, Sendable {
    public var left: Double?
    public var right: Double?

    public init(left: Double?, right: Double?) {
        self.left = left
        self.right = right
    }

    public static let none = EarPitches(left: nil, right: nil)

    public var isEmpty: Bool { left == nil && right == nil }
    public var isSameInBothEars: Bool { left == right }

    /// Band-stop coefficients for one side, empty when that side is unfiltered.
    public func notch(for ear: Ear, widthOctaves: Double, sampleRate: Double) -> [BiquadCoefficients] {
        let center = ear == .right ? right : left
        return center.map { NotchDesign.forTinnitus(centerHz: $0, widthOctaves: widthOctaves, sampleRate: sampleRate) } ?? []
    }
}
