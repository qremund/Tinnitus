import SwiftUI
import TinnitusCore

extension Color {
    init(_ rgb: RGB) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}

/// The log frequency bar used in every notch diagram: a track with octave gridlines, shaded bands for
/// what the notch removes, and a tick at each match's pitch. Positions come from `NotchScale`.
struct NotchBar: View {
    let bands: [(low: Double, high: Double)]
    let ticksHz: [Double]
    var height: CGFloat = 30
    var dimmed = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let x = { (hz: Double) in CGFloat(min(1, max(0, NotchScale.position(hz)))) * width }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Color(.systemGray5))
                ForEach(NotchScale.gridHz, id: \.self) { hz in
                    Rectangle().fill(Color(.systemGray3)).frame(width: 1, height: height).offset(x: x(hz))
                }
                ForEach(Array(bands.enumerated()), id: \.offset) { _, band in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(dimmed ? Color(.systemGray2) : Color(MatchPalette.notch))
                        .frame(width: max(x(band.high) - x(band.low), 3), height: height)
                        .offset(x: x(band.low))
                }
                ForEach(Array(ticksHz.enumerated()), id: \.offset) { _, hz in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(dimmed ? Color(.systemGray) : Color.primary)
                        .frame(width: 3, height: height - 8)
                        .offset(x: x(hz) - 1.5, y: 4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .frame(height: height)
    }
}

/// "250 Hz · 1 kHz · 4 kHz · 16 kHz" under a notch bar.
struct NotchAxisLabels: View {
    var body: some View {
        HStack {
            Text("250 Hz")
            Spacer()
            Text("1 kHz")
            Spacer()
            Text("4 kHz")
            Spacer()
            Text("16 kHz")
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

/// One ear's combined notches, drawn only: "Left Notch Removes" over the bar.
struct EarNotchDiagram: View {
    let ear: Ear
    let matches: [TinnitusProfile]
    let minimumWidthOctaves: Double
    var dimmed = false

    private var title: String { ear == .right ? "Right Notch Removes" : "Left Notch Removes" }

    var body: some View {
        let notches = matches.map { NotchSpec(centerHz: $0.centerFrequencyHz, matchedWidthOctaves: $0.bandwidthOctaves) }
        let bands = NotchDesign.bands(notches: notches, minimumWidthOctaves: minimumWidthOctaves)
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            NotchBar(bands: bands, ticksHz: matches.map(\.centerFrequencyHz), dimmed: dimmed)
            NotchAxisLabels()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(bands.isEmpty
            ? "Nothing removed"
            : bands.map { "\(Format.frequency($0.low)) to \(Format.frequency($0.high))" }.formatted(.list(type: .and)) + (dimmed ? ", notch off" : ""))
    }
}

/// The left and right diagrams together, for the active profile.
struct EarNotchDiagrams: View {
    let ears: EarProfiles
    let minimumWidthOctaves: Double
    var dimmed = false

    var body: some View {
        VStack(spacing: 14) {
            EarNotchDiagram(ear: .left, matches: ears.left, minimumWidthOctaves: minimumWidthOctaves, dimmed: dimmed)
            EarNotchDiagram(ear: .right, matches: ears.right, minimumWidthOctaves: minimumWidthOctaves, dimmed: dimmed)
        }
    }
}

/// A saved match as a colored strip (ear, pitch, width) over its own notch bar.
struct MatchRow: View {
    let match: TinnitusProfile
    let minimumWidthOctaves: Double

    var body: some View {
        let width = NotchDesign.notchWidth(matchedOctaves: match.bandwidthOctaves, minimumOctaves: minimumWidthOctaves)
        let edges = PitchMatching.notchEdges(centerHz: match.centerFrequencyHz, widthOctaves: width)
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                tile(match.ear.shortTitle, color: MatchPalette.ear(match.ear)).frame(width: 64)
                tile(Format.frequency(match.centerFrequencyHz), color: MatchPalette.pitch(match.centerFrequencyHz))
                tile(Format.shortBandwidth(match.bandwidthOctaves), color: MatchPalette.width(match.bandwidthOctaves))
            }
            .frame(height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Notch removes")
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Format.frequency(edges.low)) – \(Format.frequency(edges.high))")
                        .font(.footnote.weight(.semibold).monospacedDigit())
                }
                NotchBar(bands: [edges], ticksHz: [match.centerFrequencyHz], height: 12)
                NotchAxisLabels()
            }
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 5)
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(match.ear.shortTitle) ear, \(Format.frequency(match.centerFrequencyHz)), \(Format.bandwidth(match.bandwidthOctaves))")
        .accessibilityValue("Notch removes \(Format.frequency(edges.low)) to \(Format.frequency(edges.high))")
    }

    private func tile(_ text: String, color: RGB) -> some View {
        Text(text)
            .font(.subheadline.bold().monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(Color(color.readableText))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(color))
    }
}
