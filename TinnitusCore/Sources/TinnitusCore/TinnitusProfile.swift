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

    /// How many of the newest matches Automatic mode looks at for each ear.
    public static let automaticRecentMatches = 6
    /// Matches closer than this in pitch are treated as the same sound.
    public static let samePitchOctaves = 0.5

    /// Automatic mode: each ear looks at its newest `automaticRecentMatches` matches, groups them by
    /// pitch, and gets one median per group from that group's newest `sessions` matches. So two
    /// different tinnitus pitches in one ear each get their own notch instead of one notch between them.
    /// Left and right matches count for their own ear and "both" matches count for both. With
    /// `sameForBothEars`, every match counts for both ears and the two sides get the same notches.
    public static func from(_ profiles: [TinnitusProfile], sameForBothEars: Bool, sessions: Int = 3) -> EarProfiles {
        let newestFirst = profiles.sorted { $0.date > $1.date }
        if sameForBothEars {
            let shared = medians(of: Array(newestFirst.prefix(automaticRecentMatches)), sessions: sessions)
            return EarProfiles(left: shared, right: shared)
        }
        func side(_ ear: Ear) -> [TinnitusProfile] {
            medians(of: Array(newestFirst.filter { $0.ear == ear || $0.ear == .both }.prefix(automaticRecentMatches)), sessions: sessions)
        }
        return EarProfiles(left: side(.left), right: side(.right))
    }

    /// Groups matches by pitch, then takes the median of each group's newest `sessions` matches.
    static func medians(of matches: [TinnitusProfile], sessions: Int) -> [TinnitusProfile] {
        pitchGroups(matches).compactMap { group in
            TinnitusProfile.consensus(of: Array(group.sorted { $0.date > $1.date }.prefix(sessions)))
        }
    }

    /// Splits matches into groups where neighbors in pitch are less than `samePitchOctaves` apart.
    static func pitchGroups(_ matches: [TinnitusProfile]) -> [[TinnitusProfile]] {
        var groups: [[TinnitusProfile]] = []
        for match in matches.filter({ $0.centerFrequencyHz > 0 }).sorted(by: { $0.centerFrequencyHz < $1.centerFrequencyHz }) {
            if let last = groups.last?.last, log2(match.centerFrequencyHz / last.centerFrequencyHz) < samePitchOctaves {
                groups[groups.count - 1].append(match)
            } else {
                groups.append([match])
            }
        }
        return groups
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
