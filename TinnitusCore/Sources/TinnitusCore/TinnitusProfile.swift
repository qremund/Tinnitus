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

/// A named set of saved matches used together, such as a left tone, a second left tone, and a right
/// hiss. It refers to matches by id, so removing one from a profile never deletes the match itself.
public struct MatchProfile: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var matchIDs: [UUID]

    public init(id: UUID = UUID(), name: String, matchIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.matchIDs = matchIDs
    }

    public func contains(_ matchID: UUID) -> Bool { matchIDs.contains(matchID) }
}

/// The matches that set the notches in each ear, lowest pitch first. A side with none plays unfiltered.
public struct EarProfiles: Equatable, Sendable {
    public var left: [TinnitusProfile]
    public var right: [TinnitusProfile]

    public init(left: [TinnitusProfile], right: [TinnitusProfile]) {
        self.left = left.sorted { $0.centerFrequencyHz < $1.centerFrequencyHz }
        self.right = right.sorted { $0.centerFrequencyHz < $1.centerFrequencyHz }
    }

    /// One match (or none) per ear.
    public init(left: TinnitusProfile?, right: TinnitusProfile?) {
        self.init(left: left.map { [$0] } ?? [], right: right.map { [$0] } ?? [])
    }

    /// Notch centers for each ear.
    public var pitches: EarPitches {
        EarPitches(left: left.map(\.centerFrequencyHz), right: right.map(\.centerFrequencyHz))
    }

    public var isEmpty: Bool { left.isEmpty && right.isEmpty }

    /// The matches for one ear. For `.both`, the matches that are in both ears.
    public func matches(for ear: Ear) -> [TinnitusProfile] {
        switch ear {
        case .left: left
        case .right: right
        case .both: left.filter { match in right.contains { $0.id == match.id } }
        }
    }

    /// Automatic mode: each ear gets the median of the newest `sessions` matches that apply to it.
    /// Left and right matches count for their own ear and "both" matches count for both. With
    /// `sameForBothEars`, every match counts for both ears and the two sides get the same median.
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

    /// A profile's matches, each in its own ear: left and right matches in that ear, "both" matches in
    /// each. With `sameForBothEars`, every match goes in both ears.
    public static func combining(_ matches: [TinnitusProfile], sameForBothEars: Bool) -> EarProfiles {
        if sameForBothEars {
            return EarProfiles(left: matches, right: matches)
        }
        return EarProfiles(left: matches.filter { $0.ear != .right }, right: matches.filter { $0.ear != .left })
    }
}

/// Notch centers for each ear in Hz, lowest first. An empty side is unfiltered.
public struct EarPitches: Equatable, Hashable, Sendable {
    public var left: [Double]
    public var right: [Double]

    public init(left: [Double], right: [Double]) {
        self.left = left.sorted()
        self.right = right.sorted()
    }

    /// One notch (or none) per ear.
    public init(left: Double?, right: Double?) {
        self.init(left: left.map { [$0] } ?? [], right: right.map { [$0] } ?? [])
    }

    public static let none = EarPitches(left: [], right: [])

    public var isEmpty: Bool { left.isEmpty && right.isEmpty }
    public var isSameInBothEars: Bool { left == right }

    public func centers(for ear: Ear) -> [Double] { ear == .right ? right : left }

    /// Band-stop coefficients for one side, empty when that side is unfiltered. Several pitches give
    /// several notches in series, with overlapping ones merged into one wider notch.
    public func notch(for ear: Ear, widthOctaves: Double, sampleRate: Double) -> [BiquadCoefficients] {
        NotchDesign.forTinnitus(centersHz: centers(for: ear), widthOctaves: widthOctaves, sampleRate: sampleRate)
    }
}
