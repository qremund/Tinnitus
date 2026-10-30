import SwiftUI

/// The Match tab: the quick one-screen tuner or the guided step-by-step match.
struct MatchHomeView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        TunerView()
                    } label: {
                        choice("Quick tune", detail: "Adjust pitch, width, loudness, and ear on one screen while the sound plays.", systemImage: "slider.horizontal.3")
                    }
                    NavigationLink {
                        MatchFlowView()
                    } label: {
                        choice("Guided match", detail: "Step by step, about 10 to 15 minutes. Best for your first match.", systemImage: "list.number")
                    }
                } footer: {
                    Text("Use earbuds or headphones in a quiet room, with your phone volume at the same setting each time.")
                }
            }
            .navigationTitle("Match")
        }
    }

    private func choice(_ title: String, detail: String, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
        }
        .padding(.vertical, 6)
    }
}
