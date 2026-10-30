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
