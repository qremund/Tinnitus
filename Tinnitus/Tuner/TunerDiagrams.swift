import SwiftUI
import TinnitusCore

/// One notch on the match screen's diagrams: a saved match from the active profile, or the new one.
struct TunerNotch: Identifiable {
    let id: TunerModel.Selection
    let title: String
    let centerHz: Double
    let ear: Ear
    let low: Double
    let high: Double
    let isOn: Bool
    let isUnsaved: Bool
    let isSelected: Bool

    /// Every notch the diagrams show. The selected match is drawn where the controls put it now.
    @MainActor
    static func all(for model: TunerModel, minimumWidthOctaves: Double) -> [TunerNotch] {
        func make(_ id: TunerModel.Selection, title: String, hz: Double, octaves: Double, ear: Ear, isOn: Bool, isUnsaved: Bool) -> TunerNotch {
            let width = NotchDesign.notchWidth(matchedOctaves: octaves, minimumOctaves: minimumWidthOctaves)
            let edges = PitchMatching.notchEdges(centerHz: hz, widthOctaves: width)
            return TunerNotch(id: id, title: title, centerHz: hz, ear: ear, low: edges.low, high: edges.high,
                              isOn: isOn, isUnsaved: isUnsaved, isSelected: id == model.selection)
        }
        var notches = model.profileMatches.map { match -> TunerNotch in
            let id = TunerModel.Selection.match(match.id)
            if id == model.selection {
                return make(id, title: Format.matchTitle(match), hz: model.pitchHz, octaves: model.bandwidthOctaves, ear: model.ear,
                            isOn: model.isSoundOn, isUnsaved: model.hasUnsavedChanges)
            }
            return make(id, title: Format.matchTitle(match), hz: match.centerFrequencyHz, octaves: match.bandwidthOctaves, ear: match.ear,
                        isOn: model.isOn(match.id), isUnsaved: false)
        }
        if model.isNew {
            notches.append(make(.new, title: "New match", hz: model.pitchHz, octaves: model.bandwidthOctaves, ear: model.ear,
                                isOn: model.isSoundOn, isUnsaved: true))
        }
        return notches
    }

    func shows(in ear: Ear, sameForBothEars: Bool) -> Bool {
        sameForBothEars || self.ear == .both || self.ear == ear
    }
}

/// The Left and Right diagrams under the match controls. Tap a notch to select it; tap again where
/// notches overlap to step through them.
struct TunerDiagrams: View {
    let model: TunerModel
    let sameForBothEars: Bool
    let onSelect: (TunerModel.Selection) -> Void
    @AppStorage("notchWidthOctaves") private var notchWidthOctaves = NotchDesign.followMatchMinimumOctaves

    var body: some View {
        let notches = TunerNotch.all(for: model, minimumWidthOctaves: notchWidthOctaves)
        VStack(spacing: 6) {
            SelectableEarDiagram(ear: .left, notches: notches.filter { $0.shows(in: .left, sameForBothEars: sameForBothEars) },
                                 selection: model.selection, onSelect: onSelect)
            SelectableEarDiagram(ear: .right, notches: notches.filter { $0.shows(in: .right, sameForBothEars: sameForBothEars) },
                                 selection: model.selection, onSelect: onSelect)
            legend
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            swatch(MatchPalette.savedNotch, "Saved")
            swatch(MatchPalette.unsavedNotch, "Unsaved")
            Text("Faded is off. Tap a notch to edit it.")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private func swatch(_ color: RGB, _ title: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(Color(color)).frame(width: 10, height: 10)
            Text(title)
        }
    }
}

/// One ear's notches, each drawn on its own so it can be tapped.
struct SelectableEarDiagram: View {
    let ear: Ear
    let notches: [TunerNotch]
    let selection: TunerModel.Selection
    let onSelect: (TunerModel.Selection) -> Void
    var height: CGFloat = 24

    private var title: String { ear == .right ? "Right Notch Removes" : "Left Notch Removes" }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            GeometryReader { geometry in
                let width = geometry.size.width
                let x = { (hz: Double) in CGFloat(min(1, max(0, NotchScale.position(hz)))) * width }
                // The selected notch is drawn last, so its outline is never hidden.
                let ordered = notches.filter { !$0.isSelected } + notches.filter(\.isSelected)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6).fill(Color(.systemGray5))
                    ForEach(NotchScale.gridHz, id: \.self) { hz in
                        Rectangle().fill(Color(.systemGray3)).frame(width: 1, height: height).offset(x: x(hz))
                    }
                    ForEach(ordered) { notch in
                        let color = Color(notch.isUnsaved ? MatchPalette.unsavedNotch : MatchPalette.savedNotch)
                        let bandWidth = max(x(notch.high) - x(notch.low), 4)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(color.opacity(notch.isOn ? 0.9 : 0.3))
                            .overlay {
                                if notch.isSelected {
                                    RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary, lineWidth: 2.5)
                                }
                            }
                            .frame(width: bandWidth, height: height)
                            .offset(x: x(notch.low))
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.primary.opacity(notch.isOn ? 0.9 : 0.4))
                            .frame(width: 2, height: height - 8)
                            .offset(x: x(notch.centerHz) - 1, y: 4)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard width > 0 else { return }
                    let candidates = notches.map { NotchPicker.Notch(id: $0.id, lowHz: $0.low, highHz: $0.high) }
                    let hits = NotchPicker.hits(at: location.x / width, in: candidates, minimumSpan: 32 / width)
                    if let picked = NotchPicker.pick(hits, current: selection) { onSelect(picked) }
                }
            }
            .frame(height: height)
            NotchAxisLabels()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(notches.isEmpty
            ? "Nothing removed"
            : notches.map { "\($0.title), \(Format.frequency($0.low)) to \(Format.frequency($0.high))\($0.isOn ? "" : ", off")\($0.isSelected ? ", selected" : "")" }
                .formatted(.list(type: .and)))
        .accessibilityActions {
            ForEach(notches) { notch in
                Button("Select \(notch.title)") { onSelect(notch.id) }
            }
        }
    }
}
