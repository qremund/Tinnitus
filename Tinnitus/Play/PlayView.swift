import SwiftUI
import TinnitusCore

struct PlayView: View {
    @Environment(ProfileStore.self) private var store
    @Environment(SleepPlayer.self) private var player
    @AppStorage("notchWidthOctaves") private var notchWidthOctaves = 1.0

    private let timerChoices = [15, 30, 45, 60, 90]
    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 12)]

    var body: some View {
        @Bindable var player = player
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    notchSummary
                    ProfilePicker()

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(SleepSound.allCases, id: \.self) { sound in
                            Button {
                                player.sound = sound
                            } label: {
                                VStack(spacing: 8) {
                                    Image(systemName: sound.systemImage)
                                        .font(.title2)
                                    Text(sound.title)
                                        .font(.footnote)
                                }
                                .frame(maxWidth: .infinity, minHeight: 72)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(player.sound == sound ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(player.sound == sound ? Color.accentColor : .clear, lineWidth: 2)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button(action: player.togglePlayback) {
                        Label(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3.bold())
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)

                    VStack(alignment: .leading) {
                        Text("Volume").font(.subheadline)
                        Slider(value: $player.levelDBFS, in: -60...SafetyLimits.maxSleepLevelDBFS) {
                            Text("Volume")
                        } minimumValueLabel: {
                            Image(systemName: "speaker.fill")
                        } maximumValueLabel: {
                            Image(systemName: "speaker.wave.3.fill")
                        }
                    }

                    Toggle("Notch filter", isOn: $player.filterEnabled)
                        .disabled(!player.hasNotch)

                    sleepTimer

                    if let error = player.errorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                }
                .padding()
            }
            .navigationTitle("Play")
        }
        .onAppear(perform: syncNotch)
        .onChange(of: store.ears) { syncNotch() }
        .onChange(of: notchWidthOctaves) { syncNotch() }
    }

    @ViewBuilder
    private var notchSummary: some View {
        let pitches = store.ears.pitches
        if !pitches.isEmpty {
            Label {
                VStack(alignment: .leading) {
                    if pitches.isSameInBothEars {
                        Text(player.filterEnabled ? "Removing \(Format.earNotch(pitches.left, widthOctaves: notchWidthOctaves))" : "Notch off (A/B comparison)")
                            .font(.headline)
                        Text("Both ears, centered on your \(Format.pitches(pitches.left)) match\(pitches.left.count == 1 ? "" : "es")")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(player.filterEnabled ? "A separate notch in each ear" : "Notch off (A/B comparison)")
                            .font(.headline)
                        Text("Left: \(Format.earNotch(pitches.left, widthOctaves: notchWidthOctaves))\nRight: \(Format.earNotch(pitches.right, widthOctaves: notchWidthOctaves))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: player.filterEnabled ? "waveform.badge.minus" : "waveform")
            }
        } else {
            Label(store.activeProfile.map { "\($0.name) has no matches yet, so sounds play unfiltered. Add matches on the Profile tab." }
                  ?? "No matches yet, so sounds play unfiltered. Use the Match tab first.", systemImage: "exclamationmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var sleepTimer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sleep timer").font(.subheadline)
            if let end = player.timerEnd {
                HStack {
                    Text("Stops in ")
                    + Text(end, style: .timer)
                    Spacer()
                    Button("Cancel", role: .destructive, action: player.cancelTimer)
                }
                Text("Fades out over the last minute.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    ForEach(timerChoices, id: \.self) { minutes in
                        Button("\(minutes)m") {
                            if !player.isPlaying { player.play() }
                            player.startTimer(minutes: minutes)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func syncNotch() {
        player.setNotch(pitches: store.ears.pitches, widthOctaves: notchWidthOctaves)
    }
}
