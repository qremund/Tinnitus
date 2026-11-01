import SwiftUI
import TinnitusCore

// MARK: A. Four sliders

struct SlidersLayout: View {
    @Bindable var model: TunerModel

    var body: some View {
        VStack(spacing: 12) {
            TunerCard {
                HStack(alignment: .firstTextBaseline) {
                    TunerLabel(title: "Pitch")
                    Spacer()
                    Text(Format.frequency(model.pitchHz))
                        .font(.title2.bold().monospacedDigit())
                }
                Slider(value: $model.pitchPosition) {
                    Text("Pitch")
                } minimumValueLabel: {
                    Text("250 Hz").font(.caption2)
                } maximumValueLabel: {
                    Text("16 kHz").font(.caption2)
                }
                .accessibilityValue(Format.frequency(model.pitchHz))
                PitchNudgeRow(model: model)
            }

            TunerCard {
                HStack(alignment: .firstTextBaseline) {
                    TunerLabel(title: "Width")
                    Spacer()
                    Text(TunerText.width(model))
                        .font(.headline)
                }
                Slider(value: $model.widthPosition) {
                    Text("Width")
                } minimumValueLabel: {
                    Text("Tone").font(.caption2)
                } maximumValueLabel: {
                    Text("Wide").font(.caption2)
                }
                .accessibilityValue(TunerText.width(model))
                WidthNudgeRow(model: model)
            }

            TunerCard {
                HStack(alignment: .firstTextBaseline) {
                    TunerLabel(title: "Loudness")
                    Spacer()
                    Text(TunerText.loudness(model))
                        .font(.headline.monospacedDigit())
                }
                Slider(value: $model.levelPosition) {
                    Text("Loudness")
                } minimumValueLabel: {
                    Image(systemName: "speaker.fill").font(.caption)
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3.fill").font(.caption)
                }
                .accessibilityValue(TunerText.loudness(model))
            }
        }
    }
}

// MARK: B. Pitch and width pad

struct PadLayout: View {
    @Bindable var model: TunerModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    TunerLabel(title: "Pitch")
                    Text(Format.frequency(model.pitchHz)).font(.title.bold().monospacedDigit())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    TunerLabel(title: "Width")
                    Text(model.bandwidthOctaves <= 0 ? "Pure tone" : Format.bandwidth(model.bandwidthOctaves))
                        .font(.title3.bold())
                }
            }

            GeometryReader { geometry in
                let size = geometry.size
                // Keep the dot fully inside the pad at the extremes.
                let inset: CGFloat = 18
                let usableWidth = size.width - 2 * inset
                let usableHeight = size.height - 2 * inset - 20
                let x = inset + model.pitchPosition * usableWidth
                let y = inset + (1 - model.widthPosition) * usableHeight
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground))
                    Canvas { context, canvasSize in
                        // One line per octave from 500 Hz to 8 kHz.
                        for hz in [500.0, 1000, 2000, 4000, 8000] {
                            let lineX = inset + TunerMath.pitchPosition(hz) * usableWidth
                            context.stroke(Path { $0.move(to: CGPoint(x: lineX, y: 0)); $0.addLine(to: CGPoint(x: lineX, y: canvasSize.height - 20)) }, with: .color(.secondary.opacity(0.25)))
                        }
                        context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: canvasSize.height)) }, with: .color(.accentColor.opacity(0.4)), lineWidth: 2)
                        context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: canvasSize.width, y: y)) }, with: .color(.accentColor.opacity(0.4)), lineWidth: 2)
                    }
                    Circle()
                        .fill(.white)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: 3))
                        .frame(width: 30, height: 30)
                        .position(x: x, y: y)
                    Text("Broad hiss").font(.caption).foregroundStyle(.secondary).padding(10)
                    Text("Pure tone").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 24)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    PitchAxisLabels(width: usableWidth)
                        .offset(x: inset, y: size.height - 22)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    model.pitchPosition = (value.location.x - inset) / usableWidth
                    model.widthPosition = 1 - (value.location.y - inset) / usableHeight
                })
                .modifier(PitchAccessibility(model: model))
            }
            .frame(minHeight: 220)

            PitchNudgeRow(model: model)
            WidthNudgeRow(model: model)

            TunerCard {
                HStack {
                    TunerLabel(title: "Loudness")
                    Spacer()
                    Text(TunerText.loudness(model)).font(.headline.monospacedDigit())
                }
                Slider(value: $model.levelPosition) { Text("Loudness") }
                    .accessibilityValue(TunerText.loudness(model))
            }
        }
    }
}

