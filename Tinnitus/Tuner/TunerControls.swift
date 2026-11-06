import SwiftUI
import TinnitusCore

/// Pieces shared by the tuner layouts.
struct TunerCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct TunerLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// Octave down, a quarter semitone down, up, and octave up.
struct PitchNudgeRow: View {
    let model: TunerModel

    var body: some View {
        HStack(spacing: 8) {
            nudge("Octave ↓", label: "Octave down") { model.octave(up: false) }
            nudge("−", label: "Lower pitch slightly") { model.nudgePitch(semitones: -0.25) }
            nudge("+", label: "Raise pitch slightly") { model.nudgePitch(semitones: 0.25) }
            nudge("Octave ↑", label: "Octave up") { model.octave(up: true) }
        }
    }

    private func nudge(_ title: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label)
    }
}

/// Halve, narrow slightly, widen slightly, and double the width, like the pitch buttons.
struct WidthNudgeRow: View {
    let model: TunerModel

    var body: some View {
        HStack(spacing: 8) {
            nudge("Width ÷2", label: "Halve width") { model.scaleWidth(by: 0.5) }
            nudge("−", label: "Narrower slightly") { model.nudgeWidth(by: -0.04) }
            nudge("+", label: "Wider slightly") { model.nudgeWidth(by: 0.04) }
            nudge("Width ×2", label: "Double width") { model.scaleWidth(by: 2) }
        }
    }

    private func nudge(_ title: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label)
    }
}

struct EarPicker: View {
    @Bindable var model: TunerModel

    var body: some View {
        Picker("Ear", selection: $model.ear) {
            ForEach([Ear.left, .both, .right], id: \.self) { ear in
                Text(ear.shortTitle).tag(ear)
            }
        }
        .pickerStyle(.segmented)
    }
}

enum TunerText {
    static func loudness(_ model: TunerModel) -> String {
        if let threshold = model.knownThresholdDBFS {
            let above = model.levelDBFS - threshold
            return above >= 0 ? "+\(Format.level(above)) above threshold" : "\(Format.level(-above)) below threshold"
        }
        return "Level \(Format.level(model.levelDBFS))"
    }

    static func loudnessShort(_ model: TunerModel) -> String {
        if let threshold = model.knownThresholdDBFS {
            let above = model.levelDBFS - threshold
            return above >= 0 ? "+\(Format.level(above))" : "−\(Format.level(-above))"
        }
        return Format.level(model.levelDBFS)
    }

    static func width(_ model: TunerModel) -> String {
        model.bandwidthOctaves <= 0 ? "Pure tone" : "\(model.soundType.title) · \(Format.bandwidth(model.bandwidthOctaves))"
    }
}

/// VoiceOver controls for pitch: swipe up or down to nudge it by a semitone.
struct PitchAccessibility: ViewModifier {
    let model: TunerModel

    func body(content: Content) -> some View {
        content
            .accessibilityElement()
            .accessibilityLabel("Pitch")
            .accessibilityValue(Format.frequency(model.pitchHz))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: model.nudgePitch(semitones: 1)
                case .decrement: model.nudgePitch(semitones: -1)
                @unknown default: break
                }
            }
    }
}

/// Octave labels placed under their gridlines on the tuner's log pitch axis.
struct PitchAxisLabels: View {
    let width: CGFloat

    var body: some View {
        ZStack {
            ForEach([500.0, 1000, 2000, 4000, 8000], id: \.self) { hz in
                Text(hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))")
                    .position(x: TunerMath.pitchPosition(hz) * width, y: 10)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(width: width, height: 20)
        .allowsHitTesting(false)
    }
}
