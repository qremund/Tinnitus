import SwiftUI

struct SettingsView: View {
    @AppStorage("notchWidthOctaves") private var notchWidthOctaves = 1.0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Notch width", selection: $notchWidthOctaves) {
                        Text("1 octave").tag(1.0)
                        Text("1/2 octave").tag(0.5)
                    }
                } header: {
                    Text("Filter")
                } footer: {
                    Text("1 octave is the width used in most published studies. 1/2 octave keeps more of the sound.")
                }

                Section("Safety") {
                    Text("Test sounds are capped well below full volume. Keep the Control Center hearing meter under 80 dB.")
                    Text("This is a personal tool, not a medical device. Sudden changes in your tinnitus, or tinnitus in one ear only, are worth a visit to an audiologist.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