// MARK: C. Drag the band

struct BandLayout: View {
    @Bindable var model: TunerModel

    private enum DragMode {
        case move(startPitch: Double, startLevel: Double)
        case width
    }

    @State private var dragMode: DragMode?

    var body: some View {
        VStack(spacing: 12) {
            Text("Drag the band sideways for pitch and up or down for loudness. Drag its edges for width.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            GeometryReader { geometry in
                let size = geometry.size
                let plotHeight = size.height - 24
                let centerX = model.pitchPosition * size.width
                let halfWidth = max(model.bandwidthOctaves / 2 / 6 * size.width, 4)
                let top = (1 - model.levelPosition) * plotHeight
                // The width handles stay a finger's width apart even for a pure tone.
                let handleOffset = max(halfWidth, 24)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground))
                    Canvas { context, canvasSize in
                        for hz in [500.0, 1000, 2000, 4000, 8000] {
                            let lineX = TunerMath.pitchPosition(hz) * canvasSize.width
                            context.stroke(Path { $0.move(to: CGPoint(x: lineX, y: 0)); $0.addLine(to: CGPoint(x: lineX, y: plotHeight)) }, with: .color(.secondary.opacity(0.2)))
                        }
                        if let threshold = model.knownThresholdDBFS {
                            let thresholdY = (1 - TunerMath.levelPosition(threshold)) * plotHeight
                            context.stroke(
                                Path { $0.move(to: CGPoint(x: 0, y: thresholdY)); $0.addLine(to: CGPoint(x: canvasSize.width, y: thresholdY)) },
                                with: .color(.secondary),
                                style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])
                            )
                        }
                        // A bell-shaped band: its position is pitch, its spread is width, its height is loudness.
                        var band = Path()
                        band.move(to: CGPoint(x: centerX - halfWidth * 1.8, y: plotHeight))
                        band.addCurve(
                            to: CGPoint(x: centerX, y: top),
                            control1: CGPoint(x: centerX - halfWidth * 0.7, y: plotHeight),
                            control2: CGPoint(x: centerX - halfWidth * 0.6, y: top)
                        )
                        band.addCurve(
                            to: CGPoint(x: centerX + halfWidth * 1.8, y: plotHeight),
                            control1: CGPoint(x: centerX + halfWidth * 0.6, y: top),
                            control2: CGPoint(x: centerX + halfWidth * 0.7, y: plotHeight)
                        )
                        band.closeSubpath()
                        context.fill(band, with: .color(.accentColor.opacity(0.3)))
                        context.stroke(band, with: .color(.accentColor), lineWidth: 2)
                    }
                    Circle().fill(.white).overlay(Circle().stroke(Color.accentColor, lineWidth: 3))
                        .frame(width: 26, height: 26)
                        .position(x: centerX, y: top)
                    ForEach([-1.0, 1.0], id: \.self) { side in
                        Circle().fill(Color(.systemBackground)).overlay(Circle().stroke(.primary, lineWidth: 2))
                            .frame(width: 18, height: 18)
                            .position(x: min(max(centerX + side * handleOffset, 12), size.width - 12), y: (top + plotHeight) / 2)
                    }
                    PitchAxisLabels(width: size.width)
                        .offset(y: plotHeight + 2)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragMode == nil {
                            // Grabbing near an edge handle adjusts width; anywhere else moves the band.
                            let distance = abs(abs(value.startLocation.x - centerX) - handleOffset)
                            let nearEdge = distance < 22 && abs(value.startLocation.x - centerX) > 12
                            dragMode = nearEdge ? .width : .move(startPitch: model.pitchPosition, startLevel: model.levelPosition)
                        }
                        switch dragMode {
                        case let .move(startPitch, startLevel)?:
                            model.pitchPosition = startPitch + value.translation.width / size.width
                            model.levelPosition = startLevel - value.translation.height / plotHeight
                        case .width?:
                            // Measured from the handle's resting spot, so a narrow band widens smoothly from where you grabbed it.
                            let pulled = max(abs(value.location.x - centerX) - (handleOffset - halfWidth), 0)
                            let octaves = pulled / size.width * 6 * 2
                            model.widthPosition = octaves < 1.0 / 48 ? 0 : PitchMatching.sliderPosition(bandwidthOctaves: min(octaves, 1))
                        case nil:
                            break
                        }
                    }
                    .onEnded { _ in dragMode = nil }
                )
                .modifier(PitchAccessibility(model: model))
            }
            .frame(minHeight: 220)

            HStack(spacing: 8) {
                tile("Pitch", Format.frequency(model.pitchHz))
                tile("Width", model.bandwidthOctaves <= 0 ? "Tone" : Format.bandwidth(model.bandwidthOctaves))
                tile("Loudness", TunerText.loudnessShort(model))
            }

            PitchNudgeRow(model: model)
            WidthNudgeRow(model: model)
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

