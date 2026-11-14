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
    /// The phone's volume (0 to 1) when the match was made, so later matches can use the same setting.
    /// Older saved matches have none.
    public var phoneVolume: Double?

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
        name: String? = nil,
        phoneVolume: Double? = nil
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
        self.phoneVolume = phoneVolume
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
        result.phoneVolume = nil
        return result
    }

    /// List order for saved matches: left, then right, then both ears; within an ear, lowest pitch
    /// first, then narrowest width; newest first when all three are the same.
    public static func displayOrder(_ a: TinnitusProfile, _ b: TinnitusProfile) -> Bool {
        func rank(_ ear: Ear) -> Int {
            switch ear {
            case .left: 0
            case .right: 1
            case .both: 2
            }
        }
        if a.ear != b.ear { return rank(a.ear) < rank(b.ear) }
        if a.centerFrequencyHz != b.centerFrequencyHz { return a.centerFrequencyHz < b.centerFrequencyHz }
        if a.bandwidthOctaves != b.bandwidthOctaves { return a.bandwidthOctaves < b.bandwidthOctaves }
        return a.date > b.date
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
        func notches(_ matches: [TinnitusProfile]) -> [NotchSpec] {
            matches.map { NotchSpec(centerHz: $0.centerFrequencyHz, matchedWidthOctaves: $0.bandwidthOctaves) }
        }
        return EarPitches(leftNotches: notches(left), rightNotches: notches(right))
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

    /// The newest matches that fit in one profile, newest first: each match is added only while no
    /// ear goes over `limit`. Used to turn the old Automatic mode into a profile.
    public static func newestFitting(_ matches: [TinnitusProfile], sameForBothEars: Bool, limit: Int = NotchDesign.maxNotchesPerEar) -> [TinnitusProfile] {
        var chosen: [TinnitusProfile] = []
        for match in matches.sorted(by: { $0.date > $1.date }) {
            let candidate = combining(chosen + [match], sameForBothEars: sameForBothEars)
            if candidate.left.count <= limit && candidate.right.count <= limit {
                chosen.append(match)
            }
        }
        return chosen
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

/// The notches for each ear, lowest pitch first. An empty side is unfiltered.
public struct EarPitches: Equatable, Hashable, Sendable {
    public var leftNotches: [NotchSpec]
    public var rightNotches: [NotchSpec]

    public init(leftNotches: [NotchSpec], rightNotches: [NotchSpec]) {
        self.leftNotches = leftNotches.sorted { $0.centerHz < $1.centerHz }
        self.rightNotches = rightNotches.sorted { $0.centerHz < $1.centerHz }
    }

    /// Pure-tone notches at these pitches.
    public init(left: [Double], right: [Double]) {
        self.init(leftNotches: left.map { NotchSpec(centerHz: $0) }, rightNotches: right.map { NotchSpec(centerHz: $0) })
    }

    /// One pure-tone notch (or none) per ear.
    public init(left: Double?, right: Double?) {
        self.init(left: left.map { [$0] } ?? [], right: right.map { [$0] } ?? [])
    }

    public static let none = EarPitches(leftNotches: [], rightNotches: [])

    /// Notch centers in Hz, lowest first.
    public var left: [Double] { leftNotches.map(\.centerHz) }
    public var right: [Double] { rightNotches.map(\.centerHz) }

    public var isEmpty: Bool { leftNotches.isEmpty && rightNotches.isEmpty }
    public var isSameInBothEars: Bool { leftNotches == rightNotches }

    public func centers(for ear: Ear) -> [Double] { ear == .right ? right : left }
    public func notches(for ear: Ear) -> [NotchSpec] { ear == .right ? rightNotches : leftNotches }

    /// Every notch from both ears, for a mono source that can't separate them.
    public var allNotches: [NotchSpec] {
        (leftNotches + rightNotches.filter { !leftNotches.contains($0) }).sorted { $0.centerHz < $1.centerHz }
    }

    /// Band-stop coefficients for one side, empty when that side is unfiltered. Each notch is as wide as
    /// its matched sound plus a margin, and at least `widthOctaves`. Overlapping notches merge.
    public func notch(for ear: Ear, widthOctaves: Double, sampleRate: Double) -> [BiquadCoefficients] {
        NotchDesign.forTinnitus(notches: notches(for: ear), minimumWidthOctaves: widthOctaves, sampleRate: sampleRate)
    }

    /// Band-stop coefficients for both ears' notches together.
    public func combinedNotch(widthOctaves: Double, sampleRate: Double) -> [BiquadCoefficients] {
        NotchDesign.forTinnitus(notches: allNotches, minimumWidthOctaves: widthOctaves, sampleRate: sampleRate)
    }
}
