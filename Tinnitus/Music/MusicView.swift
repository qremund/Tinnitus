import MediaPlayer
import SwiftUI
import TinnitusCore
import UniformTypeIdentifiers

struct MusicView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicPlayer.self) private var player
    @Environment(ProfileStore.self) private var store
    @AppStorage("notchWidthOctaves") private var notchWidthOctaves = 1.0
    @State private var showingFiles = false
    @State private var showingMediaPicker = false
    @State private var importMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if !store.profiles.isEmpty {
                    Section("Notch") {
                        ProfilePicker()
                    }
                }
                if library.tracks.isEmpty {
                    emptyState
                } else {
                    Section {
                        ForEach(Array(library.tracks.enumerated()), id: \.element.id) { index, track in
                            Button {
                                player.play(library.tracks, startAt: index)
                            } label: {
                                TrackRow(track: track, isCurrent: player.currentTrack?.id == track.id, isPlaying: player.isPlaying)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            for track in offsets.map({ library.tracks[$0] }) {
                                player.remove(track)
                                library.delete(track)
                            }
                        }
                        .onMove { library.move(from: $0, to: $1) }
                    } footer: {
                        Text(notchFooter)
                    }
                }
                if library.isImporting {
                    HStack {
                        ProgressView()
                        Text("Importing songs…")
                    }
                }
            }
            .navigationTitle("Music")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !library.tracks.isEmpty { EditButton() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("From Files", systemImage: "folder") { showingFiles = true }
                        Button("From Music Library", systemImage: "music.note.list", action: openMusicLibrary)
                    } label: {
                        Label("Add songs", systemImage: "plus")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if player.currentTrack != nil {
                    NowPlayingBar()
                }
            }
            .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): importMessage = library.importFiles(urls)
                case .failure(let error): importMessage = error.localizedDescription
                }
            }
            .sheet(isPresented: $showingMediaPicker) {
                MediaPicker { items in
                    showingMediaPicker = false
                    Task { importMessage = await library.importMediaItems(items) }
                } onCancel: {
                    showingMediaPicker = false
                }
                .ignoresSafeArea()
            }
            .alert("Some songs weren't added", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importMessage ?? "")
            }
        }
        .onAppear(perform: syncNotch)
        .onChange(of: store.ears) { syncNotch() }
        .onChange(of: notchWidthOctaves) { syncNotch() }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Add your own songs", systemImage: "music.note")
                .font(.headline)
            Text("Tap + to add audio files from the Files app (MP3, M4A, WAV, AIFF, FLAC), or songs you bought or synced into the Music app.")
            Text("Apple Music streaming and downloaded Apple Music songs are copy protected, so iPhone won't let any app filter them.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.vertical, 8)
    }

    private var notchFooter: String {
        let pitches = store.ears.pitches
        if pitches.isEmpty {
            return store.activeProfile.map { "\($0.name) has no matches yet, so songs play unfiltered." }
                ?? "No matches yet, so songs play unfiltered. Use the Match tab first."
        }
        let removed: String
        if pitches.isSameInBothEars {
            removed = "Songs play with \(Format.earNotch(pitches.left, widthOctaves: notchWidthOctaves)) removed in both ears."
        } else {
            func ear(_ name: String, _ centers: [Double]) -> String {
                centers.isEmpty ? "\(name) ear: unfiltered." : "\(name) ear: \(Format.earNotch(centers, widthOctaves: notchWidthOctaves)) removed."
            }
            removed = "\(ear("Left", pitches.left)) \(ear("Right", pitches.right))"
        }
        return "\(removed) Each song takes a few seconds to prepare the first time."
    }

    private func openMusicLibrary() {
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized:
            showingMediaPicker = true
        case .notDetermined:
            MPMediaLibrary.requestAuthorization { status in
                DispatchQueue.main.async {
                    if status == .authorized {
                        showingMediaPicker = true
                    } else {
                        importMessage = "Music library access was declined. You can allow it in Settings › Tinnitus."
                    }
                }
            }
        default:
            importMessage = "Music library access is off. You can allow it in Settings › Tinnitus."
        }
    }

    private func syncNotch() {
        player.setNotch(pitches: store.ears.pitches, widthOctaves: notchWidthOctaves)
    }
}

private struct TrackRow: View {
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack {
            Image(systemName: isCurrent ? (isPlaying ? "speaker.wave.2.fill" : "speaker.fill") : "music.note")
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading) {
                Text(track.title)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                if let artist = track.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(Format.duration(track.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

private struct NowPlayingBar: View {
    @Environment(MusicPlayer.self) private var player

    var body: some View {
        @Bindable var player = player
        VStack(spacing: 10) {
            HStack {
                Text(player.currentTrack?.title ?? "")
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Spacer()
                Toggle(isOn: $player.filterEnabled) {
                    Text("Notch")
                        .font(.subheadline)
                }
                .fixedSize()
                .disabled(!player.hasNotch)
            }

            if player.isPreparing {
                ProgressView(value: player.prepareProgress) {
                    Text("Filtering this song…").font(.caption)
                }
            } else {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    ProgressView(value: min(player.currentTime, player.duration), total: max(player.duration, 1))
                    HStack {
                        Text(Format.duration(player.currentTime))
                        Spacer()
                        Text(Format.duration(player.duration))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 40) {
                Button(action: player.previous) {
                    Image(systemName: "backward.fill")
                }
                Button(action: player.togglePlayback) {
                    Image(systemName: player.isPlaying || player.isPreparing ? "pause.fill" : "play.fill")
                        .font(.title)
                }
                Button(action: player.next) {
                    Image(systemName: "forward.fill")
                }
            }
            .font(.title3)

            if let error = player.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(.bar)
    }
}