// MARK: D. Two dials

struct DialLayout: View {
    @Bindable var model: TunerModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 10) {
                    TunerLabel(title: "Pitch")
                    TunerDial(
                        fraction: $model.pitchPosition,
                        value: model.pitchHz >= 1000 ? String(format: "%.2f", model.pitchHz / 1000) : String(format: "%.0f", model.pitchHz),
                        unit: model.pitchHz >= 1000 ? "kHz" : "Hz",
                        label: "Pitch dial"
                    ) { up in
                        model.nudgePitch(semitones: up ? 1 : -1)
                    }
                    grid([
                        ("÷2", "Octave down", { model.octave(up: false) }),
                        ("×2", "Octave up", { model.octave(up: true) }),
                        ("−", "Lower pitch slightly", { model.nudgePitch(semitones: -0.25) }),
                        ("+", "Raise pitch slightly", { model.nudgePitch(semitones: 0.25) }),
                    ])
                }
                VStack(spacing: 10) {
                    TunerLabel(title: "Width")
                    TunerDial(
                        fraction: $model.widthPosition,
                        value: model.bandwidthOctaves <= 0 ? "Tone" : Format.bandwidth(model.bandwidthOctaves).replacingOccurrences(of: " octave", with: ""),
                        unit: model.bandwidthOctaves <= 0 ? "pure" : "octave",
                        label: "Width dial"
                    ) { up in
                        model.nudgeWidth(by: up ? 0.04 : -0.04)
                    }
                    grid([
                        ("÷2", "Halve width", { model.scaleWidth(by: 0.5) }),
                        ("×2", "Double width", { model.scaleWidth(by: 2) }),
                        ("−", "Narrower slightly", { model.nudgeWidth(by: -0.04) }),
                        ("+", "Wider slightly", { model.nudgeWidth(by: 0.04) }),
                    ])
                }
            }

            TunerCard {
                HStack {
                    TunerLabel(title: "Loudness")
                    Spacer()
                    Text(TunerText.loudness(model)).font(.headline.monospacedDigit())
                }
                Slider(value: $model.levelPosition) {
                    Text("Loudness")
                } minimumValueLabel: {
                    Image(systemName: "speaker.fill").font(.caption)
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3.fill").font(.caption)
                }
                .accessibilityValue(TunerText.loudness(model))
            }
        }
    }

    private func grid(_ buttons: [(String, String, () -> Void)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(buttons.indices, id: \.self) { index in
                let button = buttons[index]
                Button(action: button.2) {
                    Text(button.0).font(.title3.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(button.1)
            }
        }
    }
}

/// A round dial over a 270 degree sweep. Drag around it to set the value; VoiceOver swipes step it.
struct TunerDial: View {
    @Binding var fraction: Double
    let value: String
    let unit: String
    let label: String
    let step: (Bool) -> Void

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let angle = TunerMath.dialAngleDegrees(fraction: fraction) * .pi / 180
            ZStack {
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(TunerMath.dialStartDegrees))
                Circle()
                    .trim(from: 0, to: 0.75 * fraction)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(TunerMath.dialStartDegrees))
                Circle()
                    .fill(.white)
                    .frame(width: 22, height: 22)
                    .shadow(radius: 2)
                    .offset(x: cos(angle) * (size / 2 - 6), y: sin(angle) * (size / 2 - 6))
                VStack(spacing: 0) {
                    Text(value)
                        .font(.system(size: 26, weight: .bold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(unit).font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: size * 0.62)
            }
            .padding(6)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let dx = drag.location.x - geometry.size.width / 2
                let dy = drag.location.y - geometry.size.height / 2
                guard dx * dx + dy * dy > 24 * 24 else { return }
                fraction = TunerMath.dialFraction(dx: dx, dy: dy)
            })
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue("\(value) \(unit)")
            .accessibilityAdjustableAction { direction in
                step(direction == .increment)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
