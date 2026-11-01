import SwiftUI
import TinnitusCore

/// Picks which saved match sets the notch for each ear, in Play and Music.
struct MatchChooser: View {
    @Environment(ProfileStore.self) private var store

    var body: some View {
        if !store.profiles.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if store.sameForBothEars {
                    row("Both ears", ear: .both, choice: store.leftChoice == store.rightChoice ? store.leftChoice : nil)
                } else {
                    row("Left ear", ear: .left, choice: store.leftChoice)
                    row("Right ear", ear: .right, choice: store.rightChoice)
                }
            }
        }
    }

    private func row(_ title: String, ear: Ear, choice: UUID?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Menu {
                Button {
                    store.choose(nil, for: ear)
                } label: {
                    if choice == nil {
                        Label("Automatic (recent median)", systemImage: "checkmark")
                    } else {
                        Text("Automatic (recent median)")
                    }
                }
                // Matches made for this ear (or both) come first; the other ear's are listed apart.
                let own = store.profiles.filter { ear == .both || $0.ear == ear || $0.ear == .both }
                let other = store.profiles.filter { !(ear == .both || $0.ear == ear || $0.ear == .both) }
                Section(ear == .both ? "Saved matches" : "Matched for this ear") {
                    ForEach(own) { option($0, ear: ear, choice: choice) }
                }
                if !other.isEmpty {
                    Section("Matched for the other ear") {
                        ForEach(other) { option($0, ear: ear, choice: choice) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(label(for: choice))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                }
            }
            .accessibilityLabel("\(title) match")
            .accessibilityValue(label(for: choice))
        }
    }

    private func option(_ profile: TinnitusProfile, ear: Ear, choice: UUID?) -> some View {
        Button {
            store.choose(profile.id, for: ear)
        } label: {
            if choice == profile.id {
                Label("\(Format.matchTitle(profile)) · \(Format.matchSummary(profile))", systemImage: "checkmark")
            } else {
                Text("\(Format.matchTitle(profile)) · \(Format.matchSummary(profile))")
            }
        }
    }

    private func label(for choice: UUID?) -> String {
        guard let choice, let profile = store.profiles.first(where: { $0.id == choice }) else { return "Automatic" }
        return Format.matchTitle(profile)
    }
}
