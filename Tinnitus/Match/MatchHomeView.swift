import SwiftUI

/// The Match tab: four ways to tune your match, each on one screen.
struct MatchHomeView: View {
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Pick a way to tune. Each one adjusts pitch, width, loudness, and ear while the sound plays.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(TunerLayout.allCases) { layout in
                            NavigationLink {
                                TunerView(layout: layout)
                            } label: {
                                tile(layout)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Text("Use earbuds or headphones in a quiet room, with your phone volume at the same setting each time. Saving a few matches on different days gives a steadier result.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Match")
        }
    }

    private func tile(_ layout: TunerLayout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: layout.systemImage)
                .font(.system(size: 30))
                .foregroundStyle(Color.accentColor)
                .frame(height: 36)
            Text(layout.title)
                .font(.headline)
                .multilineTextAlignment(.leading)
                .lineLimit(2, reservesSpace: true)
            Text(layout.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 150, alignment: .topLeading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}
