import Foundation
import TinnitusCore

enum Format {
    static func frequency(_ hz: Double) -> String {
        hz >= 1000 ? String(format: "%.2f kHz", hz / 1000) : String(format: "%.0f Hz", hz)
    }

    static func bandwidth(_ octaves: Double) -> String {
        if octaves <= 0 { return "Pure tone" }
        if octaves >= 0.99 { return "1 octave" }
        return "1/\(Int((1 / octaves).rounded())) octave"
    }

    static func level(_ db: Double) -> String {
        "\(Int(db.rounded())) dB"
    }

    /// The band the notch removes, like "4.24 kHz to 8.49 kHz".
    static func notchRange(centerHz: Double, widthOctaves: Double) -> String {
        let edges = PitchMatching.notchEdges(centerHz: centerHz, widthOctaves: widthOctaves)
        return "\(frequency(edges.low)) to \(frequency(edges.high))"
    }

    /// One ear's notches for summaries, like "2.12 kHz to 4.24 kHz and 5.66 kHz to 6.73 kHz",
    /// with overlapping notches merged. Each notch is its match's width plus a margin, and at least
    /// `minimumWidthOctaves`. "unfiltered" when that ear has no match.
    static func earNotch(_ notches: [NotchSpec], minimumWidthOctaves: Double) -> String {
        let bands = NotchDesign.bands(notches: notches, minimumWidthOctaves: minimumWidthOctaves)
        guard !bands.isEmpty else { return "unfiltered" }
        return bands.map { "\(frequency($0.low)) to \(frequency($0.high))" }.formatted(.list(type: .and))
    }

    /// The notches for these matches, as in `earNotch(_:minimumWidthOctaves:)`.
    static func earNotch(matches: [TinnitusProfile], minimumWidthOctaves: Double) -> String {
        earNotch(matches.map { NotchSpec(centerHz: $0.centerFrequencyHz, matchedWidthOctaves: $0.bandwidthOctaves) }, minimumWidthOctaves: minimumWidthOctaves)
    }

    /// A phone volume as a percentage, like "70%".
    static func volume(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// Pitches as a short list, like "3.10 kHz and 6.20 kHz".
    static func pitches(_ centersHz: [Double]) -> String {
        centersHz.map(frequency).formatted(.list(type: .and))
    }

    /// A saved match's name, or its date when it has none.
    static func matchTitle(_ profile: TinnitusProfile) -> String {
        profile.name ?? profile.date.formatted(.dateTime.month().day().hour().minute())
    }

    /// One line describing a saved match.
    static func matchSummary(_ profile: TinnitusProfile) -> String {
        "\(profile.ear.shortTitle) · \(frequency(profile.centerFrequencyHz)) · \(bandwidth(profile.bandwidthOctaves))"
    }

    /// Minutes and seconds, like 3:07.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0).rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension Ear {
    var title: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .both: "Both / in my head"
        }
    }

    var shortTitle: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .both: "Both"
        }
    }
}

extension TinnitusSoundType {
    var title: String {
        switch self {
        case .tone: "Tone or whine"
        case .narrowHiss: "Narrow hiss"
        case .broadHiss: "Broad hiss"
        }
    }

    var detail: String {
        switch self {
        case .tone: "A clear pitch, like a whistle or a TV whine."
        case .narrowHiss: "A pitched hiss or buzz, like steam from a kettle."
        case .broadHiss: "A wide rush, like wind or a distant waterfall."
        }
    }
}

extension SleepSound {
    var title: String {
        switch self {
        case .white: "White noise"
        case .pink: "Pink noise"
        case .brown: "Brown noise"
        case .rain: "Rain"
        case .ocean: "Ocean"
        case .fan: "Fan"
        }
    }

    var systemImage: String {
        switch self {
        case .white: "waveform"
        case .pink: "waveform.path"
        case .brown: "water.waves"
        case .rain: "cloud.rain"
        case .ocean: "beach.umbrella"
        case .fan: "fan"
        }
    }
}
